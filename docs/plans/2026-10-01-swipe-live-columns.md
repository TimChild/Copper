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
