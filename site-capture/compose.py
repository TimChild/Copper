#!/usr/bin/env python3
"""Present real Copper window captures on a warm backdrop with a macOS-style shadow.
compose.py still IN.png OUT.png [--theme light|dark]
compose.py video FRAMEDIR OUT.mp4 --start T --end T [--fps 30] [--theme ..] [--fade S]
"""
import json, sys, subprocess, random
from PIL import Image, ImageFilter, ImageDraw, ImageChops

CW, CH = 2240, 1480          # canvas: 2x of 1120x740 CSS px
WS = None                     # fit window to 2016 px wide
WX, WY = 112, 84

def lerp(a, b, t): return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))

def backdrop(theme):
    if theme == 'dark':
        top, bot, glow = (58, 42, 32), (24, 18, 14), (150, 92, 52)
    else:
        top, bot, glow = (240, 222, 203), (205, 150, 108), (255, 244, 230)
    g = Image.new('RGB', (1, CH))
    for y in range(CH): g.putpixel((0, y), lerp(top, bot, (y / CH) ** 1.1))
    bg = g.resize((CW, CH))
    # soft light behind the window's top edge
    m = Image.new('L', (CW, CH), 0); d = ImageDraw.Draw(m)
    d.ellipse((CW * 0.12, -CH * 0.35, CW * 0.88, CH * 0.55), fill=150 if theme != 'dark' else 90)
    m = m.filter(ImageFilter.GaussianBlur(220))
    bg = Image.composite(Image.new('RGB', (CW, CH), glow), bg, m)
    # a whisper of grain, fixed seed so every frame matches (cheap in P-frames)
    rnd = random.Random(7); n = Image.effect_noise((CW // 2, CH // 2), 10).resize((CW, CH))
    bg = Image.blend(bg, Image.merge('RGB', (n, n, n)), 0.025)
    return bg

def shadow_layer(alpha, theme):
    """macOS-like window shadow from the window's own alpha (corners included)."""
    W, H = alpha.size
    canvas = Image.new('RGBA', (CW, CH), (0, 0, 0, 0))
    k = 1.0 if theme != 'dark' else 1.25
    for dy, blur, op in [(46, 70, 0.42 * k), (10, 16, 0.22 * k), (1, 1.5, 0.28 * k)]:
        a = Image.new('L', (CW, CH), 0); a.paste(alpha, (WX, WY + dy))
        a = a.filter(ImageFilter.GaussianBlur(blur)).point(lambda v: int(v * min(op, 1)))
        layer = Image.new('RGBA', (CW, CH), (20, 10, 4, 0)); layer.putalpha(a)
        canvas = Image.alpha_composite(canvas, layer)
    return canvas

def place(win, base):
    out = base.copy(); out.alpha_composite(win, (WX, WY)); return out

def prep(path):
    im = Image.open(path).convert('RGBA')
    ws = WS or 2016 / im.width
    im = im.resize((round(im.width * ws), round(im.height * ws)), Image.LANCZOS)
    # hairline ring like macOS draws around a window
    a = im.split()[3]
    ring = a.filter(ImageFilter.MaxFilter(3))
    ring = ImageChops.subtract(ring, a).point(lambda v: int(v * 0.16))
    r = Image.new('RGBA', im.size, (0, 0, 0, 0)); r.putalpha(ring)
    return im, r

def make_base(first, theme):
    im, _ = prep(first)
    bg = backdrop(theme).convert('RGBA')
    return Image.alpha_composite(bg, shadow_layer(im.split()[3], theme))

def frame(path, base):
    im, ring = prep(path)
    out = base.copy(); out.alpha_composite(ring, (WX, WY)); out.alpha_composite(im, (WX, WY))
    return out.convert('RGB')

def arg(name, default=None):
    return sys.argv[sys.argv.index(name) + 1] if name in sys.argv else default

if __name__ == '__main__':
    mode, src, out = sys.argv[1], sys.argv[2], sys.argv[3]
    theme = arg('--theme', 'light')
    if mode == 'still':
        base = make_base(src, theme); frame(src, base).save(out)
        sys.exit(0)
    frames = json.load(open(src + '/frames.json'))
    t0, t1 = float(arg('--start')), float(arg('--end')); fps = int(arg('--fps', '30'))
    fade = float(arg('--fade', '0')); speed = float(arg('--speed', '1'))
    base = make_base(frames[0][1], theme)
    cache = {}
    def get(p):
        if p not in cache:
            if len(cache) > 6: cache.pop(next(iter(cache)))
            cache[p] = frame(p, base)
        return cache[p]
    def at(t):
        prev = frames[0]
        for f in frames:
            if f[0] <= t: prev = f
            else:
                nxt = f; break
        else:
            return get(prev[1])
        a = get(prev[1]);
        if nxt[0] - prev[0] > 0.6: return a
        # hold the real frame, then a short dissolve into the next one
        XF = 0.07; w = (t - (nxt[0] - XF)) / XF
        if w <= 0: return a
        return Image.blend(a, get(nxt[1]), max(0, min(1, w)))
    rot = arg('--rotate')
    segs = [(float(rot), t1), (t0, float(rot))] if rot else [(t0, t1)]
    times = []
    for a, b in segs:
        k = int((b - a) / speed * fps)
        times.append([a + i * speed / fps for i in range(k)])
    ff = subprocess.Popen(['ffmpeg', '-loglevel', 'error', '-y', '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-s', f'{CW}x{CH}', '-r', str(fps), '-i', '-',
                           '-an', '-c:v', 'libx264', '-preset', 'veryslow', '-crf', arg('--crf', '26'), '-tune', 'film',
                           '-pix_fmt', 'yuv420p', '-movflags', '+faststart', '-x264-params', 'keyint=600:min-keyint=600', out], stdin=subprocess.PIPE)
    fadeN = int(fade * fps); n = 0
    first = at(times[0][0])
    for si, seg in enumerate(times):
        nxt_first = at(times[si + 1][0]) if si + 1 < len(times) else first
        for i, t in enumerate(seg):
            im = at(t)
            if fadeN and i >= len(seg) - fadeN and (rot is None or si == 0):
                im = Image.blend(im, nxt_first, (i - (len(seg) - fadeN) + 1) / fadeN)
            ff.stdin.write(im.tobytes()); n += 1
    ff.stdin.close(); ff.wait()
    first.save(out.rsplit('.', 1)[0] + '.poster.png')
    print('frames', n)
