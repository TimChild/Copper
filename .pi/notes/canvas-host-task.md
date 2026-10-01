# Canvas host task (E) — worktree /Users/felipearce/src/copper-canvas (branch cloud-canvas)
- NO git mutations. Never touch user's Copper (4123). No keychain.
- Spec: /Users/felipearce/exowatt/reports/2026-10-01-copper-cloud-and-canvas-plan.md §0,1,2,4,5
- Dossier: /Users/felipearce/exowatt/reports/partials/2026-10-01/copper-arch-dossier.md
- Real bundle poll: /Users/felipearce/src/copper-canvasweb/Canvas/dist/canvas.html
- Cloud contract poll: /Users/felipearce/src/copper-cloudc/Sources/Search/Fork/Cloud/CONTRACT_READY
- Build: export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk SEARCH_SIGN_IDENTITY=-; ./build.sh
- Probe: SEARCH_PROBE=canvasE SEARCH_MCP_PORT=4161
## Progress
## Key facts learned (2026-10-01)
- Session.Entry.init?(_ tab:) in Fork/Spaces.swift ~497 rejects non-HTTP tabs → must allow copper://canvas
- Tools.call dispatch: switch on name before `current(browser)`; tool() helper adds reason. Agent uses Tools.catalogue + DriveCaller.who (.plain(.pane)) ; MCP sets DriveCaller.$who = caller (Drive.Who.agent name)
- Page.raw(web, js) evaluates JS in page world; Page.screenshot(web, rect:nil, fullPage:false, jpeg:false)
- Resource lookup pattern: BackdropScene.folder in Fork/AnimatedBackdrop.swift (Search_Search.bundle in resourceURL/bundleURL)
- Bench verbs: Bench.swift switch list → Fork.bench(verb) in Fork/Fork.swift; bench script python generic verbs list line ~240
- ⌘⇧C = Copy Address (taken). Need other shortcut for Canvas.
- Address.ours schemes: http https file about data (copper not) ; Browser.submit -> CommandBar.run(copper://command) ; Launcher.take copper scheme
## Design decisions
- Interception: Browser.decidePolicyFor → CanvasHost.decide(...) (copper://canvas → cancel+mount: register shared CanvasRelay on tab controller (remove-then-add), loadFileURL canvas.html?id=X). Canvas tab page-initiated nav → cancel + open new tab; go()-initiated (tab.address == url) or backForward → allow + unmount.
- Tab.swift url observer: ignore canvas bundle file URL so address stays copper://canvas/<id>
- Browser.extensionConfiguration(for:) first line → CanvasHost.configuration(for:) (dedicated config, no extensions, relay pre-registered). Spaces.restore uses it too.
- Address.url(from:) accepts copper://canvas*. CommandBar.run handles copper://canvas (Launcher.take→CommandBar.run).
- JS calls via callAsyncJavaScript(arguments:, in: .page) — no manual escaping; apply(opsJsonString, asObject); read(optsJsonString)
- Restore: init(state=snapshot) + applyUpdate(each log entry) in ONE script, then window.__copperCanvasHost = gen marker; ignore 'update' msgs while restoring
- Store: canvas/<key>/updates.log (u32 BE len + bytes), snapshot.bin; compaction via exportState() dropping first K entries (K = count at request)
- Personal binding: registry.personalAccount; other account → store key personal-<userId>
- Menu: ForkCommands (Spaces.swift) View › Canvas ⌘⇧O (⌘⇧C taken by Copy Address)
- Collaborators: parse y-websocket awareness frames (lib0 varuint) in host
## Status 15:00
- Written: Canvas.swift, CanvasHost.swift, CanvasTools.swift, CanvasUI.swift, CloudShim.swift (CloudLog stub only), Resources/canvas.html (fixture), docs/fixtures/canvas-fixture.html, docs/canvas.md
- Copied real Fork/Cloud/Cloud.swift + CloudSocket.swift (CONTRACT_READY present 14:51)
- Patched: Package.swift, build.sh, Browser.swift(3), Tab.swift, Address.swift, Side.swift(2), Bench.swift, bench, Spaces.swift, CommandBar.swift, Tools.swift, Agent.swift
- TODO: build (bg log /tmp/copper-canvas-build.log; release build slow ~15min, others compiling), probe test, PATCHES row, CHANGELOG, poll real bundle
## Status 15:41
- REAL bundle integrated (sha 80accf4f, dist 15:16). Fixture at docs/fixtures/canvas-fixture.html.
- Build: ./build.sh debug (~1 min). Probe launcher: /tmp/canvas-probe.sh ; kill: pkill -f "copper-canvas/build/Copper.app/Contents/MacOS/Copper"
- Fixed: dropping page updates during restore broke Yjs (gap) → now keep all; force-compact after open w/ log.
- Persistence verified across 2 relaunches. Tools all verified (list/open/read/apply/select/focus/create/invite errors/screenshot).
- Crash seen once: NSWindow Update Constraints loop in headless while popover open via bench (ScrollView in popover?) — avoid popover open in headless; use `bench canvas ui picture PATH [dark]`.
- Fixed: CanvasLinks.label for unknown canvas; restore icon. Pending: stale tabs of deleted canvases (wiped store but registry lost) — fine.
- TODO: verify card pictures, final screenshots, CommandBar rows test (bench newtab), Address typed copper://canvas, report.
## Status 15:57 — E2E cloud verified
- Own server: /tmp/cce-copper-cloud --config /tmp/cce/cce.toml serve (127.0.0.1:18461, tls off, db copper_cloud_canvas_e). Users ada@/bob@example.com; cloud.json written in worlds canvase/canvasf. Probe F: /tmp/canvas-probe-f.sh (port 4162). Server read helper: python3 /tmp/cce/read.py WORLD CANVAS_ID
- Verified: personal local history merged to server; shared create/invite/accept/decline/rename/leave/delete/members; live edits both ways; collaborators=1 (count by awareness user.id); offline edit synced after server restart.
- Fixed: awareness multi-message frames; collaborators by person; remote rename retitles; removed closes pending tabs.
- Screenshots: /tmp/canvas-e-2.png (canvas tab), /tmp/canvas-e-shared.png (shared live + door dot), /tmp/canvas-card-cloud-both.png, /tmp/canvas-card-invite-members.png, /tmp/canvas-e-card.png, /tmp/canvas-e-card-dark.png, /tmp/canvas-e-card-states.png
- Remaining: browser_snapshot on canvas tab check, multi-tab fan-out check, re-poll bundle/cloud files, docs update (agents.md link, canvas.md bench), final report. Cleanup: kill probes + my server at end (leave db).
## DONE 16:12 — release build green (build 202610011609), transcript /tmp/canvas-e-transcript.txt, final shot /tmp/canvas-e-final.png. Probes + server stopped. Report delivered.
