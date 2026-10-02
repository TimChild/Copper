# Tab groups

A group is a name and a colour over a run of tabs in the sidebar. Copper
keeps the row flat — one array, as upstream has it — and draws a header
where a run of grouped tabs starts. Members sit next to each other; joining
a group moves the tab to the end of that group's run.

## By hand

- Right-click a tab › **Group** › an existing group, *New Group from Tab*,
  or *Remove from Group*.
- **⌃⇧G** — new group from the active tab.
- Drag a tab between two tabs of a group and it joins; drag it clear and it
  leaves.
- Click a header to fold the group; right-click it to rename, recolour,
  ungroup (label goes, tabs stay) or close every tab in it.
- Groups survive restart: `groups.json` holds the groups and each session
  entry carries its group id. Older automatic-grouping fields in that file
  are ignored.

Copper does not automatically group tabs. Opening or navigating a page never
moves it or displays a grouping suggestion. Groups change only when you use
the menu, keyboard shortcut, drag-and-drop, bench, or MCP tool.

## From the bench

```
./bench groups                       list groups and their members
./bench groups new NAME
./bench groups assign TAB NAME       (creates the group if needed)
./bench groups remove TAB
./bench groups dissolve NAME
./bench ai                           active lane, tier, and model
./bench ai lane key|claude
./bench ai tier haiku|sonnet|opus
```

## Where it lives

`Fork/Groups.swift` (model, persistence, membership, bench),
`Fork/GroupsUI.swift` (rows, headers, menus, and ⌃⇧G),
`Fork/Intelligence.swift` (Jev and model-lane clients used by other Copper
features), and `Fork/SettingsFork.swift` (the Settings pages). Hooks in
`PATCHES.md` › `groups-hooks` cover the manual group integration only.
