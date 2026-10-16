#!/usr/bin/env python3
"""Drive a PROBE Copper with the canvas-big fixture (used by apply.sh / measure.sh).

    drive.py apply NAME [SCALE]      create canvas NAME, apply every batch, focus, read back
    drive.py measure [--shot PATH]   run measure.js in the front tab (two-phase), print JSON

Talks to Copper only through its CLI (`$COPPER_BIN call …` / `eval` / `shot`),
which honours SEARCH_PROBE / SEARCH_MCP_PORT (macOS) and COPPER_WORLD /
SEARCH_MCP_PORT (Linux). The wrappers refuse to run without a probe world.
"""
import json
import os
import platform
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.environ.get("FIXTURE_OUT", os.path.join(HERE, "out"))
ARG_CHUNK = 100_000  # Linux caps ONE argv string at 128 KB (MAX_ARG_STRLEN); the CLI joins args with spaces


def copper():
    c = os.environ.get("COPPER_BIN")
    if not c:
        sys.exit("drive: COPPER_BIN is not set (apply.sh/measure.sh set it)")
    return c


def run(argv, timeout=180):
    t = time.time()
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout, p.stderr, time.time() - t
    except subprocess.TimeoutExpired as e:
        return 124, e.stdout or "", "drive: CLI timed out after %ds" % timeout, time.time() - t


def call(tool, args, ops=None):
    """`copper call TOOL JSON`, the JSON split into argv strings at op boundaries."""
    head = json.dumps(args, separators=(",", ":"))
    if ops is None:
        chunks = [head]
    else:
        prefix = head[:-1] + ("," if len(args) else "") + '"ops":['
        chunks, cur = [], prefix
        for i, op in enumerate(ops):
            s = json.dumps(op, separators=(",", ":")) + ("," if i < len(ops) - 1 else "")
            if len(cur) + len(s) > ARG_CHUNK and cur != prefix:
                chunks.append(cur)
                cur = ""
            cur += s
        chunks.append(cur + "]}")
    return run([copper(), "call", tool] + chunks)


def parse(text):
    try:
        return json.loads(text)
    except Exception:
        return None


def short(s, n=600):
    s = (s or "").strip()
    return s if len(s) <= n else s[:n] + "… (%d chars)" % len(s)


def find_id(obj):
    if isinstance(obj, dict):
        if isinstance(obj.get("id"), str):
            return obj["id"]
        for k in ("canvas", "summary"):
            if k in obj:
                r = find_id(obj[k])
                if r:
                    return r
    return None


def apply(name, scale):
    man_path = os.path.join(OUT, scale, "manifest.json")
    if not os.path.exists(man_path):
        subprocess.check_call([sys.executable, os.path.join(HERE, "gen.py"), "--scale", scale, "--out", OUT])
    man = json.load(open(man_path))
    report = dict(name=name, scale=scale, expectedShapes=man["shapes"], kinds=man["kinds"], batches=[], failures=[],
                  started=time.strftime("%Y-%m-%dT%H:%M:%S"), platform=platform.system(),
                  probe=os.environ.get("SEARCH_PROBE") or os.environ.get("COPPER_WORLD"), port=os.environ.get("SEARCH_MCP_PORT"))
    print("apply: %s — %d shapes (%s), %d ops in %d batches" % (name, man["shapes"], ", ".join("%s %d" % kv for kv in sorted(man["kinds"].items())),
          man["ops"], len(man["batches"])))

    rc, out, err, dt = call("canvas_create", {"name": name, "reason": "canvas-big fixture: create the board"})
    created = parse(out)
    cid = find_id(created) if created else None
    print("create: rc=%d %.2fs id=%s" % (rc, dt, cid))
    if rc != 0 or not cid:
        report["failures"].append(dict(step="canvas_create", rc=rc, seconds=round(dt, 2), stdout=short(out), stderr=short(err)))
        finish(report, scale, name)
        sys.exit("apply: canvas_create failed: %s %s" % (short(out), short(err)))
    report["canvasId"] = cid
    rc, out, err, dt = call("canvas_open", {"id": cid, "foreground": True, "reason": "canvas-big fixture: show the board"})
    print("open: rc=%d %.2fs %s" % (rc, dt, short(err or "", 200)))
    if rc != 0:
        report["failures"].append(dict(step="canvas_open", rc=rc, seconds=round(dt, 2), stdout=short(out), stderr=short(err)))

    total_t = 0.0
    applied = 0
    for b in man["batches"]:
        ops = json.load(open(os.path.join(OUT, scale, b["file"])))
        rc, out, err, dt = call("canvas_apply", {"id": cid, "reason": "canvas-big fixture %s" % b["file"]}, ops)
        total_t += dt
        res = parse(out) or {}
        errs = res.get("errors") or []
        ok = res.get("applied", 0)
        applied += ok
        line = dict(file=b["file"], ops=len(ops), bytes=b["bytes"], rc=rc, seconds=round(dt, 2), applied=ok, errors=len(errs))
        report["batches"].append(line)
        print("batch %s: %3d ops %7d B  rc=%d  %6.2fs  applied=%s errors=%d%s" % (
            b["file"], len(ops), b["bytes"], rc, dt, ok, len(errs), ("  " + short(err, 300)) if rc else ""))
        if rc != 0 or errs:
            report["failures"].append(dict(step="canvas_apply " + b["file"], rc=rc, seconds=round(dt, 2),
                                           errors=errs[:8], stdout=short(out) if not res else None, stderr=short(err)))
            for e in errs[:3]:
                print("    error: %s" % json.dumps(e))
    report["applyTotalSeconds"] = round(total_t, 2)
    report["applied"] = applied

    if man.get("focusIds") and os.environ.get("FIXTURE_NO_FOCUS") != "1":
        rc, out, err, dt = call("canvas_focus", {"id": cid, "shapeIds": man["focusIds"], "reason": "canvas-big fixture: the bench view"})
        print("focus: rc=%d %.2fs %s" % (rc, dt, short(err, 200)))
        if rc != 0:
            report["failures"].append(dict(step="canvas_focus", rc=rc, seconds=round(dt, 2), stdout=short(out), stderr=short(err)))

    rc, out, err, dt = call("canvas_read", {"id": cid, "reason": "canvas-big fixture: count what landed"})
    res = parse(out)
    shapes = len(res.get("shapes", [])) if isinstance(res, dict) else None
    report["read"] = dict(rc=rc, seconds=round(dt, 2), bytes=len(out), shapes=shapes,
                          total=res.get("total") if isinstance(res, dict) else None,
                          next=bool(res.get("next")) if isinstance(res, dict) else None,
                          comments=len(res.get("comments", [])) if isinstance(res, dict) else None)
    print("read: rc=%d %.2fs %d bytes shapes=%s total=%s comments=%s%s" % (
        rc, dt, len(out), shapes, report["read"]["total"], report["read"]["comments"], ("  " + short(err, 300)) if rc else ""))
    if rc != 0 or res is None:
        report["failures"].append(dict(step="canvas_read", rc=rc, seconds=round(dt, 2), stdout=short(out), stderr=short(err)))
    finish(report, scale, name)
    print("summary: applied %d/%d ops in %.1fs; read back %s shapes (expected %d); %d failure(s)" % (
        applied, man["ops"], total_t, shapes, man["shapes"], len(report["failures"])))


def finish(report, scale, name):
    path = os.path.join(OUT, scale, "apply-%s-%s.json" % (name.replace("/", "_").replace(" ", "_"), time.strftime("%Y%m%d-%H%M%S")))
    with open(path, "w") as f:
        json.dump(report, f, indent=1)
    print("report: %s" % path)


def _rss_mb(pid):
    p = subprocess.run(["ps", "-o", "rss=", "-p", str(pid)], capture_output=True, text=True)
    return round(int(p.stdout.strip() or 0) / 1024, 1)


def webcontent_rss():
    """macOS: the probe's own WebKit processes and their RSS. `launchctl print
    pid/<app pid>` lists the app's XPC service instances (WebContent, GPU,
    Networking) with their pids — exact, even with other Coppers running.
    Falls back to WebContent processes started after FIXTURE_PROBE_STARTED."""
    if platform.system() != "Darwin":
        return None
    port = os.environ.get("SEARCH_MCP_PORT", "")
    app = subprocess.run(["lsof", "-tiTCP:%s" % port, "-sTCP:LISTEN"], capture_output=True, text=True).stdout.split()
    if app:
        out = subprocess.run(["launchctl", "print", "pid/%s" % app[0]], capture_output=True, text=True).stdout
        procs = []
        for line in out.splitlines():
            parts = line.split()
            if len(parts) >= 3 and parts[-1].startswith("com.apple.WebKit.") and parts[0].isdigit() and parts[0] != "0":
                kind = parts[-1].split(".")[3]
                procs.append(dict(pid=int(parts[0]), kind=kind, rssMB=_rss_mb(parts[0])))
        if procs:
            wc = [p for p in procs if p["kind"] == "WebContent"]
            return dict(processes=len(wc), totalMB=round(sum(p["rssMB"] for p in wc), 1), appMB=_rss_mb(app[0]),
                        gpuMB=round(sum(p["rssMB"] for p in procs if p["kind"] == "GPU"), 1),
                        networkMB=round(sum(p["rssMB"] for p in procs if p["kind"] == "Networking"), 1),
                        top=sorted(wc, key=lambda r: -r["rssMB"])[:8], filter="launchctl print pid/%s (the probe's own)" % app[0])
    since = os.environ.get("FIXTURE_PROBE_STARTED")  # epoch seconds
    p = subprocess.run(["ps", "-ax", "-o", "pid=,rss=,etime=,command="], capture_output=True, text=True)
    now = time.time()
    rows = []
    for line in p.stdout.splitlines():
        if "com.apple.WebKit.WebContent" not in line:
            continue
        parts = line.split(None, 3)
        pid, rss, et = int(parts[0]), int(parts[1]), parts[2]
        secs = 0
        d = 0
        if "-" in et:
            d, et = et.split("-")
        for x in et.split(":"):
            secs = secs * 60 + int(x)
        secs += int(d) * 86400
        if since and now - secs < float(since) - 2:
            continue
        rows.append(dict(pid=pid, rssMB=round(rss / 1024, 1)))
    return dict(processes=len(rows), totalMB=round(sum(r["rssMB"] for r in rows), 1), top=sorted(rows, key=lambda r: -r["rssMB"])[:8],
                filter="started after FIXTURE_PROBE_STARTED" if since else "ALL WebContent processes on this Mac (set FIXTURE_PROBE_STARTED)")


def measure(shot=None):
    js = open(os.path.join(HERE, "measure.js")).read()
    rc, out, err, dt = run([copper(), "eval", js], timeout=60)
    first = parse(out)
    if rc != 0 or not isinstance(first, dict):
        sys.exit("measure: eval failed rc=%d: %s %s" % (rc, short(out), short(err)))
    if first.get("state") == "done":  # a finished run nobody read: take it, start a new one
        rc, out, err, dt = run([copper(), "eval", js], timeout=60)
        first = parse(out) or {}
    if first.get("state") != "started":
        sys.exit("measure: unexpected answer %s" % short(out))
    time.sleep(6.5)
    res = None
    for _ in range(40):
        rc, out, err, dt = run([copper(), "eval", js], timeout=60)
        res = parse(out)
        if isinstance(res, dict) and res.get("state") == "done":
            break
        time.sleep(0.5)
    if not isinstance(res, dict) or res.get("state") != "done":
        sys.exit("measure: run never finished: %s %s" % (short(out), short(err)))
    res["webContent"] = webcontent_rss()
    if shot:
        rc, out, err, dt = run([copper(), "shot", shot], timeout=60)
        res["screenshot"] = shot if rc == 0 else "failed: %s" % short(err)
    print(json.dumps(res, indent=1))


def main():
    a = sys.argv[1:]
    if not a or a[0] not in ("apply", "measure"):
        sys.exit(__doc__)
    if a[0] == "apply":
        if len(a) < 2:
            sys.exit("usage: drive.py apply NAME [small|big|huge]")
        apply(a[1], a[2] if len(a) > 2 else "big")
    else:
        shot = a[a.index("--shot") + 1] if "--shot" in a else None
        measure(shot)


if __name__ == "__main__":
    main()
