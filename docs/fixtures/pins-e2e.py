#!/usr/bin/env python3
"""Two headless probe-world Coppers on one copper-cloud: do pins stay one set
while the two Macs sit on different spaces, and do per-space pins travel?

    docs/fixtures/pins-e2e.py BINARY "<link code>"

BINARY is a Copper executable (.build/debug/Search, or an app's
Contents/MacOS/Copper). Worlds pinsa/pinsb, never the browser in use. The
link code is an open-mode instance's (`copper-cloud link-code`).
"""
import json, os, socket, subprocess, sys, time

BIN, LINK = sys.argv[1], sys.argv[2]
STAMP = str(int(time.time()))
RESULTS = []


def folder(world):
    return os.path.expanduser(f"~/Library/Application Support/Copper ({world})")


def ask(world, req):
    with socket.socket(socket.AF_UNIX) as s:
        s.connect(os.path.join(folder(world), "bench.sock"))
        s.sendall((json.dumps(req) + "\n").encode())
        out = b""
        while True:
            chunk = s.recv(1 << 16)
            if not chunk:
                break
            out += chunk
    return json.loads(out)


def op(world, verb, name, arg=""):
    return ask(world, {"do": verb, "op": name, "arg": arg})


def check(label, ok, detail=""):
    RESULTS.append(ok)
    print(("  ok   " if ok else "  FAIL ") + label + ("" if ok else f" — {detail}"))


def launch(world, port, fresh=True):
    suite = f"com.officecommun.search.test.{world}"
    if fresh:
        subprocess.run(["rm", "-rf", folder(world)])
        subprocess.run(["defaults", "delete", suite], capture_output=True)
        for key in ("bench", "welcomed"):
            subprocess.run(["defaults", "write", suite, key, "-bool", "true"])
    env = dict(os.environ, SEARCH_PROBE=world, SEARCH_HEADLESS="1", SEARCH_MCP_PORT=str(port),
               SEARCH_HEADLESS_SIZE="1440x1000")
    log = open(f"/tmp/copper-{world}.log", "w")
    proc = subprocess.Popen([BIN], env=env, stdout=log, stderr=log)
    for _ in range(80):
        try:
            ask(world, {"do": "tabs"})
            return proc
        except Exception:
            time.sleep(0.5)
    sys.exit(f"{world} never answered")


def pins(world):
    return op(world, "spaces", "list")["pins"]


def shown(world):
    """URLs of the pins in the window's row right now."""
    return sorted(t["url"] for t in ask(world, {"do": "tabs"})["tabs"] if t.get("pin"))


def sync(*worlds, rounds=1):
    for _ in range(rounds):
        for w in worlds:
            op(w, "cloud", "sync", "now")
            time.sleep(2.5)


A, B = "pinsa", "pinsb"
procs = [launch(A, 4181), launch(B, 4182)]
try:
    print("== link, one account on both")
    for w in (A, B):
        op(w, "cloud", "link", LINK)
    email = f"pins-{STAMP}@example.com"
    op(A, "cloud", "signup", f"{email} correct-horse-battery Pins")
    op(B, "cloud", "signin", f"{email} correct-horse-battery")
    for w in (A, B):
        op(w, "cloud", "sync", "on all")

    print("== two spaces, two pins on A")
    op(A, "spaces", "new", "Work")
    op(A, "spaces", "select", "0")
    one, two = f"https://example.org/one-{STAMP}", f"https://example.com/two-{STAMP}"
    op(A, "cloud", "pin", one)
    op(A, "cloud", "pin", two)
    sync(A, B, rounds=2)
    names_b = [s["name"] for s in op(B, "spaces", "list")["spaces"]]
    check("B has both spaces", "Work" in names_b, names_b)
    check("B has the two pins", len(pins(B)) == 2, pins(B))

    print("== the Macs on different spaces, syncing back and forth")
    op(A, "spaces", "select", "0")
    op(B, "spaces", "select", "1")
    for i in range(3):
        sync(A, B, rounds=1)
        op(A, "spaces", "select", str((i + 1) % 2))
        op(B, "spaces", "select", str(i % 2))
    sync(A, B, rounds=2)
    check("A still has 2 pins", len(pins(A)) == 2, [p["url"] for p in pins(A)])
    check("B still has 2 pins", len(pins(B)) == 2, [p["url"] for p in pins(B)])

    if "--old" in sys.argv:
        raise SystemExit
    print("== each space its own pins")
    r = op(A, "spaces", "perpins", "on")
    check("A turns per-space pins on", r.get("perSpacePins") is True, r)
    first = next(p for p in pins(A) if p["url"] == one)
    op(A, "spaces", "pin-space", f"{first['id']} Work")
    sync(A, B, rounds=2)
    check("the setting reaches B", op(B, "spaces", "list").get("perSpacePins") is True, op(B, "spaces", "list").get("perSpacePins"))
    only_b = {p["url"]: p["only"] for p in pins(B)}
    check("B keeps pin one to Work", only_b.get(one) == "Work", only_b)
    op(B, "spaces", "select", "0")
    check("B on Home shows only pin two", shown(B) == [two], shown(B))
    op(B, "spaces", "select", "1")
    check("B on Work shows both", shown(B) == sorted([one, two]), shown(B))
    check("B still has 2 pins", len(pins(B)) == 2, pins(B))

    print("== a new pin on B while on Work stays in Work")
    three = f"https://example.net/three-{STAMP}"
    op(B, "cloud", "pin", three)
    sync(B, A, rounds=2)
    only_a = {p["url"]: p["only"] for p in pins(A)}
    check("A gets pin three, kept to Work", only_a.get(three) == "Work", only_a)
    op(A, "spaces", "select", "0")
    check("A on Home doesn't show it", three not in shown(A), shown(A))

    print("== unpinning a pin no window shows")
    third = next(p for p in pins(B) if p["url"] == three)
    op(B, "spaces", "select", "1")
    ask(B, {"do": "unpin", "id": third["id"]})
    sync(B, A, rounds=2)
    check("A loses pin three though it's hidden on Home", three not in [p["url"] for p in pins(A)], pins(A))
    check("A has 2 pins", len(pins(A)) == 2, pins(A))

    print("== setting off: every pin everywhere again")
    op(A, "spaces", "perpins", "off")
    op(A, "spaces", "select", "0")
    check("A on Home shows both", shown(A) == sorted([one, two]), shown(A))

    print("== a pin's space survives a restart")
    op(A, "spaces", "perpins", "on")
    time.sleep(1.5)
    op(A, "windows", "quit")
    procs[0].wait(timeout=20)
    procs[0] = launch(A, 4181, fresh=False)
    only_a = {p["url"]: p["only"] for p in pins(A)}
    check("pin one is still kept to Work", only_a.get(one) == "Work", only_a)
    check("still 2 pins after the restart and a sync", (sync(A, B), len(pins(A)))[1] == 2, pins(A))
finally:
    for p in procs:
        p.terminate()
    print(f"\n{sum(RESULTS)}/{len(RESULTS)} passed")
    sys.exit(0 if all(RESULTS) else 1)
