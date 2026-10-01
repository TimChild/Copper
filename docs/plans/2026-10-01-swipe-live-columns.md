# Space swipe: live columns on one ground

Branch `feat/swipe-live-columns`. Working notes — the diagnosis first, the
design and the measurements as they land. Captures live outside the repo in
`~/Developer/copper-swipe4-captures/` (symlinked at `/tmp/swipe4`).

## What Collin sees (shipped build: origin/fork, picture-based slide)

Swiping between two gradient spaces "flashes and changes state"; #18's live
ground was laggier, left a white band at the top and incoming spaces didn't
load.

## Reproduction (base e2a5b4d = origin/fork at #19, 1× display 3440×1440 @144 Hz)

Test world `Copper (swipe4)`, column 232×900, band y 92…858. Spaces: Casual
(3-stop gradient, 152 tabs) → Exowatt (2-stop gradient, 37 tabs, never
visited this launch). Scripted swipe: twelve held steps of −10 pt (one event
each, a window shot after each), then the lift with shots at 0, 32, … 450 ms.

Mean colour of ground patches (image px, 1400×900 shot):
top band x100–130 y2–10 (static part) · left margin x1–6 y300–700 (band
region) · gap under the favourites x20–200 y129–135 (band region).

| frame | top band | left margin | gap |
|---|---|---|---|
| d01 (phase .04) | 227 218 182 | 211 220 179 | 221 218 179 |
| d04 (.17) | 226 218 182 | 209 193 160 | 225 207 170 |
| d08 (.34) | 226 218 182 | 215 194 154 | 234 185 151 |
| d12 (.52, held) | 226 218 182 | 224 188 145 | 239 168 136 |
| r000 (lift) | 226 218 182 | 224 188 145 | 239 168 136 |
| r032 … r450 | 245 144 122 | 245 171 122 | 245 150 121 |

Strips: `base/run1-drag-strip.png`, `base/run1-release-strip.png`.

What the frames show, and why:

1. **During the drag the ground is two pictures, not one.** The outgoing
   column is a bitmap of the window (`SpaceSlide.photograph`, 41 ms at the
   first finger movement in run 1, 149 ms in run 2) with Casual's gradient
   baked in; its band part slides out at `(1 − phase)` opacity over the
   arriving space's *live* `ThemeBackdrop`. So the band region's ground is a
   cross-fade of two gradients plus a vertical seam at the picture's edge,
   while the static part (top band, strip) does not change at all while the
   fingers are down — with no cached picture of Exowatt the fallback is the
   old picture, so the lights/address stay green over an orange band.
2. **The incoming column was empty.** Exowatt had never been pictured this
   launch (`incoming: false`), so what came in was bare orange ground — "the
   incoming space didn't load".
3. **The lift is a stall, then a jump.** `release` runs `Spaces.select(…,
   pictured: true)` at once; the next run-loop turn commits the swapped
   column (152 ↔ 37 rows, the page's web view, hosted-view geometry and
   tracking areas — the `sample` is all `NSHostingView.layout` →
   `DisplayList.ViewUpdater … Platform.updateGeometry` → `NSView setFrame`,
   nothing of ours on the stack) and that turn took **740 ms** (run 3:
   committed 207 ms → moved 947 ms; longest frame gap 738 ms), 400 ms in run
   4, ~1.9 s in run 2 (both pictures cached, 152 rows coming back). The
   settle spring only starts after it, so the eye sees the dragged frame
   freeze and then the whole column — ground, rows, lights, strip — appear
   in the new state: the "flash and state change". For a click
   (`spaces select 0`) the same stall is 258 ms *before* the slide starts,
   which reads as latency rather than a flash.
4. Even the timed slide drops frames: click Exowatt → Casual, 23 frames in
   244 ms at 6.9 ms period, 10 missed, longest 30.8 ms — moving the live
   band (an `NSScrollView` platform view, clipped) costs 10–30 ms a frame
   with 152 rows.

## #18 (b38c47d, reverted in 8e3e7ea)

Put the ground in its own `NSHostingView` (`SpaceGroundHost`) so it could be
hidden while the column was drawn twice (black and white mattes) for a
picture on clear. A nested hosting view insets by the window's safe area →
the top 28–32 pt came out white. The two matte draws cost 17–55 ms at the
first finger movement (laggier), and a never-pictured space still came in
blank.

## Design (this branch)

- Ground: `SpaceGround` as the column's plain SwiftUI `.background`, inside
  the window's own hosting view (ignores the safe area, so it runs under the
  lights). Blends `from.look` → `to.look` by `phase`, stop by stop for two
  simple themes, crossfade for a picture, the one scene for an animated one.
  `phase` is monotone from the first drag event through the settle, and the
  switch happens with `from`/`to` still set, so t = 1 and the new space's
  own look are the same pixels.
- Outgoing: the live band (one `ScrollView`: header + rows) slides out.
  Incoming: `SpacePreview` of the neighbour's parked rows on clear, only the
  rows in view, premounted while idle.
- Commit: deferred to after the settle lands, under the preview — the
  400–900 ms column swap then costs no visible motion; the preview fades
  out over the live column once it is up.
- Nothing is pictured, ever.

## Status 2026-10-01 evening (commits 45f19c9 … on feat/swipe-live-columns)

Built and verified on the `Copper (swipe4)` world, laptop Retina display
(1728×1117 @ 120 Hz, 2×) — the base reproduction above was on the 1× 3440
display earlier in the day; the external display was gone by the time the
branch was built, so 1× for the new build and a real trackpad are unverified.

### Colour curve (new build, Casual → Exowatt, 12 held steps then the lift; shots every 16 ms)

Top band (static ground under the lights), G channel: 214.8 210.0 206.1
202.5 198.8 195.1 190.6 187.5 184.2 181.0 177.7 173.8 | lift: 173.4 170.7
166.9 164.7 155.9 148.5 144.9 144.2 143.5 142.6 142.6 … 142.4 | after the
switch and the preview's fade (r700+): 142.6. Monotone, no spike, no reset;
the step at the end is ≤ 0.3/255. Exowatt → Casual the same the other way
(144.6 → 177.0 at the lift → 218.7). Full tables: `new/suite/*/` via
`curves.sh`; strips `new/suite/casual-to-exo-strip.png`,
`exo-to-casual-strip.png`, `first-fwd-strip.png` (Exowatt → Work, a
picture space never visited that launch: its rows are there from the first
frame). Flat ↔ animated (Reve ↔ Focus) and picture ↔ flat (Work ↔ Reve)
ran both ways and committed; frames in `new/suite/`.

### Main thread (12-swipe loops, Casual ⇄ Exowatt, back to back, same minutes)

The machine was under a load average of 50–120 throughout (another agent's
expo export, Unity, a second Copper build, P3), so absolute numbers are
inflated for both builds; only the comparison and the shape are meaningful.

| | base (origin/fork e418c06) | this branch |
|---|---|---|
| event gap while dragging, median of medians | 11.9 ms | 22.8 ms |
| longest event gap per swipe, median | 371 ms (the picture at the first movement) | 77 ms |
| lift → first settle frame (`turn`), median | 3381 ms (column swap before the spring) | 0 ms |
| longest frame gap, median | 2988 ms, during the settle | 550 ms, after the spring landed (the swap under the preview) |
| switch stall (landed → switched), median | — | 623 ms (154 ms best; the swap itself, unchanged) |

Reading: the base freezes mid-motion for the whole column swap and then
jumps; this branch moves smoothly to the landing and pays the swap while
nothing is moving. The drag itself costs more per event here (the live band
is a clipped `NSScrollView` platform view resized every frame; see
`SpaceSlide.clipsBand`). `bench spaces slide clip off` was tried: no
measurable gain under this load (medians 26 vs 60 ms with the load doubling
between runs), and an unclipped band leaving to the right draws over the
page, so clipping stays on. Re-measure on a quiet machine before deciding.
`sample` over the loops: our own bodies are < 1 % of main-thread samples
(SpaceStrip.chip 34, SpacePreview.Row 26, SlideInk 14 of ~9000); the rest
is SwiftUI/AppKit layout of platform views.

### Preview cost

`bench spaces preview N` (an off-screen hosting view, so pessimistic):
Focus 39 rows / 18 visible: plan 2 ms, build 180, layout 120, draw 96;
Work 5 rows: plan 0.6, build 2.7, layout 176, draw 91. Far over 8 ms, so
the two neighbours stay premounted (hidden) while idle, as designed.

### Open

- 1× display and a real trackpad on this build; Retina was the only screen.
- The band's per-frame cost under no load; clip on/off decision.
- `SpacePreviewModel.make`'s landing scroll reads the first window's scroll
  view (`SideScrollElasticity.column`); a second window's preview lands at
  the first's scroll.
- The address pill's text and the strip's lifted chip change at the switch
  (after the settle), not during; only their ink crossfades.
