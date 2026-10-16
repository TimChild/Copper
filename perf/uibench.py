#!/usr/bin/env python3
"""The UI bench: a made-up SaaS console (perf/uibench/app.html) driven by
`jev_run`, one arm per way of running Jev, so the arms can be compared on
clicking buttons, filling forms and getting through dialogs — not on a site's
servers or long articles.

    python3 perf/uibench/server.py &                 # the app, on :8777
    perf/uibench.py --world "Copper (dev)" --port 4124 --rounds 3
    perf/uibench.py --arms classic,turbo --tasks login,whack
    perf/uibench.py --summary perf/results/uibench.jsonl

A pass is the app's own verdict (its server records what was done), not Jev's
DONE. Per run: wall_ms (jev_run's clock, first decision to the end),
success_ms (page load to the app's success event), actions, decisions, APM
(actions per minute of wall time), wrong clicks the app saw, and where the
time went (observe, decide, act, settle; Jev and text-model latency inside).
"""

import argparse
import json
import os
import random
import statistics
import sys
import time
import urllib.error
import urllib.request
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from wikigame import Copper, median, fmt  # noqa: E402

TASKS = {
    "login": ('Sign in with the work email "maya@northwind.test" and the access code "482915". Stop when the dashboard shows.', 3),
    "settings": ('Open Settings, turn on Two-factor authentication, change the language to "Deutsch", and save the changes. Leave the other settings as they are.', 4),
    "project": ('Create a new project named "Apollo" in the region "EU Central (Frankfurt)" with Team visibility.', 6),
    "checkout": ("Check out with Express shipping, accept the terms of sale, and place the order. Do not sign up for product news.", 5),
    "invoices": ('Approve invoice "INV-1042" and nothing else.', 2),
    "files": ('Delete the file "budget-2026.xlsx" and nothing else.', 2),
    "whack": ("Click the button the prompt names, again and again, until the page says All done.", 12),
    "swatches": ("Click the square of the colour the prompt names, again and again, until the page says All done.", 8),
}

ARMS = {
    # explicit, so a change of Copper's defaults never changes an arm
    "classic": {"strategy": "classic", "vision": "off"},
    "fast": {"strategy": "fast", "vision": "off"},
    "literal": {"strategy": "fast,literal", "vision": "off"},
    "burst": {"strategy": "fast,burst", "vision": "off"},
    "turbo": {"strategy": "turbo", "vision": "off"},
    "turbo-1.14": {"strategy": "turbo", "model": "jev-1.14.0", "vision": "off"},
    "marks-turbo": {"strategy": "turbo", "vision": "marks"},
    "box-turbo": {"strategy": "turbo", "vision": "box"},
    "pixels": {"strategy": "turbo", "vision": "pixels"},
    "llm-haiku": {"strategy": "fast,llm=haiku", "vision": "off"},
    # the hybrid: text turbo, a numbered picture only when the page is ambiguous
    "hybrid": {"strategy": "turbo", "vision": "auto"},
    "hybrid-1.14": {"strategy": "turbo", "vision": "auto", "model": "jev-1.14.0"},
    # whatever this Copper does with nothing said (Settings' Fast mode and What Jev sees)
    "default": {},
}


def app_result(base, sid):
    try:
        with urllib.request.urlopen(f"{base}/api/result?sid={sid}", timeout=10) as r:
            return json.load(r)
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError):
        return {"ok": False, "done": False, "wrong": 0, "events": []}


def play(copper, base, task, arm, max_steps):
    goal, optimal = TASKS[task]
    sid = f"{task}-{arm}-{uuid.uuid4().hex[:8]}"
    args = {"goal": goal, "url": f"{base}/app?task={task}&sid={sid}", "newTab": True, "json": True,
            "maxSteps": max_steps, "elements": False}
    args.update(ARMS[arm])
    begun = time.time()
    error = None
    try:
        run = json.loads(copper.call("jev_run", args))
    except (RuntimeError, urllib.error.URLError, json.JSONDecodeError, TimeoutError) as e:
        error = f"{type(e).__name__}: {e}"[:300]
        run = {"status": "error", "note": error, "elapsed_ms": int((time.time() - begun) * 1000),
               "actions": 0, "decisions": 0, "totals": {}, "steps": []}
    finally:
        try:
            copper.call("browser_close", {}, timeout=20)
        except Exception:
            pass
    time.sleep(0.3)  # a beacon in flight
    app = app_result(base, sid)
    totals = run.get("totals", {})
    detail = app.get("detail") or {}
    wall = run.get("elapsed_ms") or 0
    actions = run.get("actions") or 0
    out = {
        "at": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "task": task, "arm": arm, "args": ARMS[arm], "sid": sid,
        "pass": bool(app.get("ok")), "app_done": bool(app.get("done")), "wrong": app.get("wrong", 0),
        "status": run.get("status"), "note": run.get("note", ""),
        "wall_ms": wall, "success_ms": detail.get("t") if app.get("ok") else None,
        "actions": actions, "decisions": run.get("decisions") or 0, "optimal": optimal,
        "apm": round(actions / (wall / 60000), 1) if wall else None,
        "model": totals.get("model", ""), "strategy": totals.get("strategy", ""),
        **{k: totals.get(k) for k in ("jev_ms", "text_ms", "shot_ms", "observe_ms", "decide_ms", "act_ms", "settle_ms",
                                      "input_tokens", "requests", "stale", "burst_actions", "box_hits", "box_asked")},
        "steps": [{"op": s.get("operation"), "label": (s.get("label") or "")[:60], "text": s.get("text"),
                   "p": s.get("probability"), "jev": round(s.get("jev_ms") or 0), "txt": round(s.get("text_ms") or 0),
                   "obs": round(s.get("observe_ms") or 0), "dec": round(s.get("decide_ms") or 0),
                   "act": round(s.get("act_ms") or 0), "set": round(s.get("settle_ms") or 0),
                   "tok": s.get("input_tokens"), "burst": s.get("burst"), "box": s.get("box")} for s in run.get("steps", [])],
    }
    if error:
        out["error"] = error
    mark = "PASS" if out["pass"] else ("fail:" + str(out["status"]))
    print(f"  {arm:<12} {mark:<16} {wall:>6} ms  {actions:>2}/{optimal:<2} act  {out['decisions']:>2} dec  "
          f"APM {out['apm'] or 0:>5}  jev {int(out['jev_ms'] or 0):>5}  txt {int(out['text_ms'] or 0):>5}  act {int(out['act_ms'] or 0):>5}"
          + (f"  wrong {out['wrong']}" if out["wrong"] else "")
          + (f"  — {out['note'][:60]}" if not out["pass"] and out["note"] else ""), flush=True)
    return out


def summarize(results, out=None):
    arms = []
    for r in results:
        if r["arm"] not in arms:
            arms.append(r["arm"])
    tasks = []
    for r in results:
        if r["task"] not in tasks:
            tasks.append(r["task"])
    lines = ["| Arm | Pass | Median wall (passes) | Median to success | APM (median) | Actions / optimal | Decisions | Decide ms / decision | Act ms / action | Text-model ms / run | Tokens / run | Wrong clicks |",
             "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|"]
    for arm in arms:
        rs = [r for r in results if r["arm"] == arm]
        ok = [r for r in rs if r["pass"]]
        per_dec = [r["decide_ms"] / r["decisions"] for r in rs if r.get("decide_ms") and r.get("decisions")]
        per_act = [r["act_ms"] / r["actions"] for r in rs if r.get("act_ms") and r.get("actions")]
        lines.append("| {} | {}/{} | {} | {} | {} | {} | {} | {} | {} | {} | {} | {} |".format(
            arm, len(ok), len(rs), fmt(median([r["wall_ms"] for r in ok]), " ms"),
            fmt(median([r["success_ms"] for r in ok]), " ms"),
            fmt(median([r["apm"] for r in ok])),
            fmt(median([r["actions"] / r["optimal"] for r in ok]) if ok else None),
            fmt(median([r["decisions"] for r in ok])),
            fmt(median(per_dec)), fmt(median(per_act)),
            fmt(median([r.get("text_ms") or 0 for r in rs])),
            fmt(median([r.get("input_tokens") or 0 for r in rs])),
            sum(r["wrong"] for r in rs)))
    lines += ["", "Per task: passes, and median wall ms of the passes.", "",
              "| Task | " + " | ".join(arms) + " |", "|---|" + "---:|" * len(arms)]
    for task in tasks:
        cells = []
        for arm in arms:
            rs = [r for r in results if r["task"] == task and r["arm"] == arm]
            ok = [r for r in rs if r["pass"]]
            cells.append(f"{len(ok)}/{len(rs)} · {fmt(median([r['wall_ms'] for r in ok]))}" if rs else "—")
        lines.append(f"| {task} | " + " | ".join(cells) + " |")
    text = "\n".join(lines) + "\n"
    if out:
        with open(out, "w") as f:
            f.write(text)
    return text


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--world", default="Copper")
    ap.add_argument("--port", type=int)
    ap.add_argument("--token")
    ap.add_argument("--app", default="http://127.0.0.1:8777")
    ap.add_argument("--arms", default=",".join(ARMS))
    ap.add_argument("--tasks", default=",".join(TASKS))
    ap.add_argument("--rounds", type=int, default=1)
    ap.add_argument("--max-steps", type=int, default=30)
    ap.add_argument("--out", default="perf/results/uibench.jsonl")
    ap.add_argument("--summary")
    ap.add_argument("--seed", type=int, default=11)
    a = ap.parse_args()
    if a.summary:
        with open(a.summary) as f:
            results = [json.loads(line) for line in f if line.strip()]
        print(summarize(results, out=a.summary.rsplit(".", 1)[0] + ".md"))
        return
    arms = [x.strip() for x in a.arms.split(",") if x.strip()]
    tasks = [x.strip() for x in a.tasks.split(",") if x.strip()]
    for x in arms:
        if x not in ARMS:
            sys.exit(f"unknown arm {x}: {', '.join(ARMS)}")
    for x in tasks:
        if x not in TASKS:
            sys.exit(f"unknown task {x}: {', '.join(TASKS)}")
    try:
        urllib.request.urlopen(a.app + "/app", timeout=5).read()
    except Exception as e:
        sys.exit(f"the app is not up at {a.app} ({e}); start perf/uibench/server.py")
    copper = Copper(a.world, a.port, a.token)
    os.makedirs(os.path.dirname(a.out) or ".", exist_ok=True)
    rng = random.Random(a.seed)
    results = []
    print(f"{len(tasks)} tasks × {len(arms)} arms × {a.rounds} rounds = {len(tasks) * len(arms) * a.rounds} runs")
    with open(a.out, "a") as f:
        for round_ in range(a.rounds):
            for task in tasks:
                order = arms[:]
                rng.shuffle(order)
                print(f"\n[{round_ + 1}] {task}")
                for arm in order:
                    r = play(copper, a.app, task, arm, a.max_steps)
                    r["round"] = round_ + 1
                    results.append(r)
                    f.write(json.dumps(r) + "\n")
                    f.flush()
                    time.sleep(0.5)
    print()
    print(summarize(results, out=a.out.rsplit(".", 1)[0] + ".md"))


if __name__ == "__main__":
    main()
