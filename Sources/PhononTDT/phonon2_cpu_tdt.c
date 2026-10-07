/* Vendored from https://github.com/fermionresearch/phonon-coreml
 * at 1ace2d0 (1ace2d0fb9a1d1f11a79f3a128eedfbf5afebb5d; Sources/PhononTDT identical to tag 1.1.1),
 * file Sources/PhononTDT/phonon2_cpu_tdt.c. Copyright 2026 Fermion Research. Apache License 2.0:
 * see Sources/Search/Fork/Voice/Phonon/LICENSE and NOTICE.
 * Local changes: this header only.
 */
/* Phonon-2 greedy TDT decode step in C (2026-09-28 evening, CPU-engine plan item "the TDT loop out of PyTorch").
 *
 * The container stores the decoder as int6 codes with per-row fp16 scales (embedding [V,640], LSTM weight_ih/hh l0/l1
 * [2560,640], decoder_projector [640,640], joint.head [8198,640]); int6 codes fit int8 exactly, so an int8 dot against
 * them with the row scale is EXACT for the weights.  Activations (embedding row, LSTM inputs/hidden, joint hidden) are
 * quantised per vector to int8 (absmax/127) -- the same ~exact class as the encoder kernel.  Biases fp32.
 *
 * Per step (one activation vector):  x = emb[last];  for l in 0,1: g = Wih_l x + bih_l + Whh_l h_l + bhh_l (2560), i f g o;
 * dec = Wp h_1 + bp;  z = relu(encp[t] + dec);  logits = Wh z + bh (8198);  tok = argmax(logits[:V]), dur = argmax(logits[V:]).
 * Control flow = the reference loop (equal to HF generate on 200/200 utterances): blank with dur 0 -> 1; non-blank keeps
 * the frame and updates the state; max_symbols consecutive dur-0 emissions force an advance.
 * GEMVs run on a persistent pool (rows split across threads), NEON sdot (detected at run time, plain NEON otherwise) / AVX2 / AVX-512 VNNI with a scalar fallback.
 * C ABI: phonon2_tdt_create(...), phonon2_tdt_decode(h, encp[T][640] fp32, T, out_tokens, max_out) -> n tokens,
 *        phonon2_tdt_set_threads(n), phonon2_tdt_destroy(h); ABI 3 adds phonon2_tdt_clone (shared tables).
 */
#include <math.h>
#include <pthread.h>
#if defined(__APPLE__)
#include <pthread/qos.h>
#endif
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifndef P2_EXPORT
#define P2_EXPORT
#endif
#if defined(_WIN32)
#include <malloc.h>
/* Windows: plain malloc (16-byte aligned; every vector access is unaligned-safe) so that the free() calls throughout
   stay valid — _aligned_malloc memory freed with free() corrupts the CRT heap (0xC0000374, seen on Windows Server 2022). */
#define P2_ALIGNED_ALLOC(b) malloc(b)
#define P2_ALIGNED_FREE(p) free(p)
#else
#define P2_ALIGNED_ALLOC(b) ({ void *_p = NULL; posix_memalign(&_p, 64, (b)) ? NULL : _p; })
#define P2_ALIGNED_FREE(p) free(p)
#endif
static float f16(uint16_t h) { uint32_t s = (h >> 15) & 1, e = (h >> 10) & 31, f = h & 1023; float v; if (e == 0) v = ldexpf((float)f, -24); else if (e == 31) v = f ? NAN : INFINITY; else v = ldexpf((float)(f | 1024), (int)e - 25); return s ? -v : v; }
static void *xalloc(size_t b) { void *p = P2_ALIGNED_ALLOC(b ? b : 64); if (!p) { fprintf(stderr, "tdt alloc\n"); exit(2); } memset(p, 0, b ? b : 64); return p; }
#if defined(__aarch64__)
#include <arm_neon.h>
#define T_NEON 1
#endif
#if defined(__x86_64__)
#include <immintrin.h>
#define T_X86 1
#endif


struct pool_s;
typedef struct { int rows, cols; int8_t *q; float *scale; float *bias; int32_t *rowsum; } mat_t;   /* q [rows][cols], rowsum for the x86 u8 offset */

static void mat_init(mat_t *m, int rows, int cols, const int8_t *q, const uint16_t *scale16, const uint16_t *bias16_a, const uint16_t *bias16_b) {
    m->rows = rows; m->cols = cols; m->q = xalloc((size_t)rows * cols); memcpy(m->q, q, (size_t)rows * cols);
    m->scale = xalloc(rows * sizeof(float)); m->bias = xalloc(rows * sizeof(float)); m->rowsum = xalloc(rows * sizeof(int32_t));
    for (int r = 0; r < rows; ++r) {
        m->scale[r] = f16(scale16[r]); m->bias[r] = (bias16_a ? f16(bias16_a[r]) : 0.f) + (bias16_b ? f16(bias16_b[r]) : 0.f);
        int32_t s = 0; for (int k = 0; k < cols; ++k) s += q[(size_t)r * cols + k]; m->rowsum[r] = s;
    }
}
static void mat_free(mat_t *m) { free(m->q); free(m->scale); free(m->bias); free(m->rowsum); }

typedef struct {
    int V, E, H, ndur, blank, max_sym, nhead;
    mat_t emb, ih0, hh0, ih1, hh1, proj, head;
    int durations[16];
    /* scratch */
    int8_t *xq, *hq; uint8_t *xu, *hu; float *gates, *h0, *c0, *h1, *c1, *dec, *z, *logits;
    int owns;                        /* 1 = owns the weight tables; clones share them */
    float *ph0, *pc0, *ph1, *pc1;   /* post-step LSTM state of the last prediction-network evaluation (blank-step cache) */
    struct pool_s *pool;
} tdt_t;

/* ---------------------------------------------------------------- int8 GEMV: y[r] = scale[r]*sx*<q_r, xq> (+ optional second operand) */
#if defined(T_X86)
__attribute__((target("avx512f,avx512bw,avx512vnni")))
static int32_t dot_vnni(const int8_t *w, const uint8_t *xu, int32_t rowsum, int K) {
    __m512i acc = _mm512_setzero_si512();
    for (int k = 0; k < K; k += 64) acc = _mm512_dpbusd_epi32(acc, _mm512_loadu_si512((const void *)(xu + k)), _mm512_loadu_si512((const void *)(w + k)));
    return _mm512_reduce_add_epi32(acc) - 128 * rowsum;
}
__attribute__((target("avx2")))
static int32_t dot_avx2(const int8_t *w, const uint8_t *xu, int32_t rowsum, int K) {
    /* u8*s8 maddubs: |w| <= 32 (int6 codes) -> pair sums <= 2*255*32 = 16320 < 32767, no saturation */
    __m256i acc = _mm256_setzero_si256(), ones = _mm256_set1_epi16(1);
    for (int k = 0; k < K; k += 32) acc = _mm256_add_epi32(acc, _mm256_madd_epi16(_mm256_maddubs_epi16(_mm256_loadu_si256((const __m256i *)(xu + k)), _mm256_loadu_si256((const __m256i *)(w + k))), ones));
    __m128i s = _mm_add_epi32(_mm256_castsi256_si128(acc), _mm256_extracti128_si256(acc, 1)); s = _mm_hadd_epi32(s, s); s = _mm_hadd_epi32(s, s);
    return _mm_cvtsi128_si32(s) - 128 * rowsum;
}
static int g_x86_kind = -1;   /* 4 vnni, 3 avx2, 1 scalar */
static void detect_x86_tdt(void) { if (g_x86_kind >= 0) return; g_x86_kind = (__builtin_cpu_supports("avx512vnni") && __builtin_cpu_supports("avx512bw")) ? 4 : (__builtin_cpu_supports("avx2") ? 3 : 1); }
#endif
#if defined(T_NEON)
#if defined(__APPLE__)
#include <sys/sysctl.h>
#endif
/* SDOT where the CPU has it (every Apple M-series chip and recent iPhones); plain NEON widening multiply elsewhere, chosen once at run time
   so the same binary never executes an instruction the CPU lacks. */
__attribute__((target("dotprod")))
static int32_t dot_sdot(const int8_t *w, const int8_t *x, int K) {
    int32x4_t a0 = vdupq_n_s32(0), a1 = vdupq_n_s32(0);
    for (int k = 0; k < K; k += 32) { a0 = vdotq_s32(a0, vld1q_s8(w + k), vld1q_s8(x + k)); a1 = vdotq_s32(a1, vld1q_s8(w + k + 16), vld1q_s8(x + k + 16)); }
    return vaddvq_s32(vaddq_s32(a0, a1));
}
static int32_t dot_neon(const int8_t *w, const int8_t *x, int K) {
    int32x4_t a = vdupq_n_s32(0);
    for (int k = 0; k < K; k += 16) {
        int8x16_t wv = vld1q_s8(w + k), xv = vld1q_s8(x + k);
        a = vpadalq_s16(a, vmull_s8(vget_low_s8(wv), vget_low_s8(xv))); a = vpadalq_s16(a, vmull_high_s8(wv, xv));
    }
    return vaddvq_s32(a);
}
static int g_sdot = -1;
static void detect_sdot(void) {
    if (g_sdot >= 0) return;
#if defined(__ARM_FEATURE_DOTPROD)
    g_sdot = 1;
#elif defined(__APPLE__)
    int v = 0; size_t n = sizeof v; g_sdot = (sysctlbyname("hw.optional.arm.FEAT_DotProd", &v, &n, NULL, 0) == 0 && v) ? 1 : 0;
#else
    g_sdot = 0;
#endif
}
#endif
static inline int32_t dot_i8(const int8_t *w, const int8_t *x, const uint8_t *xu, int32_t rowsum, int K) {
#if defined(T_NEON)
    (void)xu; (void)rowsum;
    return g_sdot > 0 ? dot_sdot(w, x, K) : dot_neon(w, x, K);
#elif defined(T_X86)
    detect_x86_tdt();
    if (g_x86_kind == 4) return dot_vnni(w, xu, rowsum, K);
    if (g_x86_kind == 3) return dot_avx2(w, xu, rowsum, K);
    { int32_t a = 0; for (int k = 0; k < K; ++k) a += w[k] * x[k]; return a; }
#else
    (void)xu; (void)rowsum; int32_t a = 0; for (int k = 0; k < K; ++k) a += w[k] * x[k]; return a;
#endif
}

static float quant_vec(const float *x, int K, int8_t *q, uint8_t *u) {
    float amax = 0.f; for (int k = 0; k < K; ++k) { float a = fabsf(x[k]); if (a > amax) amax = a; }
    float s = amax > 0.f ? amax / 127.f : 1.f, inv = 1.f / s;
    for (int k = 0; k < K; ++k) { int v = (int)lrintf(x[k] * inv); if (v > 127) v = 127; if (v < -127) v = -127; q[k] = (int8_t)v; if (u) u[k] = (uint8_t)(v + 128); }
    return s;
}

/* ---------------------------------------------------------------- pool: rows [r0,r1) of a job (one pool PER HANDLE, so handles are independent) */
typedef struct { const mat_t *A; const int8_t *xq; const uint8_t *xu; float sx; const mat_t *B; const int8_t *hq; const uint8_t *hu; float sh; float *y; int rows; } job_t;
typedef struct pool_s { pthread_mutex_t mu; pthread_cond_t cv; atomic_int epoch, quit, done; int nthreads, spin, started; job_t job; pthread_t th[32]; } pool_t;
typedef struct { int tid; pool_t *P; } warg_t;
static int g_default_threads = 1;

static void run_rows(pool_t *P, int tid) {
    const job_t *j = &P->job; int n = P->nthreads, r0 = (int)((long)j->rows * tid / n), r1 = (int)((long)j->rows * (tid + 1) / n);
    for (int r = r0; r < r1; ++r) {
        float v = j->A->scale[r] * j->sx * (float)dot_i8(j->A->q + (size_t)r * j->A->cols, j->xq, j->xu, j->A->rowsum[r], j->A->cols) + j->A->bias[r];
        if (j->B) v += j->B->scale[r] * j->sh * (float)dot_i8(j->B->q + (size_t)r * j->B->cols, j->hq, j->hu, j->B->rowsum[r], j->B->cols) + j->B->bias[r];
        j->y[r] = v;
    }
    atomic_fetch_add(&P->done, 1);
}
static void *worker(void *arg) {
    warg_t *w = arg; pool_t *P = w->P; int tid = w->tid, seen = 0; free(w);
#if defined(__APPLE__)
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);   /* GEMV rows on performance cores (short utterances return sooner) */
#endif
    for (;;) {
        int spins = 0;
        while (atomic_load_explicit(&P->epoch, memory_order_acquire) == seen) {
            if (atomic_load(&P->quit)) return NULL;
            if (++spins >= P->spin) { pthread_mutex_lock(&P->mu); while (atomic_load(&P->epoch) == seen && !atomic_load(&P->quit)) pthread_cond_wait(&P->cv, &P->mu); pthread_mutex_unlock(&P->mu); spins = 0; }
        }
        seen = atomic_load(&P->epoch); run_rows(P, tid);
    }
}
static void pool_stop(pool_t *P) {
    if (!P->started) return;
    atomic_store(&P->quit, 1); pthread_mutex_lock(&P->mu); pthread_cond_broadcast(&P->cv); pthread_mutex_unlock(&P->mu);
    for (int i = 1; i < P->nthreads; ++i) pthread_join(P->th[i], NULL);
    atomic_store(&P->quit, 0); P->started = 0;
}
static void pool_start(pool_t *P, int n) {
    if (n < 1) n = 1; if (n > 32) n = 32;
    pool_stop(P); P->nthreads = n; P->spin = 30000; pthread_mutex_init(&P->mu, NULL); pthread_cond_init(&P->cv, NULL);
    for (int i = 1; i < n; ++i) { warg_t *w = xalloc(sizeof *w); w->tid = i; w->P = P; pthread_create(&P->th[i], NULL, worker, w); }
    P->started = 1;
}
/* kept for ABI: the default thread count for handles created afterwards (and for handles that never called phonon2_tdt_handle_threads) */
P2_EXPORT void phonon2_tdt_set_threads(int n) { g_default_threads = n < 1 ? 1 : (n > 32 ? 32 : n); }
static void gemv(pool_t *P, const mat_t *A, const int8_t *xq, const uint8_t *xu, float sx, const mat_t *B, const int8_t *hq, const uint8_t *hu, float sh, float *y) {
    if (!P->started) pool_start(P, g_default_threads);
    if (P->nthreads == 1) { P->job = (job_t){ A, xq, xu, sx, B, hq, hu, sh, y, A->rows }; atomic_store(&P->done, 0); run_rows(P, 0); return; }
    P->job = (job_t){ A, xq, xu, sx, B, hq, hu, sh, y, A->rows }; atomic_store(&P->done, 0);
    pthread_mutex_lock(&P->mu); atomic_fetch_add(&P->epoch, 1); pthread_cond_broadcast(&P->cv); pthread_mutex_unlock(&P->mu);
    run_rows(P, 0);
    while (atomic_load_explicit(&P->done, memory_order_acquire) < P->nthreads) {}
}

/* ---------------------------------------------------------------- create / destroy */
static void alloc_scratch(tdt_t *t) {
    int E = t->E, H = t->H, nhead = t->nhead;
    int K = E > H ? E : H;
    t->xq = xalloc(K + 64); t->hq = xalloc(K + 64); t->xu = xalloc(K + 64); t->hu = xalloc(K + 64);
    t->gates = xalloc(4 * H * sizeof(float)); t->h0 = xalloc(H * 4); t->c0 = xalloc(H * 4); t->h1 = xalloc(H * 4); t->c1 = xalloc(H * 4);
    t->dec = xalloc(H * 4); t->z = xalloc(H * 4); t->ph0 = xalloc(H * 4); t->pc0 = xalloc(H * 4); t->ph1 = xalloc(H * 4); t->pc1 = xalloc(H * 4); t->logits = xalloc(nhead * sizeof(float));
    t->pool = xalloc(sizeof(pool_t));
}

P2_EXPORT void *phonon2_tdt_create(int V, int E, int H, int nhead, int ndur, const int *durations, int blank, int max_sym,
                         const int8_t *emb_q, const uint16_t *emb_s,
                         const int8_t *ih0_q, const uint16_t *ih0_s, const uint16_t *bih0, const int8_t *hh0_q, const uint16_t *hh0_s, const uint16_t *bhh0,
                         const int8_t *ih1_q, const uint16_t *ih1_s, const uint16_t *bih1, const int8_t *hh1_q, const uint16_t *hh1_s, const uint16_t *bhh1,
                         const int8_t *proj_q, const uint16_t *proj_s, const uint16_t *proj_b,
                         const int8_t *head_q, const uint16_t *head_s, const uint16_t *head_b) {
    if (E % 64 || H % 64) { fprintf(stderr, "tdt: E/H must be multiples of 64\n"); return NULL; }
#if defined(T_NEON)
    detect_sdot();
#endif
    tdt_t *t = xalloc(sizeof *t); t->V = V; t->E = E; t->H = H; t->ndur = ndur; t->blank = blank; t->max_sym = max_sym; t->nhead = nhead;
    for (int i = 0; i < ndur && i < 16; ++i) t->durations[i] = durations[i];
    mat_init(&t->emb, V, E, emb_q, emb_s, NULL, NULL);
    mat_init(&t->ih0, 4 * H, E, ih0_q, ih0_s, bih0, NULL); mat_init(&t->hh0, 4 * H, H, hh0_q, hh0_s, bhh0, NULL);
    mat_init(&t->ih1, 4 * H, H, ih1_q, ih1_s, bih1, NULL); mat_init(&t->hh1, 4 * H, H, hh1_q, hh1_s, bhh1, NULL);
    mat_init(&t->proj, H, H, proj_q, proj_s, proj_b, NULL); mat_init(&t->head, nhead, H, head_q, head_s, head_b, NULL);
    t->owns = 1; alloc_scratch(t);
    return t;
}
P2_EXPORT void phonon2_tdt_destroy(void *h) { tdt_t *t = h; if (!t) return; if (t->owns) { mat_free(&t->emb); mat_free(&t->ih0); mat_free(&t->hh0); mat_free(&t->ih1); mat_free(&t->hh1); mat_free(&t->proj); mat_free(&t->head); }
    pool_stop(t->pool); free(t->pool);
    free(t->xq); free(t->hq); free(t->xu); free(t->hu); free(t->gates); free(t->h0); free(t->c0); free(t->h1); free(t->c1); free(t->dec); free(t->z); free(t->ph0); free(t->pc0); free(t->ph1); free(t->pc1); free(t->logits); free(t); }
/* a new handle that SHARES the weight tables of `h` (own scratch, state and thread pool); destroy every clone before `h`. */
P2_EXPORT void *phonon2_tdt_clone(void *h) {
    tdt_t *b = h; if (!b) return NULL;
    tdt_t *t = xalloc(sizeof *t); *t = *b; t->owns = 0; alloc_scratch(t);
    return t;
}
P2_EXPORT void phonon2_tdt_handle_threads(void *h, int n) { tdt_t *t = h; if (t) pool_start(t->pool, n); }

static inline float sigm(float x) { return 1.f / (1.f + expf(-x)); }

static void lstm_layer(tdt_t *t, const mat_t *ih, const mat_t *hh, const float *x, int xdim, float *h, float *c) {
    float sx = quant_vec(x, xdim, t->xq, t->xu), sh = quant_vec(h, t->H, t->hq, t->hu);
    gemv(t->pool, ih, t->xq, t->xu, sx, hh, t->hq, t->hu, sh, t->gates);
    int H = t->H;
    for (int j = 0; j < H; ++j) {
        float i = sigm(t->gates[j]), f = sigm(t->gates[H + j]), g = tanhf(t->gates[2 * H + j]), o = sigm(t->gates[3 * H + j]);
        c[j] = f * c[j] + i * g; h[j] = o * tanhf(c[j]);
    }
}

/* encp: [T][H] fp32 (encoder_projector already applied); returns number of tokens written (excluding blank) */
P2_EXPORT int phonon2_tdt_decode_timed(void *hnd, const float *encp, int T, int32_t *out, int32_t *out_frame, int32_t *out_dur, int max_out) {
    tdt_t *t = hnd; int H = t->H, E = t->E, V = t->V, blank = t->blank;
    memset(t->h0, 0, H * 4); memset(t->c0, 0, H * 4); memset(t->h1, 0, H * 4); memset(t->c1, 0, H * 4);
    float *x = xalloc(E * sizeof(float));
    /* blank-step cache (exact): a blank leaves `last` and the LSTM state unchanged, so the next step's prediction-network output
       is the same computation on the same inputs; it is reused instead of recomputed.  The post-step state is kept in ph/pc and becomes
       the state only when a non-blank is emitted (the reference loop's restore-on-blank, without the copies). */
    int last = blank, tt = 0, nsym = 0, n = 0, it = 0, max_it = t->max_sym * T + 16, cached = 0;
    while (tt < T && it < max_it) {
        ++it;
        if (!cached) {
            for (int k = 0; k < E; ++k) x[k] = t->emb.scale[last] * (float)t->emb.q[(size_t)last * E + k];
            memcpy(t->ph0, t->h0, H * 4); memcpy(t->pc0, t->c0, H * 4); memcpy(t->ph1, t->h1, H * 4); memcpy(t->pc1, t->c1, H * 4);
            lstm_layer(t, &t->ih0, &t->hh0, x, E, t->ph0, t->pc0);
            lstm_layer(t, &t->ih1, &t->hh1, t->ph0, H, t->ph1, t->pc1);
            float sh = quant_vec(t->ph1, H, t->hq, t->hu); gemv(t->pool, &t->proj, t->hq, t->hu, sh, NULL, NULL, NULL, 0.f, t->dec);
            cached = 1;
        }
        const float *f = encp + (size_t)(tt < T ? tt : T - 1) * H;
        for (int k = 0; k < H; ++k) { float v = f[k] + t->dec[k]; t->z[k] = v > 0.f ? v : 0.f; }
        float sz = quant_vec(t->z, H, t->xq, t->xu); gemv(t->pool, &t->head, t->xq, t->xu, sz, NULL, NULL, NULL, 0.f, t->logits);
        int tok = 0; float best = t->logits[0];
        for (int v = 1; v < V; ++v) if (t->logits[v] > best) { best = t->logits[v]; tok = v; }
        int di = 0; float bd = t->logits[V];
        for (int d = 1; d < t->ndur; ++d) if (t->logits[V + d] > bd) { bd = t->logits[V + d]; di = d; }
        int dur = t->durations[di];
        if (tok == blank && dur == 0) dur = 1;
        if (tok != blank) {
            if (n < max_out) { out[n] = tok; if (out_frame) out_frame[n] = tt; if (out_dur) out_dur[n] = dur; ++n; }
            last = tok; memcpy(t->h0, t->ph0, H * 4); memcpy(t->c0, t->pc0, H * 4); memcpy(t->h1, t->ph1, H * 4); memcpy(t->c1, t->pc1, H * 4); cached = 0;
        }   /* blank: state not advanced, cache stays valid */
        if (dur == 0) { if (++nsym >= t->max_sym) { dur = 1; nsym = 0; } } else nsym = 0;
        tt += dur;
    }
    free(x); return n;
}
P2_EXPORT int phonon2_tdt_decode(void *hnd, const float *encp, int T, int32_t *out, int max_out) { return phonon2_tdt_decode_timed(hnd, encp, T, out, NULL, NULL, max_out); }
P2_EXPORT int phonon2_tdt_abi_version(void) { return 3; }
