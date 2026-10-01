import os, sys, time, subprocess, json
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cb import Recorder, ask
out = sys.argv[1]; goal = sys.argv[2]
r = Recorder(out); r.start(); t0 = time.time()
time.sleep(1.5)
p = subprocess.run([os.path.join(os.path.dirname(os.path.abspath(__file__)), 'cop'), 'run', goal, '--no-elements'], capture_output=True, text=True)
t1 = time.time()
time.sleep(2.5)
fr = r.finish()
open(out + '/run.txt', 'w').write(p.stdout + '\n---\n' + p.stderr)
json.dump({'t0': t0, 'run_start': t0 + 1.5, 'run_end': t1}, open(out + '/times.json', 'w'))
print(len(fr), 'frames', round(t1 - t0, 1), 's'); print(p.stdout[-1500:]); print(p.stderr[-500:])
