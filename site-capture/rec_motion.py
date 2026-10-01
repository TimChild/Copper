import os, sys, time, json
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cb import Recorder, ask
out = sys.argv[1]
def ids():
    out = {}
    for k in range(3):
        ask({"do": "spaces", "op": "select", "arg": str(k)}); time.sleep(0.3)
        for t in ask({"do": "tabs"}).get("tabs", []): out[t.get("title", "")] = t["id"][:8]
    return out
I = ids(); print(I)
G = I['Google']; CU = I['Copper - Wikipedia']; LIB = I['Statue of Liberty - Wikipedia']; WK = I['WebKit']
def sp(i): ask({"do": "spaces", "op": "select", "arg": str(i)})
def sel(i): ask({"do": "select", "id": i})
# reset
sp(2); sel(LIB); sp(1); sel(WK); sp(0); sel(G); ask({"do": "ui", "sidebar": True}); time.sleep(2)
marks = []
def mark(n): marks.append((n, time.time()))
r = Recorder(out); r.start(); time.sleep(0.2)
mark('start'); time.sleep(1.0)
mark('wiki'); sel(CU); time.sleep(1.1)
mark('summon'); ask({"do": "summon", "text": ""}); time.sleep(0.45)
for t in ['p', 'pa', 'pat']:
    ask({"do": "summon", "text": t}); time.sleep(0.35)
time.sleep(0.5)
mark('go'); ask({"do": "key", "id": CU, "text": "↩", "via": "app"}); time.sleep(1.6)
mark('work'); sp(1); time.sleep(1.5)
mark('top'); ask({"do": "ui", "sidebar": False}); time.sleep(1.5)
mark('side'); ask({"do": "ui", "sidebar": True}); time.sleep(0.9)
mark('home'); sp(0); sel(G); time.sleep(1.2)
mark('end')
fr = r.finish()
json.dump(marks, open(out + '/marks.json', 'w'))
print(len(fr), 'frames', round(marks[-1][1] - marks[0][1], 1))
