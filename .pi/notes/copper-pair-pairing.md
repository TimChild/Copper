# copper-pair: pairing codes task (2026-10-01)
Worktree /Users/felipearce/src/copper-pair (branch cloud-pair). NO git mutations.
Plan:
- Cloud.swift: PairingCode type + Cloud.Code enum + parseCode; parseLinkCode = k-only view; CloudTrust.seen; pair(code, trusting:) + adoptPaired (atomic); Failure.seen for TOFU.
- New Fork/Cloud/CloudPairing.swift: mint/list/revoke + CloudPairing.shared ObservableObject (current code, poll used_at, pairHere(code,trusting,sync)).
- CloudSettings.swift: Connect field detects link vs pairing; Pair another Mac card (after devices, before account).
- CommandBar.swift (Fork file, but listed in PATCHES rows) -> amend cloud-hooks PATCHES row.
- CloudBench: pair, pairing-code, pairing-codes, revoke-pairing; selftest checks; bench help text.
- docs/cloud.md section + CHANGELOG cloud line.
Server: /v1/auth/pair 404 on local 8443 as of start; copper-cloud docs/api.md has no pairing yet (ADMIN_API_READY exists, admin-api.md only).
Status: (update below)
