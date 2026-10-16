#!/usr/bin/env python3
"""Big-canvas fixture generator for Copper's canvas performance work.

Writes `canvas_apply` op batches that build a plausible, busy whiteboard —
slide frames in a grid with content inside, a wall of live web frames, sticky
brainstorm clusters, an image moodboard, checklists, timelines, arrows and
comment threads — plus the local web pages and images `serve.sh` serves to
the live frames. Python 3.9+ standard library only; deterministic for a seed.

    python3 gen.py --scale big            # ~1,500 shapes  -> out/big/ops-NNN.json
    python3 gen.py --scale huge           # ~4,000 shapes
    python3 gen.py --scale small          # ~300 shapes, quick checks

Outputs (all under --out, default ./out, git-ignored):
    out/<scale>/ops-NNN.json   JSON array of ops, <= 200 ops and <= ~600 KB each
    out/<scale>/manifest.json  counts, expected shape total, focus ids, batches
    out/www/                   pages/*.html, img/*.png|jpg, index.html (serve.sh)

Board images are data: URLs (the page accepts only data: or https: image
sources), each <= --max-data-url chars so every op fits one argv string even
on Linux (MAX_ARG_STRLEN 128 KB). The heavy 100 KB–2 MB images are served
over http to the local pages shown in the live frames.
"""
import argparse
import base64
import json
import math
import os
import random
import struct
import sys
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))

# --------------------------------------------------------------------------
# PNG writer (zlib)
# --------------------------------------------------------------------------


def png_bytes(w, h, rows):
    """rows: iterable of h bytes-like rows, each w*3 RGB bytes."""
    raw = bytearray()
    for r in rows:
        raw.append(0)
        raw += r
    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    ihdr = struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(bytes(raw), 6)) + chunk(b"IEND", b"")


class Raster:
    """A tiny RGB raster with rectangle fills (fast slice assignment)."""

    def __init__(self, w, h, bg):
        self.w, self.h = w, h
        self.buf = bytearray(bytes(bg) * (w * h))

    def rect(self, x, y, w, h, color):
        x0, y0 = max(0, int(x)), max(0, int(y))
        x1, y1 = min(self.w, int(x + w)), min(self.h, int(y + h))
        if x1 <= x0 or y1 <= y0:
            return
        span = bytes(color) * (x1 - x0)
        for yy in range(y0, y1):
            o = (yy * self.w + x0) * 3
            self.buf[o:o + len(span)] = span

    def rows(self):
        s = self.w * 3
        for y in range(self.h):
            yield self.buf[y * s:(y + 1) * s]

    def png(self):
        return png_bytes(self.w, self.h, self.rows())


def mix(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


PALETTE = [(244, 114, 182), (96, 165, 250), (52, 211, 153), (251, 191, 36), (167, 139, 250),
           (248, 113, 113), (45, 212, 191), (251, 146, 60), (129, 140, 248), (163, 230, 53)]


def ui_mockup_png(rng, w, h):
    """A product screenshot: header, sidebar, card grid with text-like bars."""
    dark = rng.random() < 0.3
    bg = (24, 26, 32) if dark else (246, 247, 250)
    fg = (210, 214, 222) if dark else (60, 66, 80)
    card = (36, 40, 48) if dark else (255, 255, 255)
    accent = rng.choice(PALETTE)
    r = Raster(w, h, bg)
    hh = max(24, h // 14)
    r.rect(0, 0, w, hh, (16, 18, 24) if dark else (255, 255, 255))
    r.rect(hh // 3, hh // 3, hh // 3, hh // 3, accent)
    for i in range(5):
        r.rect(hh + i * (w // 12), hh * 0.42, w // 18, hh * 0.16, fg)
    sw = w // 6
    r.rect(0, hh, sw, h - hh, (30, 33, 40) if dark else (236, 238, 243))
    for i in range(12):
        r.rect(sw * 0.12, hh + 20 + i * (h // 16), sw * (0.4 + 0.4 * rng.random()), max(3, h // 120), fg)
    cols = rng.choice([2, 3, 4])
    pad = max(8, w // 60)
    cw = (w - sw - pad * (cols + 1)) / cols
    ch = cw * rng.uniform(0.45, 0.8)
    y = hh + pad
    while y + ch < h:
        for c in range(cols):
            x = sw + pad + c * (cw + pad)
            r.rect(x, y, cw, ch, card)
            r.rect(x, y, cw, max(3, ch * 0.06), rng.choice(PALETTE))
            lines = int(ch / max(10, h / 60)) - 2
            for li in range(max(1, lines)):
                r.rect(x + pad, y + ch * 0.18 + li * max(10, h / 60), cw * rng.uniform(0.3, 0.85), max(2, h / 200), fg)
            if rng.random() < 0.4:
                bars = 8
                for b in range(bars):
                    bh = ch * 0.4 * rng.random()
                    r.rect(x + pad + b * (cw - 2 * pad) / bars, y + ch - pad - bh, (cw - 2 * pad) / bars * 0.7, bh, accent)
        y += ch + pad
    return r.png()


def chart_png(rng, w, h):
    """A slide chart: gridlines, bars and a line series."""
    r = Raster(w, h, (255, 255, 255))
    m = max(20, w // 16)
    for i in range(6):
        r.rect(m, m + i * (h - 2 * m) / 5, w - 2 * m, 1, (226, 230, 236))
    r.rect(m, h - m, w - 2 * m, 2, (90, 96, 110))
    r.rect(m, m, 2, h - 2 * m, (90, 96, 110))
    n = rng.randint(6, 18)
    bw = (w - 2 * m) / n
    c1, c2 = rng.sample(PALETTE, 2)
    v = rng.uniform(0.2, 0.6)
    pts = []
    for i in range(n):
        v = min(0.95, max(0.05, v + rng.uniform(-0.15, 0.18)))
        bh = (h - 2 * m) * v
        r.rect(m + i * bw + bw * 0.15, h - m - bh, bw * 0.7, bh, mix(c1, (255, 255, 255), 0.25))
        pts.append((m + i * bw + bw / 2, h - m - (h - 2 * m) * min(0.98, v * rng.uniform(0.6, 1.2))))
    t = max(2, w // 300)
    for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
        steps = int(max(abs(x1 - x0), abs(y1 - y0)) / t) + 1
        for s in range(steps):
            f = s / steps
            r.rect(x0 + (x1 - x0) * f, y0 + (y1 - y0) * f, t * 2, t * 2, c2)
    return r.png()


def noise_png(rng, w, h, amp):
    """Photo-ish grain over a vertical colour gradient; amp (2..256) sets entropy (file size)."""
    top, bot = rng.choice(PALETTE), rng.choice(PALETTE)
    rows = []
    for y in range(h):
        base = mix(top, bot, y / max(1, h - 1))
        row = bytearray(w * 3)
        for ch in range(3):
            lvl = base[ch]
            table = bytes(max(0, min(255, lvl + (b % amp) - amp // 2)) for b in range(256))
            row[ch::3] = rng.randbytes(w).translate(table) if hasattr(rng, "randbytes") else bytes(rng.getrandbits(8) for _ in range(w)).translate(table)
        rows.append(row)
    return png_bytes(w, h, rows)


# --------------------------------------------------------------------------
# Baseline JPEG writer from procedurally generated DCT coefficients.
# No pixel-domain DCT: a smooth colour field gives each block its DC and
# first-order AC (so gradients look smooth), random higher-order AC adds
# texture; the amount of texture sets the file size. Standard Annex K tables.
# --------------------------------------------------------------------------

ZZ = [0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
      35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63]
QL = [16, 11, 10, 16, 24, 40, 51, 61, 12, 12, 14, 19, 26, 58, 60, 55, 14, 13, 16, 24, 40, 57, 69, 56, 14, 17, 22, 29, 51, 87, 80, 62,
      18, 22, 37, 56, 68, 109, 103, 77, 24, 35, 55, 64, 81, 104, 113, 92, 49, 64, 78, 87, 103, 121, 120, 101, 72, 92, 95, 98, 112, 100, 103, 99]
QC = [17, 18, 24, 47, 99, 99, 99, 99, 18, 21, 26, 66, 99, 99, 99, 99, 24, 26, 56, 99, 99, 99, 99, 99, 47, 66, 99, 99, 99, 99, 99, 99] + [99] * 32
DC_BITS = [0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0]
DC_VALS = list(range(12))
AC_BITS = [0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7D]
AC_VALS = [
    0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07,
    0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xA1, 0x08, 0x23, 0x42, 0xB1, 0xC1, 0x15, 0x52, 0xD1, 0xF0,
    0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0A, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x25, 0x26, 0x27, 0x28,
    0x29, 0x2A, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
    0x4A, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5A, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69,
    0x6A, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7A, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
    0x8A, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9A, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7,
    0xA8, 0xA9, 0xAA, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7, 0xB8, 0xB9, 0xBA, 0xC2, 0xC3, 0xC4, 0xC5,
    0xC6, 0xC7, 0xC8, 0xC9, 0xCA, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0xDA, 0xE1, 0xE2,
    0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xEA, 0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8,
    0xF9, 0xFA]
# Every AC symbol must be in the table exactly once, whatever the order.
assert len(AC_VALS) == sum(AC_BITS) == 162
assert sorted(AC_VALS) == sorted([0x00, 0xF0] + [(r << 4) | s for r in range(16) for s in range(1, 11)])


def huff_codes(bits, vals):
    codes, code, k = {}, 0, 0
    for length in range(1, 17):
        for _ in range(bits[length - 1]):
            codes[vals[k]] = (code, length)
            code += 1
            k += 1
        code <<= 1
    return codes


DC_CODES = huff_codes(DC_BITS, DC_VALS)
AC_CODES = huff_codes(AC_BITS, AC_VALS)


def scaled(q, quality):
    s = 5000 // quality if quality < 50 else 200 - 2 * quality
    return [max(1, min(255, (v * s + 50) // 100)) for v in q]


class BitWriter:
    def __init__(self):
        self.out = bytearray()
        self.acc = 0
        self.n = 0

    def put(self, code, length):
        self.acc = (self.acc << length) | code
        self.n += length
        while self.n >= 8:
            self.n -= 8
            b = (self.acc >> self.n) & 0xFF
            self.out.append(b)
            if b == 0xFF:
                self.out.append(0)
        self.acc &= (1 << self.n) - 1 if self.n else 0

    def flush(self):
        if self.n:
            self.put((1 << (8 - self.n)) - 1, 8 - self.n)


def _size(v):
    v = abs(v)
    s = 0
    while v:
        s += 1
        v >>= 1
    return s


def _enc_block(bw, coeffs, prev_dc):
    """coeffs: 64 quantized values in zigzag order."""
    diff = coeffs[0] - prev_dc
    s = _size(diff)
    c, l = DC_CODES[s]
    bw.put(c, l)
    if s:
        bw.put(diff if diff > 0 else diff + (1 << s) - 1, s)
    run = 0
    last = 63
    while last > 0 and coeffs[last] == 0:
        last -= 1
    for k in range(1, last + 1):
        v = coeffs[k]
        if v == 0:
            run += 1
            continue
        while run > 15:
            c, l = AC_CODES[0xF0]
            bw.put(c, l)
            run -= 16
        s = _size(v)
        c, l = AC_CODES[(run << 4) | s]
        bw.put(c, l)
        bw.put(v if v > 0 else v + (1 << s) - 1, s)
        run = 0
    if last < 63:
        c, l = AC_CODES[0x00]
        bw.put(c, l)
    return coeffs[0]


def rgb_to_ycc(r, g, b):
    y = 0.299 * r + 0.587 * g + 0.114 * b
    return y, 128 - 0.168736 * r - 0.331264 * g + 0.5 * b, 128 + 0.5 * r - 0.418688 * g - 0.081312 * b


def landscape_field(rng, w, h):
    """A smooth 'photo': sky gradient, sun, rolling hills, a lake band."""
    sky_top = rng.choice([(40, 90, 170), (250, 150, 90), (90, 140, 210), (30, 40, 80)])
    sky_bot = mix(sky_top, (255, 230, 200), 0.6)
    ground = rng.choice([(70, 120, 60), (150, 120, 70), (90, 100, 110), (200, 180, 140)])
    ground2 = mix(ground, (20, 30, 20), 0.5)
    sun = (rng.uniform(0.15, 0.85) * w, rng.uniform(0.1, 0.4) * h, rng.uniform(0.04, 0.1) * w)
    hz = rng.uniform(0.45, 0.7) * h
    a1, f1, a2, f2 = rng.uniform(0.02, 0.08) * h, rng.uniform(1, 4), rng.uniform(0.01, 0.04) * h, rng.uniform(5, 11)
    ph = rng.uniform(0, 6.28)

    def horizon(x):
        return hz - a1 * math.sin(f1 * x / w * 6.28 + ph) - a2 * math.sin(f2 * x / w * 6.28)

    def color(x, y):
        hy = horizon(x)
        if y < hy:
            c = mix(sky_top, sky_bot, min(1.0, y / max(1.0, hy)))
            d = math.hypot(x - sun[0], y - sun[1])
            glow = math.exp(-(d / (sun[2] * 2.2)) ** 2)
            c = mix(c, (255, 244, 214), min(1.0, glow * 1.2))
        else:
            t = min(1.0, (y - hy) / max(1.0, h - hy))
            c = mix(ground, ground2, t)
        return c

    return color, horizon


def jpeg_bytes(rng, w, h, quality=82, texture=0.4, tex_k=6, tex_amp=3):
    """4:2:0 baseline JPEG of a procedural landscape."""
    ql, qc = scaled(QL, quality), scaled(QC, quality)
    color, horizon = landscape_field(rng, w, h)
    mw, mh = (w + 15) // 16, (h + 15) // 16
    bw = BitWriter()
    prev = [0, 0, 0]
    k_h = -18.22 / ql[ZZ[1]]  # ramp slope (per px) -> zigzag[1] (horizontal u=1)
    k_v = -18.22 / ql[ZZ[2]]
    for my in range(mh):
        for mx in range(mw):
            # four luma blocks
            for by in range(2):
                for bx in range(2):
                    cx, cy = mx * 16 + bx * 8 + 4, my * 16 + by * 8 + 4
                    y0 = rgb_to_ycc(*color(cx, cy))[0]
                    yx = rgb_to_ycc(*color(cx + 4, cy))[0] - rgb_to_ycc(*color(cx - 4, cy))[0]
                    yy = rgb_to_ycc(*color(cx, cy + 4))[0] - rgb_to_ycc(*color(cx, cy - 4))[0]
                    c = [0] * 64
                    c[0] = int(round((y0 - 128) * 8 / ql[0]))
                    c[1] = max(-60, min(60, int(round(k_h * yx / 8))))
                    c[2] = max(-60, min(60, int(round(k_v * yy / 8))))
                    if texture and cy > horizon(cx) - 8 and rng.random() < texture:
                        for _ in range(tex_k):
                            c[rng.randint(3, 27)] = rng.choice((-1, 1)) * rng.randint(1, tex_amp)
                    elif texture and rng.random() < texture * 0.15:
                        c[rng.randint(3, 9)] = rng.choice((-1, 1))
                    prev[0] = _enc_block(bw, c, prev[0])
            _, cb, cr = rgb_to_ycc(*color(mx * 16 + 8, my * 16 + 8))
            for i, (v, q) in enumerate(((cb, qc), (cr, qc))):
                c = [0] * 64
                c[0] = int(round((v - 128) * 8 / q[0]))
                prev[1 + i] = _enc_block(bw, c, prev[1 + i])
    bw.flush()

    def seg(marker, data):
        return b"\xff" + bytes([marker]) + struct.pack(">H", len(data) + 2) + data

    out = bytearray(b"\xff\xd8")
    out += seg(0xE0, b"JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00")
    out += seg(0xDB, bytes([0]) + bytes(ql[ZZ[k]] for k in range(64)) + bytes([1]) + bytes(qc[ZZ[k]] for k in range(64)))
    out += seg(0xC0, struct.pack(">BHHB", 8, h, w, 3) + bytes([1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1]))
    out += seg(0xC4, bytes([0x00]) + bytes(DC_BITS) + bytes(DC_VALS) + bytes([0x10]) + bytes(AC_BITS) + bytes(AC_VALS))
    out += seg(0xDA, bytes([3, 1, 0x00, 2, 0x00, 3, 0x00, 0, 63, 0]))
    out += bw.out
    out += b"\xff\xd9"
    return bytes(out)


def data_url(mime, data):
    return "data:%s;base64,%s" % (mime, base64.b64encode(data).decode("ascii"))


def fit_data_image(rng, kind, w, h, budget):
    """A board image as a data URL no longer than `budget` chars; shrinks/tames it until it fits."""
    for attempt in range(8):
        seed = rng.random()
        sub = random.Random(seed)
        if kind == "photo":
            tex = [0.5, 0.3, 0.15, 0.05, 0.0, 0.0, 0.0, 0.0][attempt]
            data, mime = jpeg_bytes(sub, w, h, quality=80, texture=tex, tex_k=4), "image/jpeg"
        elif kind == "ui":
            data, mime = ui_mockup_png(sub, w, h), "image/png"
        else:
            data, mime = chart_png(sub, w, h), "image/png"
        url = data_url(mime, data)
        if len(url) <= budget:
            return url, w, h
        if kind != "photo" or attempt >= 4:
            w, h = int(w * 0.8), int(h * 0.8)
    raise SystemExit("could not fit a %s image under %d chars" % (kind, budget))


# --------------------------------------------------------------------------
# Words
# --------------------------------------------------------------------------

TOPICS = ["Onboarding", "Billing", "Search", "Sync", "Offline mode", "Sharing", "Permissions", "Mobile", "Perf", "Pricing",
          "Notifications", "Import", "Export", "Analytics", "Accessibility", "Dark mode", "Comments", "Templates", "API",
          "Security review", "Launch", "Support", "Docs", "Hiring", "Q4 roadmap", "Retention", "Activation", "Infra"]
VERBS = ["Ship", "Fix", "Measure", "Prototype", "Interview", "Design", "Draft", "Review", "Cut", "Split", "Cache", "Migrate",
         "Instrument", "Simplify", "Document", "Test", "Benchmark", "Localize", "Sunset", "Pilot"]
NOUNS = ["the empty state", "first-run flow", "invite email", "settings page", "sync conflicts", "cold start", "the paywall",
         "error copy", "search ranking", "share sheet", "keyboard shortcuts", "webhooks", "audit log", "rate limits",
         "the sidebar", "image uploads", "SSO", "trial length", "usage dashboard", "export to CSV", "offline queue",
         "the changelog", "release notes", "crash reports", "load times", "the pricing page", "team billing"]
QUIRKS = ["users drop off here", "3 customers asked", "blocked on legal", "needs design pass", "p95 is 4.2 s",
          "low effort / high impact", "what about enterprise?", "do we even need this?", "see thread", "ask Ana",
          "+1 from support", "risky before launch", "data says otherwise", "quick win", "parked until Q1",
          "needs an owner", "confirmed in interviews", "A/B test first", "spike: 2 days", "dup of #412"]
PEOPLE = ["Ana", "Ben", "Chen", "Dara", "Eli", "Fatima", "Gus", "Hana", "Ivan", "Jo", "Kofi", "Lena", "Mo", "Nia", "Omar",
          "Priya", "Quinn", "Rosa", "Sam", "Tariq", "Uma", "Vik", "Wen", "Yara", "Zoe"]
COLORS = ["yellow", "pink", "blue", "green", "purple", "gray", "white"]
STICKY_COLORS = ["yellow", "yellow", "yellow", "pink", "blue", "green", "purple", "white"]
COMMENT_LINES = ["Is this still accurate after the last sync?", "Can we get numbers for this?", "Love this direction.",
                 "Who owns this one?", "This conflicts with the slide before.", "Let's discuss Thursday.",
                 "Moved to next sprint.", "Customer quote is from the Oct interviews.", "Needs a design review first.",
                 "Done — see the PR.", "I think we're overestimating the effort.", "Ping legal before we commit.",
                 "Should this link to the spec?", "Agree, but scope it down.", "Screenshot is outdated."]


def sentence(rng):
    return "%s %s" % (rng.choice(VERBS), rng.choice(NOUNS))


def sticky_text(rng):
    r = rng.random()
    if r < 0.35:
        return sentence(rng)
    if r < 0.65:
        return "%s\n\n_%s_" % (sentence(rng), rng.choice(QUIRKS))
    if r < 0.85:
        return "**%s**\n- %s\n- %s" % (rng.choice(TOPICS), sentence(rng).lower(), sentence(rng).lower())
    return "%s — %s. %s?" % (sentence(rng), rng.choice(QUIRKS), sentence(rng))


# --------------------------------------------------------------------------
# Served pages + images (the live frames' content)
# --------------------------------------------------------------------------

FONT_CSS = """@font-face { font-family: 'Fixture Serif'; src: url('/fonts/fixture-serif.ttf') format('truetype'); font-display: swap; }
@font-face { font-family: 'Fixture Mono'; src: url('/fonts/fixture-mono.ttf') format('truetype'); font-display: swap; }
"""

PAGE_HEAD = """<!doctype html><html lang="en"><head><meta charset="utf-8"><title>%(title)s</title>
<link rel="icon" href="/img/favicon.png"><meta name="viewport" content="width=device-width">
<style>""" + FONT_CSS + """
body{margin:0;font:15px/1.5 'Fixture Serif',Georgia,serif;background:%(bg)s;color:%(fg)s}
header{position:sticky;top:0;padding:12px 20px;background:%(accent)s;color:#fff;font:600 18px 'Fixture Mono',Menlo,monospace;z-index:2}
main{padding:20px}
%(css)s
</style></head><body><header>%(title)s</header><main>
"""


def page_anim(rng, i):
    n = rng.randint(250, 600)
    return PAGE_HEAD % dict(title="Telemetry live #%d" % i, bg="#0b1020", fg="#d6e2ff", accent="#3b5bdb",
                            css="canvas{display:block;width:100%;height:70vh;background:#05070f}.k{font:32px 'Fixture Mono',monospace}") + """
<div class="k">Particles: <span id="n">%d</span> · fps <span id="fps">0</span></div><canvas id="c"></canvas>
<script>
const c=document.getElementById('c'),g=c.getContext('2d');let W,H;function size(){W=c.width=c.clientWidth*devicePixelRatio;H=c.height=c.clientHeight*devicePixelRatio}
size();addEventListener('resize',size);let s=%d;const R=()=>(s=(s*16807)%%2147483647)/2147483647;
const P=Array.from({length:%d},()=>({x:R()*W,y:R()*H,vx:(R()-.5)*3,vy:(R()-.5)*3,h:R()*360}));
let last=performance.now(),fr=0,acc=0;
function tick(t){fr++;acc+=t-last;last=t;if(acc>1000){document.getElementById('fps').textContent=fr;fr=0;acc=0}
g.fillStyle='rgba(5,7,15,.25)';g.fillRect(0,0,W,H);
for(const p of P){p.x+=p.vx;p.y+=p.vy;if(p.x<0||p.x>W)p.vx*=-1;if(p.y<0||p.y>H)p.vy*=-1;
g.fillStyle='hsl('+((p.h+t/20)%%360)+',80%%,60%%)';g.beginPath();g.arc(p.x,p.y,3*devicePixelRatio,0,6.283);g.fill()}
requestAnimationFrame(tick)}requestAnimationFrame(tick);
</script></main></body></html>""" % (n, i + 7, n)


def page_table(rng, i):
    rows = rng.randint(1500, 3500)
    css = ("table{border-collapse:collapse;width:100%;font:13px 'Fixture Mono',Menlo,monospace}"
           "th{position:sticky;top:44px;background:#eef2f7}td,th{border-bottom:1px solid #e3e7ee;padding:4px 8px;text-align:left}"
           "tr:nth-child(even){background:#fafbfc}.ok{color:#2b8a3e}.bad{color:#c92a2a}")
    out = [PAGE_HEAD % dict(title="Orders export #%d" % i, bg="#fff", fg="#222", accent="#495057", css=css)]
    out.append('<p>Updated <b id="clock"></b> · %d rows</p><table><thead><tr><th>#</th><th>Customer</th><th>Plan</th>'
               '<th>Region</th><th>MRR</th><th>Status</th></tr></thead><tbody>' % rows)
    regions = ["us-east", "us-west", "eu-central", "ap-south", "sa-east"]
    for r in range(rows):
        ok = rng.random() < 0.85
        out.append('<tr><td>%d</td><td>%s %s</td><td>%s</td><td>%s</td><td>$%d</td><td class="%s">%s</td></tr>' % (
            r + 1, rng.choice(PEOPLE), rng.choice(TOPICS), rng.choice(["Free", "Team", "Pro", "Enterprise"]),
            rng.choice(regions), rng.randint(0, 9000), "ok" if ok else "bad", "active" if ok else "past due"))
    out.append("</tbody></table><script>setInterval(()=>{document.getElementById('clock').textContent=new Date().toLocaleTimeString()},1000)</script></main></body></html>")
    return "".join(out)


def page_gallery(rng, i, images):
    pick = rng.sample(images, min(len(images), rng.randint(6, 12)))
    css = (".g{display:grid;grid-template-columns:repeat(3,1fr);gap:12px}.g figure{margin:0;transition:transform .3s}"
           ".g figure:hover{transform:scale(1.04)}.g img{width:100%;height:220px;object-fit:cover;border-radius:8px;"
           "box-shadow:0 6px 20px rgba(0,0,0,.25)}figcaption{font:12px 'Fixture Mono',monospace;opacity:.7}")
    out = [PAGE_HEAD % dict(title="Moodboard export #%d" % i, bg="#f4f1ec", fg="#2a2420", accent="#a0522d", css=css), '<div class="g">']
    for name, size in pick:
        out.append('<figure><img src="/img/%s" alt=""><figcaption>%s · %d KB</figcaption></figure>' % (name, name, size // 1024))
    out.append("</div></main></body></html>")
    return "".join(out)


def page_dashboard(rng, i):
    css = ("@keyframes spin{to{transform:rotate(360deg)}}@keyframes pulse{50%{opacity:.35}}"
           ".grid{display:grid;grid-template-columns:repeat(4,1fr);gap:14px}.card{background:#fff;border-radius:12px;padding:14px;"
           "box-shadow:0 2px 12px rgba(20,30,60,.12)}.big{font:700 34px 'Fixture Mono',monospace}.spin{width:28px;height:28px;"
           "border:4px solid #dbe4ff;border-top-color:#4c6ef5;border-radius:50%;animation:spin 1s linear infinite;display:inline-block}"
           ".live{animation:pulse 1.4s ease-in-out infinite;color:#e03131}svg{width:100%;height:120px}")
    out = [PAGE_HEAD % dict(title="Ops dashboard #%d" % i, bg="#eef1f7", fg="#1b1f2a", accent="#1c7ed6", css=css), '<div class="grid">']
    for k in range(16):
        pts = " ".join("%d,%d" % (x * 10, 110 - int(50 + 45 * math.sin(x / 3.0 + k) * rng.random())) for x in range(31))
        out.append('<div class="card"><div>%s <span class="live">●</span> <span class="spin"></span></div>'
                   '<div class="big" data-v="%d">%d</div><svg viewBox="0 0 300 120"><polyline fill="none" stroke="#4c6ef5" '
                   'stroke-width="3" points="%s"/></svg></div>' % (rng.choice(TOPICS), rng.randint(100, 9000), rng.randint(100, 9000), pts))
    out.append("</div><script>setInterval(()=>{for(const e of document.querySelectorAll('.big')){const v=+e.dataset.v+((Math.random()*40)|0)-20;"
               "e.dataset.v=v;e.textContent=v}},500)</script></main></body></html>")
    return "".join(out)


def page_article(rng, i):
    css = ("article{max-width:760px;margin:auto;font-size:18px}h2{font:600 24px 'Fixture Mono',monospace}"
           "pre{background:#1e1e2e;color:#cdd6f4;padding:14px;border-radius:8px;font:13px 'Fixture Mono',monospace;overflow:auto}")
    out = [PAGE_HEAD % dict(title="Design doc: %s #%d" % (rng.choice(TOPICS), i), bg="#fffdf8", fg="#2b2b2b", accent="#2f9e44", css=css), "<article>"]
    for s in range(rng.randint(12, 24)):
        out.append("<h2>%d. %s</h2>" % (s + 1, sentence(rng)))
        for _ in range(rng.randint(2, 5)):
            out.append("<p>%s</p>" % " ".join("%s %s, %s." % (rng.choice(VERBS), rng.choice(NOUNS), rng.choice(QUIRKS)) for _ in range(rng.randint(3, 7))))
        if rng.random() < 0.4:
            out.append("<pre>%s</pre>" % "\n".join("fn %s_%d() -> Result&lt;()&gt; { /* %s */ }" % (rng.choice(VERBS).lower(), k, rng.choice(QUIRKS)) for k in range(6)))
    out.append("</article></main></body></html>")
    return "".join(out)


PAGE_KINDS = [("anim", page_anim), ("table", page_table), ("gallery", None), ("dashboard", page_dashboard), ("article", page_article)]


def build_www(www, rng, n_pages, log):
    """Pages and their images. Returns the list of page paths (relative to www)."""
    os.makedirs(os.path.join(www, "pages"), exist_ok=True)
    os.makedirs(os.path.join(www, "img"), exist_ok=True)
    os.makedirs(os.path.join(www, "fonts"), exist_ok=True)
    # Served images: 100 KB – 2 MB, PNG and JPEG, varied sizes.
    images = []
    specs = []
    for k in range(24):
        if k % 2 == 0:
            w = rng.choice([1600, 2000, 2400, 3000])
            specs.append(("photo-%02d.jpg" % k, "jpg", w, int(w * rng.uniform(0.56, 0.75)), rng.uniform(0.3, 1.0)))
        else:
            w = rng.choice([600, 800, 1000, 1200])
            h = int(w * rng.uniform(0.6, 0.8))
            amp = rng.choice([8, 16, 24, 48, 64])
            while amp > 4 and w * h * 3 * math.log2(amp) / 8 > 1.5e6:  # keep it under 2 MB
                amp //= 2
            specs.append(("grain-%02d.png" % k, "png", w, h, amp))
    for name, kind, w, h, p in specs:
        path = os.path.join(www, "img", name)
        if not os.path.exists(path):
            sub = random.Random("%s-%d" % (name, w))
            data = jpeg_bytes(sub, w, h, quality=90, texture=p, tex_k=12, tex_amp=6) if kind == "jpg" else noise_png(sub, w, h, int(p))
            with open(path, "wb") as f:
                f.write(data)
        images.append((name, os.path.getsize(path)))
    fav = os.path.join(www, "img", "favicon.png")
    if not os.path.exists(fav):
        r = Raster(32, 32, (59, 91, 219))
        r.rect(8, 8, 16, 16, (255, 255, 255))
        with open(fav, "wb") as f:
            f.write(r.png())
    pages = []
    for i in range(n_pages):
        kind, fn = PAGE_KINDS[i % len(PAGE_KINDS)]
        name = "pages/%s-%02d.html" % (kind, i)
        html = page_gallery(rng, i, images) if kind == "gallery" else fn(rng, i)
        with open(os.path.join(www, name), "w") as f:
            f.write(html)
        pages.append(name)
    with open(os.path.join(www, "index.html"), "w") as f:
        f.write("<!doctype html><title>canvas-big fixture</title><h1>canvas-big fixture pages</h1><ul>%s</ul>" %
                "".join('<li><a href="/%s">%s</a></li>' % (p, p) for p in pages))
    total = sum(s for _, s in images)
    log("www: %d pages, %d images (%.1f MB, %d–%d KB)" % (len(pages), len(images), total / 1e6,
        min(s for _, s in images) // 1024, max(s for _, s in images) // 1024))
    return pages


# --------------------------------------------------------------------------
# The board
# --------------------------------------------------------------------------

SCALES = {
    # frames, live, cards, images, stickies+text, checklists, timelines, arrows, comment threads
    "small": dict(frames=8, live=8, public=2, cards=10, images=30, notes=180, checklists=12, timelines=2, arrows=50, comments=8),
    "big": dict(frames=40, live=40, public=6, cards=50, images=150, notes=900, checklists=60, timelines=10, arrows=250, comments=40),
    "huge": dict(frames=100, live=100, public=6, cards=130, images=400, notes=2450, checklists=160, timelines=27, arrows=667, comments=100),
}

PUBLIC_SITES = ["https://example.com/", "https://en.wikipedia.org/wiki/Whiteboard",
                "https://developer.mozilla.org/en-US/docs/Web/API/Canvas_API", "https://www.w3.org/",
                "https://www.rust-lang.org/", "https://news.ycombinator.com/"]
CARD_SITES = ["https://github.com/", "https://www.figma.com/", "https://linear.app/", "https://www.notion.so/",
              "https://docs.python.org/3/", "https://webkit.org/blog/", "https://yjs.dev/", "https://react.dev/",
              "https://www.typescriptlang.org/docs/", "https://bun.sh/docs", "https://tailwindcss.com/docs",
              "https://developer.apple.com/documentation/webkit"]


class Board:
    def __init__(self, rng, counts, budget):
        self.rng = rng
        self.c = counts
        self.budget = budget
        self.ops = []
        self.kinds = {}
        self.by_region = {}
        self.n = 0

    def nid(self, prefix):
        self.n += 1
        return "%s-%04d" % (prefix, self.n)

    def add(self, region, kind, shape, prefix=None):
        sid = self.nid(prefix or kind[:2])
        shape = dict(shape)
        shape["id"] = sid
        self.ops.append({"op": "add", "shape": shape})
        self.kinds[kind] = self.kinds.get(kind, 0) + 1
        self.by_region.setdefault(region, []).append((sid, kind, shape))
        return sid

    def take(self, key, n=1):
        n = min(n, self.c[key])
        self.c[key] -= n
        return n

    def sticky(self, region, x, y, w=200, h=200, text=None, color=None):
        if not self.take("notes"):
            return None
        return self.add(region, "sticky", dict(type="sticky", x=round(x), y=round(y), w=w, h=h,
                        color=color or self.rng.choice(STICKY_COLORS), text=text or sticky_text(self.rng)))

    def text(self, region, x, y, text, w=600, h=60, size=None):
        if not self.take("notes"):
            return None
        s = dict(type="text", x=round(x), y=round(y), w=w, h=h, text=text)
        if size:
            s["fontSize"] = size
        return self.add(region, "text", s)

    def image(self, region, x, y, w, kind=None):
        if not self.take("images"):
            return None
        rng = self.rng
        kind = kind or rng.choice(["photo", "photo", "ui", "chart"])
        nw = rng.choice([480, 800, 1200, 1600, 2000, 2400]) if kind != "photo" else rng.choice([480, 640, 960, 1280, 1600])
        nh = int(nw * rng.choice([0.5625, 0.625, 0.75, 0.66, 1.0]))
        src, nw, nh = fit_data_image(rng, kind, nw, nh, self.budget)
        h = round(w * nh / nw)
        return self.add(region, "image", dict(type="image", x=round(x), y=round(y), w=round(w), h=h, src=src, naturalW=nw, naturalH=nh))

    def checklist(self, region, x, y, w=340):
        if not self.take("checklists"):
            return None
        rng = self.rng
        if rng.random() < 0.5:
            cols, rows = ["Done"], list(dict.fromkeys(sentence(rng) for _ in range(rng.randint(3, 9))))  # labels must be unique
        else:
            cols, rows = rng.choice([["Yes", "No"], ["Yes", "No", "Maybe"], ["P0", "P1", "P2"]]), rng.sample(PEOPLE, rng.randint(4, 12))
        picks = {r: rng.choice(cols) for r in rows if rng.random() < 0.55}
        s = dict(type="checklist", x=round(x), y=round(y), w=w, title=rng.choice(["Launch checklist", "Who's in?", "Sprint %d" % rng.randint(30, 60),
                 "Offsite RSVP", "Release gates", "%s tasks" % rng.choice(TOPICS)]), columns=cols, rows=rows, picks=picks)
        if rng.random() < 0.3:
            s["notes"] = {rows[0]: rng.choice(QUIRKS)}
        return self.add(region, "checklist", s)

    def timeline(self, region, x, y, w=1400, h=380):
        if not self.take("timelines"):
            return None
        rng = self.rng
        m0 = rng.randint(1, 6)
        start = "2026-%02d-01" % m0
        end = "2027-%02d-01" % rng.randint(1, 6)
        items = []
        for k in range(rng.randint(4, 10)):
            mm = (m0 + k) % 12 + 1
            yy = 2026 + (m0 + k) // 12
            it = {"date": "%d-%02d-%02d" % (yy, mm, rng.randint(1, 27)), "label": "%s %s" % (rng.choice(VERBS), rng.choice(TOPICS).lower())}
            if rng.random() < 0.3:
                it["text"] = rng.choice(QUIRKS)
            if rng.random() < 0.15:
                it["end"] = "%d-%02d-28" % (yy + (1 if mm == 12 else 0), mm % 12 + 1)
            items.append(it)
        return self.add(region, "timeline", dict(type="timeline", x=round(x), y=round(y), w=w, h=h, title="%s timeline" % rng.choice(TOPICS),
                        start=start, end=end, step="month", items=items))

    def card(self, region, x, y, url, title=None):
        if not self.take("cards"):
            return None
        s = dict(type="link", x=round(x), y=round(y), w=300, h=84, url=url)
        if title:
            s["title"] = title
        return self.add(region, "link", s)


def layout(board, base, pages, seed, log):
    rng = board.rng
    c0 = dict(board.c)
    focus = []

    # ---- 1. The deck: slide frames in a grid, content inside --------------
    SW, SH, GAP = 1280, 720, 160
    n_frames = board.c["frames"]
    cols = 10 if n_frames > 60 else min(8, n_frames)
    deck_rows = (n_frames + cols - 1) // cols
    deck_w = cols * SW + (cols - 1) * GAP
    deck_h = deck_rows * SH + (deck_rows - 1) * GAP
    board.text("deck", 0, -260, "# Q4 planning deck", w=1600, h=140, size=96)
    # Notes the deck may use: about a quarter of the budget.
    deck_notes = int(c0["notes"] * 0.25)
    notes_before = board.c["notes"]
    slides = []
    for i in range(n_frames):
        x = (i % cols) * (SW + GAP)
        y = (i // cols) * (SH + GAP)
        topic = TOPICS[i % len(TOPICS)]
        fr = dict(type="frame", x=x, y=y, w=SW, h=SH, title="%d · %s" % (i + 1, topic))
        if i % 9 == 0:
            src, nw, nh = fit_data_image(rng, "photo", 1280, 720, board.budget)
            fr["image"] = {"src": src, "naturalW": nw, "naturalH": nh}
        board.take("frames")
        fid = board.add("deck", "frame", fr, prefix="fr")
        slides.append(fid)
        if "image" in fr:
            board.text("deck", x + 60, y + 520, "## %s\n%s" % (topic, sentence(rng)), w=900, h=140, size=40)
            continue
        if notes_before - board.c["notes"] > deck_notes:
            board.text("deck", x + 60, y + 50, "## %s" % topic, w=800, h=70, size=44)
            continue
        board.text("deck", x + 60, y + 40, "## %s" % topic, w=800, h=70, size=44)
        t = i % 5
        if t == 0:
            board.text("deck", x + 60, y + 150, "\n".join("- %s" % sentence(rng) for _ in range(rng.randint(3, 6))), w=560, h=420, size=26)
            board.image("deck", x + 680, y + 150, 540, kind=rng.choice(["chart", "ui", "photo"]))
        elif t == 1:
            for k in range(6):
                board.sticky("deck", x + 60 + (k % 3) * 400 + rng.randint(-10, 10), y + 160 + (k // 3) * 260 + rng.randint(-8, 8), 240, 220)
        elif t == 2:
            board.image("deck", x + 60, y + 150, 700, kind="chart")
            board.sticky("deck", x + 820, y + 160, 380, 200)
            board.sticky("deck", x + 820, y + 400, 380, 200)
        elif t == 3:
            if board.checklist("deck", x + 60, y + 150, 520) is None:
                board.sticky("deck", x + 60, y + 150, 520, 300)
            board.text("deck", x + 640, y + 150, "**Owner:** %s\n\n%s\n\n_%s_" % (rng.choice(PEOPLE), sentence(rng), rng.choice(QUIRKS)), w=560, h=300, size=24)
        else:
            for k in range(3):
                board.sticky("deck", x + 60 + k * 400, y + 170, 340, 260)
            board.card("deck", x + 60, y + 500, rng.choice(CARD_SITES))
            board.card("deck", x + 420, y + 500, rng.choice(CARD_SITES))

    # ---- 2. The web wall: live frames --------------------------------------
    WW, WH, WG = 960, 640, 120
    n_live = board.c["live"]
    n_public = min(c0["public"], n_live)
    wcols = 10 if n_live > 60 else min(8, n_live)
    wall_y = deck_h + 900
    board.text("wall", 0, wall_y - 260, "# Research wall (live)", w=1600, h=140, size=96)
    lives = []
    public_slots = set(int(k * n_live / max(1, n_public)) + 1 for k in range(n_public)) if n_public else set()
    pub = 0
    for i in range(n_live):
        x = (i % wcols) * (WW + WG)
        y = wall_y + (i // wcols) * (WH + WG + 80)
        if i in public_slots and pub < n_public:
            url, title = PUBLIC_SITES[pub], None
            pub += 1
        else:
            page = pages[i % len(pages)]
            url, title = "%s/%s?f=%d" % (base, page, i), None
        s = dict(type="link", live=True, x=x, y=y, w=WW, h=WH, url=url)
        board.take("live")
        lives.append(board.add("wall", "live", s, prefix="wf"))
        if i % 3 == 0:
            board.sticky("wall", x + WW - 120, y - 70, 220, 120, text="%s — %s" % (rng.choice(PEOPLE), rng.choice(QUIRKS)), color="pink")
    wall_rows = (n_live + wcols - 1) // wcols
    wall_w = wcols * WW + (wcols - 1) * WG
    wall_h = wall_rows * (WH + WG + 80)

    # Focus (the bench view): three live frames of the wall's first row and the
    # slide above them — frames ~340 px wide on a 1440 px board, so a live budget applies.
    mid = cols // 2
    focus.append(slides[min(len(slides) - 1, (deck_rows - 1) * cols + min(mid, cols - 1) - 1)])
    focus += [lives[max(0, min(len(lives) - 1, mid + k))] for k in range(-1, 2)]

    # ---- 3. Brainstorm: sticky clusters, right of the deck ----------------
    bx0 = max(deck_w, wall_w) + 1400
    by0 = 0
    reserve = 30 + c0["checklists"] // 4
    clusters = []
    ccols, cell_w = 5, 1700
    cx_i, cy, row_h = 0, by0, 0
    board.text("brain", bx0, by0 - 260, "# Brainstorm", w=1200, h=140, size=96)
    while board.c["notes"] > reserve:
        n = min(rng.randint(12, 28), board.c["notes"] - reserve)
        if n <= 1:
            break
        k = rng.randint(4, 6)
        x0 = bx0 + cx_i * cell_w
        head = board.text("brain", x0, cy, "### %s" % rng.choice(TOPICS), w=700, h=60, size=40)
        members = []
        for j in range(n - 1):
            sx = x0 + (j % k) * 236 + rng.randint(-14, 14)
            sy = cy + 100 + (j // k) * 236 + rng.randint(-14, 14)
            sid = board.sticky("brain", sx, sy, 200 + rng.randint(-10, 30), 200 + rng.randint(-10, 30))
            if sid:
                members.append(sid)
        clusters.append((head, members))
        h = 100 + ((n - 2) // k + 1) * 236 + 260
        row_h = max(row_h, h)
        cx_i += 1
        if cx_i == ccols:
            cx_i, cy, row_h = 0, cy + row_h, 0
    brain_bottom = cy + row_h

    # ---- 4. Moodboard: images, masonry, below the brainstorm ---------------
    mx0, my0 = bx0, brain_bottom + 900
    board.text("mood", mx0, my0 - 260, "# Moodboard", w=1200, h=140, size=96)
    mcols = 8 if c0["images"] > 60 else 5
    col_y = [my0] * mcols
    mood = []
    while board.c["images"] > 0:
        cidx = min(range(mcols), key=lambda q: col_y[q])
        w = rng.choice([360, 420, 480, 520])
        sid = board.image("mood", mx0 + cidx * 560, col_y[cidx], w)
        if not sid:
            break
        mood.append(sid)
        col_y[cidx] += board.by_region["mood"][-1][2]["h"] + 40
        if rng.random() < 0.12 and board.c["notes"] > 0:
            board.sticky("mood", mx0 + cidx * 560 + w - 140, col_y[cidx] - 120, 180, 150, color="white")

    # ---- 5. Planning: checklists, timelines, cards — below the wall --------
    px0, py0 = 0, wall_y + wall_h + 900
    board.text("plan", px0, py0 - 260, "# Planning", w=1200, h=140, size=96)
    tl = []
    ty = py0
    while board.c["timelines"] > 0:
        tl.append(board.timeline("plan", px0, ty, 1600, 400))
        ty += 480
    checks = []
    qx, qy, qrow = px0 + 1800, py0, 0
    while board.c["checklists"] > 0:
        checks.append(board.checklist("plan", qx, qy))
        qx += 400
        qrow += 1
        if qrow == 10:
            qx, qy, qrow = px0 + 1800, qy + 620, 0
    cy2 = max(ty, qy + 700)
    k = 0
    while board.c["cards"] > 0:
        board.card("plan", px0 + (k % 12) * 340, cy2 + (k // 12) * 120, CARD_SITES[k % len(CARD_SITES)])
        k += 1
    while board.c["notes"] > 0:
        board.sticky("plan", px0 + (k % 12) * 340, cy2 + 200 + (k // 12) * 240, 220, 200)
        k += 1

    # ---- 6. Arrows ---------------------------------------------------------
    arrows = c0["arrows"]
    made = 0
    seen = set()

    def connect(a, b, label=None, color=None):
        nonlocal made
        if made >= arrows or not a or not b or a == b or (a, b) in seen:
            return
        seen.add((a, b))
        op = {"op": "connect", "id": board.nid("ar"), "from": a, "to": b}
        if label:
            op["label"] = label
        if color:
            op["color"] = color
        board.ops.append(op)
        board.kinds["arrow"] = board.kinds.get("arrow", 0) + 1
        made += 1

    for a, b in zip(slides, slides[1:]):
        connect(a, b, "next" if rng.random() < 0.2 else None)
    cross_every = 6
    rounds = 0
    while made < arrows and rounds < 20:
        rounds += 1
        for ci, (head, members) in enumerate(clusters):
            if made >= arrows:
                break
            if len(members) >= 3:
                j = rng.randint(0, len(members) - 3)
                connect(members[j], members[j + 1])
                connect(members[j + 1], members[j + 2], rng.choice([None, None, "then", "blocks", "why?"]))
            if ci % cross_every == 0:
                connect(head, rng.choice(slides), "see slide", "blue")
                if lives:
                    connect(rng.choice(members) if members else head, rng.choice(lives), "source", "purple")
        if checks and tl:
            connect(rng.choice([c for c in checks if c]), rng.choice([t for t in tl if t]), "feeds")
        if mood:
            connect(rng.choice(mood), rng.choice(slides), "used in")

    # ---- 7. Comment threads -------------------------------------------------
    pool = [sid for region in ("deck", "wall", "brain", "mood", "plan") for sid, kind, _ in board.by_region.get(region, [])
            if kind in ("sticky", "frame", "live", "image", "checklist", "timeline")]
    threads = replies = resolved = 0
    for t in range(c0["comments"]):
        on = slides[t % len(slides)] if t % 4 == 0 else rng.choice(pool)
        tid = "cm-%03d" % (t + 1)
        board.ops.append({"op": "comment", "id": tid, "on": on, "text": rng.choice(COMMENT_LINES)})
        threads += 1
        for _ in range(rng.randint(0, 3)):
            board.ops.append({"op": "reply", "thread": tid, "text": "%s — %s" % (rng.choice(PEOPLE), rng.choice(COMMENT_LINES))})
            replies += 1
        if rng.random() < 0.25:
            board.ops.append({"op": "resolve", "thread": tid, "resolved": True})
            resolved += 1

    bounds = dict(x=-200, y=-400, w=max(bx0 + ccols * cell_w, mx0 + mcols * 560), h=max(max(col_y), cy2 + 2000))
    return dict(focusIds=focus, comments=dict(threads=threads, replies=replies, resolved=resolved), bounds=bounds,
                regions={r: len(v) for r, v in board.by_region.items()})


def batches(ops, max_ops, max_bytes):
    cur, size = [], 0
    for op in ops:
        s = len(json.dumps(op, separators=(",", ":")))
        if cur and (len(cur) >= max_ops or size + s > max_bytes):
            yield cur
            cur, size = [], 0
        cur.append(op)
        size += s + 1
    if cur:
        yield cur


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--scale", choices=sorted(SCALES), default="big")
    ap.add_argument("--seed", type=int, default=20261016)
    ap.add_argument("--out", default=os.path.join(HERE, "out"))
    ap.add_argument("--base", default="http://127.0.0.1:8765", help="where serve.sh serves the pages")
    ap.add_argument("--max-ops", type=int, default=200)
    ap.add_argument("--max-batch-bytes", type=int, default=600_000, help="serialized ops per batch (macOS ARG_MAX is 1 MB)")
    ap.add_argument("--max-data-url", type=int, default=110_000, help="chars per board image (Linux argv strings max 128 KB)")
    ap.add_argument("--www-only", action="store_true", help="only (re)build out/www")
    ap.add_argument("-q", "--quiet", action="store_true")
    a = ap.parse_args(argv)
    log = (lambda *_: None) if a.quiet else (lambda m: print("gen: " + m, file=sys.stderr))
    base = a.base.rstrip("/")
    counts = dict(SCALES[a.scale])
    n_local = max(1, counts["live"] - counts["public"])
    www = os.path.join(a.out, "www")
    # Pages depend only on (seed, index), so scales share one www folder.
    pages = []
    os.makedirs(www, exist_ok=True)
    img_rng = random.Random(a.seed * 7 + 1)
    pages = build_www(www, img_rng, max(n_local, 34), log)
    if a.www_only:
        return 0
    board = Board(random.Random(a.seed), counts, a.max_data_url)
    info = layout(board, base, pages, a.seed, log)
    out = os.path.join(a.out, a.scale)
    os.makedirs(out, exist_ok=True)
    for f in os.listdir(out):
        if f.startswith("ops-") and f.endswith(".json"):
            os.remove(os.path.join(out, f))
    files = []
    for i, b in enumerate(batches(board.ops, a.max_ops, a.max_batch_bytes)):
        name = "ops-%03d.json" % (i + 1)
        data = json.dumps(b, separators=(",", ":"))
        with open(os.path.join(out, name), "w") as f:
            f.write(data)
        files.append(dict(file=name, ops=len(b), bytes=len(data)))
    shapes = sum(v for k, v in board.kinds.items())
    manifest = dict(scale=a.scale, seed=a.seed, base=base, shapes=shapes, kinds=board.kinds, ops=len(board.ops),
                    batches=files, www=dict(pages=len(pages)), **info)
    with open(os.path.join(out, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=1)
    big = max(len(json.dumps(o)) for o in board.ops)
    log("%s: %d shapes %s, %d ops in %d batches (largest op %d chars, largest batch %d bytes) -> %s" % (
        a.scale, shapes, json.dumps(board.kinds, sort_keys=True), len(board.ops), len(files), big,
        max(f["bytes"] for f in files), out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
