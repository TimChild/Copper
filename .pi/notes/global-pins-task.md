# global-pins takeover (worktree /Users/felipearce/src/copper-pins)
No git mutations. Probe world: pinprobe, MCP port 4201. ALWAYS ./bench --world pinprobe.
Old probe pid 59628 (prev agent's, from this worktree build) — kill by PID before relaunch.

Plan (prev agent's diff kept as base):
1 Spaces.swift: pinHome dict (profile jar home), tabsChanged normalizes source to pins+row,
  adopt/foldLegacy dedupe BEFORE build, shape writes pins top-level (space=home) + downgrade
  mirrors in main space row (pin set) ; restore: new fmt ignores tabs pin entries; legacy sorts by
  space idx, dedupe; Sections.restore for pins seen; bench spaces move error for pin
2 SessionGuard/Session count = loose tabs + pins
3 Browser: open/reopen insert pos past pins; close pin skip rest if shown elsewhere
4 Side.swift pins outside SpaceSlideBand; SpaceSlide comment
5 SpacesUI hide Move Current Tab Here for pin; CommandBar badge
6 Bench pin/unpin/reorder --window N; windows output pins; bench tabs print pin
7 CHANGELOG/PATCHES
Status: (update below)
