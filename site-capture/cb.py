#!/usr/bin/env python3
"""Tiny bench client + continuous frame recorder for the sitepics world."""
import json, os, socket, sys, time, threading
SOCK = os.path.expanduser("~/Library/Application Support/Copper (sitepics)/bench.sock")
def ask(req):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.connect(SOCK); s.sendall((json.dumps(req) + "\n").encode())
        chunks = []
        while True:
            c = s.recv(1 << 16)
            if not c: break
            chunks.append(c)
    return json.loads(b"".join(chunks).split(b"\n", 1)[0] or b"{}")
def window(path): return ask({"do": "window", "path": path})
class Recorder:
    def __init__(self, outdir):
        self.outdir = outdir; os.makedirs(outdir, exist_ok=True); self.stop = False; self.frames = []
    def run(self):
        i = 0
        while not self.stop:
            p = os.path.join(self.outdir, f"f{i:05d}.png"); t = time.time()
            r = window(p)
            if r.get("path"): self.frames.append((t, p)); i += 1
    def start(self): self.th = threading.Thread(target=self.run); self.th.start()
    def finish(self):
        self.stop = True; self.th.join()
        with open(os.path.join(self.outdir, "frames.json"), "w") as f: json.dump(self.frames, f)
        return self.frames
if __name__ == "__main__":
    print(json.dumps(ask(json.loads(sys.argv[1]))))
