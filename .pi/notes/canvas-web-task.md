# Canvas web bundle task (D)
- Worktree /Users/felipearce/src/copper-canvasweb, own ONLY Canvas/. No git mutations.
- Spec: /Users/felipearce/exowatt/reports/2026-10-01-copper-cloud-and-canvas-plan.md §4
- Dossier: /Users/felipearce/exowatt/reports/partials/2026-10-01/canvas-port-dossier.md
- Source (READ ONLY): another app's apps/web/src/modules/wiki
- NAME RULE: no 'wiki' strings in Canvas/ (grep -ri before finish)
- Screenshots /tmp/canvas-web-*.png; never touch user's Copper (4123)
## Progress
- [15:07] Core done: src/{controller,api,ops,placement,host-bridge,bridge-socket,theme,dev,dev-relay}.ts, src/canvas/** (doc,geometry,arrows,search,markdown-lite,images,agents, components/Board.tsx etc). 176 tests pass, lint+typecheck clean, build 487KB dist/canvas.html.
- Dev server: `bun run dev` (port 5173, started nohup). Playwright scripts in /tmp/canvas-pw/{shot,interact}.mjs (webkit via ~/.volta/tools/image/packages/playwright).
- TODO: fix move test (click then wait), placement avoid frame labels, README/build.sh, Copper headless check, final grep for forbidden names.
- [15:18] DONE. 176 tests, typecheck, lint, build all green; dist 489,759 B (151 KB gz). README.md, build.sh, .gitignore written. Name grep clean. Dev server + probe Copper (4188) killed; user's Copper 4123 untouched. No git mutations. Final report delivered.
