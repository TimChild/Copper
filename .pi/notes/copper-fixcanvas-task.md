# copper-fixcanvas (cloud-fixcanvas branch) — review fixes
Worktree /Users/felipearce/src/copper-fixcanvas. NO git mutations. Don't edit Cloud.swift/CloudSettings/CloudAuth/CloudBench or Canvas/ (web).
Helper: source /tmp/fixcv/env.sh (B, start_world, stop_world, cli). Worlds fixa:4175 fixb:4176. Accounts in /tmp/fixcv/accounts, stamp /tmp/fixcv/stamp, pw correct-horse-battery.
Done code: CloudSync .canvas domain (persisted in cloud-sync.json Saved.canvas since SyncPrefs is in Cloud.swift), didChange, syncs();
Canvas.swift room(for:) gating + account match, listAccount/refreshed reset, signedOut, CanvasStore appendRemote/pending/flush/flushAll;
CanvasHost roomId/synced/restartPage/checkpoint/hand()/post()/status setStatus, sweeper recovery, willTerminate flush; CanvasWire.sync;
CanvasUI D01-D04 + signed-out group + Personal subtitle; B05 Drive.ended(summary:) + Outcome.result + DrivePane + Agent.swift box + CanvasTools lines.
Build OK. C01 verified (off/browser-only/on/off) — pictures /tmp/fix-door-c01-*.png.
Next: X01 test, X03 test, X02 pics, D pics, B05 evidence, docs/canvas.md + CHANGELOG, e2e harness 13/13, kill worlds.

[progress] All acceptance verified: C01, X01 (disconnect+SIGTERM restart offline, also SIGKILL on-disk), X03 (incl. no-pause switching), X02 (door signed-out + other-account count; status modes), D (pics /tmp/fix-door-{populated,rename,invite,delete,members}[-dark].png), B05 (/tmp/fix-driver-results.png, drive status result field). Added Fork.swift render drive via NSHostingView (ScrollView). Docs + CHANGELOG done. Remaining: e2e harness 13/13, kill worlds, report.
