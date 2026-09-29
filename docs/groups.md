# Tab groups, and the models that fill them

A group is a name and a colour over a run of tabs in the sidebar. Copper
keeps the row flat — one array, as upstream has it — and draws a header
where a run of grouped tabs starts. Members sit next to each other; joining
a group moves the tab to the end of that group's run.

## By hand

- Right-click a tab › **Group** › an existing group, *New Group from Tab*,
  *Suggest a Group*, *Remove from Group*.
- **⌃G** — accept the suggestion under the tab if there is one, otherwise ask
  for one for the active tab. **⌃⇧G** — new group from the active tab.
- Drag a tab between two tabs of a group and it joins; drag it clear and it
  leaves.
- Click a header to fold the group; right-click it to rename, recolour,
  ungroup (label goes, tabs stay) or close every tab in it.
- Groups survive restart: `groups.json` holds the groups and rules; each
  session entry carries its group id.

## By itself

Settings › Intelligence › **Group new tabs**: Off / Ask / Automatic.

A second after a page finishes loading — not private tabs, not pinned, not
the bench's, not one already in a group, not the same host it was judged on
before — the tab is weighed by four judges, cheapest first, each only if the
one before had nothing:

1. **Your rules.** `github.com → Code`, `*.atlassian.net → Work`,
   `github.com/Exowatt-Labs → Labs`. Free, and final.
2. **Jev** (TypeSafe System One, `jev-latest`). One call, two questions:
   a `choice` among the groups present (each described by its name, hosts
   and titles) plus `none`, and a `noul` "worth grouping at all". Taken when
   its confidence clears the bar (default 60%). ~200 ms.
3. **The model lane** (the API-key gateway or Claude account selected in
   [Intelligence](intelligence.md); Sonnet by default). Asked when Jev was unsure, or when
   nothing fits and a *new* group needs a *name* — which a closed choice can't produce.
   JSON in, JSON out, read leniently.
4. **Same site.** No keys at all: a tab from a host a group already holds
   joins it.

*Ask* puts a one-line chip under the tab — ✓ / ✕, gone after 15 s.
*Automatic* just does it and says so in the line at the bottom. In either
mode a tab that navigated elsewhere while a judge was out is left alone.

Only the tab's address and title, and the names, hosts and titles of your
open groups and tabs, are sent. Never page contents.

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
./bench groups                       list, with the pending suggestion if any
./bench groups new NAME
./bench groups assign TAB NAME       (creates the group if needed)
./bench groups remove TAB
./bench groups suggest TAB           ask the judges now
./bench groups dissolve NAME
./bench ai                           active lane, tier, model, mode, last decision
./bench ai lane key|claude
./bench ai tier haiku|sonnet|opus
./bench ai mode off|ask|auto
```

## Where it lives

`Fork/Groups.swift` (model, persistence, membership, bench),
`Fork/GroupsUI.swift` (rows, headers, chip, menus, ⌃G),
`Fork/Grouper.swift` (the judges), `Fork/Intelligence.swift` (keys, Jev and
model-lane clients), `Fork/SettingsFork.swift` (the Settings pages). Hooks in
`PATCHES.md` › `groups-hooks`.
