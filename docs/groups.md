# Tab groups

A group is a name and a colour over a run of tabs in the sidebar. Copper
keeps the row flat — one array, as upstream has it — and draws a header
where a run of grouped tabs starts. Members sit next to each other; joining
a group moves the tab to the end of that group's run.

## By hand

- Right-click a tab › **Group** › an existing group, *New Group from Tab*,
  *Remove from Group*.
- **⌃⇧G** — new group from the active tab.
- Drag a tab between two tabs of a group and it joins; drag it clear and it
  leaves.
- Click a header to fold the group; right-click it to rename, recolour,
  ungroup (label goes, tabs stay) or close every tab in it.
- Groups survive restart: `groups.json` holds the groups; each
  session entry carries its group id.

## Keys

Settings › Intelligence. Paste a **Jev key** (`Authorization: Bearer`,
`https://api.typesafe.ai/v1/systemone`) and choose the model lane in
[Intelligence](intelligence.md). The API-key lane also has a **router key** (any
OpenAI-compatible `/v1/chat/completions`; address and model names are fields).
Eye to reveal, clipboard to paste, **Test** to fire one question each way. Keys
are in `intelligence.json` beside the session, 0600 — not the keychain, because
an ad-hoc-signed rebuild changes the code hash and the keychain would prompt
every build.

## From the bench

```
./bench groups                       list
./bench groups new NAME
./bench groups assign TAB NAME       (creates the group if needed)
./bench groups remove TAB
./bench groups dissolve NAME
./bench ai                           active lane, tier, model
./bench ai lane key|claude
./bench ai tier haiku|sonnet|opus
```

## Where it lives

`Fork/Groups.swift` (model, persistence, membership, bench),
`Fork/GroupsUI.swift` (rows, headers, menus, ⌃⇧G),
`Fork/Intelligence.swift` (keys, Jev and model-lane clients), `Fork/SettingsFork.swift` (the Settings pages). Hooks in
`PATCHES.md` › `groups-hooks`.
