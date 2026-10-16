# Jev vision: what Jev sees, and whether pictures help

**Status: measured, 2026-10-16.** Pictures are in (Settings › Agents › Jev mode › *What Jev sees*; `vision` on `jev_run`), off by default. The text-only loop stays the default because it is the fastest and as reliable as any picture mode on the games below.

## What changed

TypeSafe's Jev takes images now (docs.typesafe.ai/images — a preview behind the `TypeSafe-Danger-Zone-Images: true` header, Jev 1.13 and 1.14; TypeSafe calls them "Dreamer-ready" and says their models do worse on pictures than on text). Jev 1.14 (2026-10-14) adds a **Box** question: four edges of where something is in a picture, plus a confidence. [browser-use/jev-ultrafast](https://github.com/browser-use/jev-ultrafast) does not use either: its `main` (last pushed 2026-09-30) and every `codex/*` branch send text only (`screenshots=` there only feeds the inspector and the demo video), and no open PR adds images. So Copper's port (`Fork/MCP/Ultrafast.swift`) got them first:

| `vision` | what rides beside the element table on every decision |
|---|---|
| `off` | nothing more — the original loop |
| `screenshot` | a JPEG of the viewport at 1× in the state (`page.screenshot`), referenced from the rules |
| `marks` | the same picture with every element's index drawn in a tag at its top-left corner, the table's numbering (set-of-marks) |
| `box` | the picture, and one Box question in place of the per-operation target heads: *the one control in `page.screenshot` to act on*. The box's centre is mapped onto the observed element under it (the smallest when they nest, else the nearest within 24 px); when it lands on none, the text head is asked as a second request and the miss is counted. Jev 1.14 only |

The picture is taken right after the read (trail layer hidden), re-rendered into a bitmap of known size so the marks and the box maths share one scale, kept within TypeSafe's 280–1568 px sides, and sent base64 under a fresh UUID reference. `Jev.ask` grew `assets` and a per-call `model`; a Box answer is parsed into `Answer.boxes`. Per-step `input_tokens`, `jev_ms`, `shot_ms`, `box_hit` and `requests` go into the trace and into `jev_run`'s `json: true` object. `SEARCH_JEV_SHOTS=<folder>` keeps every picture sent. Model output never becomes a coordinate: a box only ever selects an element this code observed, and the same freshness and occlusion checks run before the click.

## The Wikipedia game

`perf/wikigame.py`: ten games (start article → target article; seven one link away, three two away), each a `jev_run` with the goal *reach the article titled X by clicking links in the article only, never the search box*, in a tab of the harness's own, verified by the final URL. Six arms, alternating within each game, two rounds: **120 runs**, 20 per arm. Headless dev build of this branch on the Mac mini (M-series, 1280×800 viewport, Wikipedia live), 2026-10-16 14:17–14:31 EDT. A pass is Jev's DONE on the target with no TYPE_TEXT. `wall` is `jev_run`'s clock (first decision to the end, page loads included; the initial navigation outside it); *Jev ms* and tokens are per decision, summed per run. Raw runs: `perf/results/wikigame.jsonl`.

| Arm | Model | Pass | Median wall (passes) | Median actions | Jev ms / decision (p50 · p90) | Tokens / decision | Tokens / run | Box | Stale |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `off` | jev-1.13.0 | 17/20 | **1,978 ms** | 2 | **193 · 298** | 5,659 | 17,560 | — | 1 |
| `off` | jev-1.14.0 | **18/20** | 2,072 ms | 2 | **170 · 216** | 5,502 | 18,203 | — | 2 |
| `screenshot` | jev-1.13.0 | 17/20 | 2,609 ms | 2 | 352 · 520 | 7,796 | 23,155 | — | 0 |
| `marks` | jev-1.13.0 | **18/20** | 2,825 ms | 2 | 400 · 730 | 7,757 | 23,270 | — | 0 |
| `marks` | jev-1.14.0 | 16/20 | 3,068 ms | 2 | 340 · 477 | 7,832 | 23,500 | — | 0 |
| `box` | jev-1.14.0 | 14/20 | 3,288 ms | 2 | 321 · 454 | 5,134 | 15,957 | 22/22 hit | 7 |

Per game, wall ms of each run (`×` a fail): see `perf/results/wikigame.md`.

### What it says

- **Text is fastest, and no less reliable.** A picture adds about 2,200 input tokens (+40%) and 160–210 ms of Jev latency per decision, plus 10–20 ms to take it; passes land 30–55% later on the clock. Pass rates are 16–18 of 20 for every arm but box, which is within the noise of two rounds: the failures are the same games on every arm.
- **Jev 1.14 on text is the best arm here** (18/20, 170 ms p50, 216 ms p90 — the tightest latency of all). The model, not the modality, is the upgrade worth taking.
- **Box lands, then disappoints.** Every box Jev returned landed on an offered element (22/22) and the second request was never needed, so the mapping works. But the box arm passed 14/20: it said BLOCKED with 31–46% confidence more often than any other arm (6 of its failures), it picked citation brackets (`[ 12 ]`) twice — the smallest element under a box drawn over a sentence — and it was the only arm with stale retries (7: a click chosen by position landing after the page had moved). It is also the slowest on the clock. The token count is lower only because the target heads are gone.
- **Why anything fails.** 19 of the 23 failures across all arms are Jev choosing BLOCKED at 31–58% after one to three scrolls, on three games (Messi → Buenos Aires, Beethoven → Austria, Coffee → Ethiopia) where the link is below the fold or two hops away. That is the policy's jaggedness on long articles, shared by every arm; a scroll-then-BLOCKED guard (refuse BLOCKED under 60% while SCROLL_DOWN is still offered) would likely lift every arm equally. Nothing cheated: no arm typed into the search box.
- **Pictures did help once.** Both runs of Moon → Earth and Pizza → Naples were one click on every arm; on Shakespeare → Hamlet the marks arm was slower (7.3 s and 7.4 s on one run each) because Jev clicked a nearby link first. There was no game where a picture arm was reliably faster than text.

So: `off` stays the default, and the picture modes are there for pages the table cannot describe (icon-only buttons, canvases, layout that carries meaning) and for when TypeSafe's picture accuracy catches up. The harness is there to re-run when it does.

## Not done

- The Settings picker shows the four modes but says nothing about cost; a per-run note in the trace does (`Jev: 1,102 ms, 20,822 tokens · pictures: marks, 32 ms`).
- Box mode's nearest-element rule prefers the smallest containing element; a word-sized citation link inside a sentence wins over the sentence's link. Preferring the candidate whose label the goal mentions, or excluding `sup` reference links from box candidates, would fix the two bad clicks.
- No multipart upload: the picture goes base64 in JSON, about a third larger on the wire. Fine at 250 KB.
- `jev_step` reads `vision`/`model` only when a session starts.
