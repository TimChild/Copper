# Copper Cloud client task (worktree /Users/felipearce/src/copper-cloudc, branch cloud-cloudc)
- NO git mutations. Probe worlds only (SEARCH_PROBE=cloudc, MCP 4151). No keychain.
- Spec: /Users/felipearce/exowatt/reports/2026-10-01-copper-cloud-and-canvas-plan.md §0,1,2,5
- Dossier: /Users/felipearce/exowatt/reports/partials/2026-10-01/copper-arch-dossier.md
- DONE: Cloud.swift, CloudSocket.swift (contract), CloudAuth.swift, CONTRACT_READY touched (build ok 90s)
- CloudSync.swift is a stub (log only) -> next: full engine, CloudSettings.swift, Settings.swift .cloud page, CommandBar row, bench cloud verbs, docs/cloud.md, CHANGELOG, PATCHES, README
- Build: export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk SEARCH_SIGN_IDENTITY=-; ./build.sh

## Progress (later)
- Written: CloudMerge.swift (pure docs+merges+allowlist), CloudApply.swift (build/apply via Spaces/Prefs/Bookmarks/History), CloudSync.swift (engine), CloudSettings.swift (UI), CloudBench.swift (bench verbs + selftest)
- Hooks: Spaces.swift extension cloudAdopt/cloudOpen/cloudClose + restore() defer → CloudSync.start; Settings.swift .cloud; Bench.swift case "cloud"; bench script verb; CommandBar row
- Docs: docs/cloud.md, CHANGELOG <!-- cloud -->, README, PATCHES row cloud-hooks
- Local server: /tmp/cc-server (copied binary), config /tmp/cc-cloudc/cc.toml (127.0.0.1:8463, db copper_cloud_cloudc, metrics 9474), serving in bg, log /tmp/cc-cloudc/serve.log. link-code: COPPER_CLOUD_CONFIG=/tmp/cc-cloudc/cc.toml /tmp/cc-server link-code
- Build is SLOW (machine load ~35, other agents building); build log /tmp/cloudc-build.log
- Next: get build green, ./build.sh, probe worlds cloudc + cloudc2 (MCP 4151/4152), bench --world cloudc cloud ...

## DONE (2026-10-01 ~16:05)
- Build green (build 202610011604). E2E validated vs live copper-cloud (TLS pinned + plain-http loopback): link/pin negatives, signup/signin errors, spaces/settings/bookmarks/tabs/history sync, 409 merge, delete propagation, same-name Home rekey, relaunch persistence, 401 session sign-out, disconnect/logout, WebSocket wstest, settings page pictures.
- Bug found+fixed: Bookmarks per-node saves race on concurrent queue -> added Bookmarks.replace (upstream edit, PATCHES row updated).
- Torn down: probe worlds, test DB copper_cloud_cloudc, /tmp server. CONTRACT_READY left in place (SwiftPM 'unhandled file' warning; main thread should delete at merge).
- Remaining: final report only.
