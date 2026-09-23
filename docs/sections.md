# The sidebar's three sections

Arc's sidebar is three blocks, and Copper's are the same three.

**Favourites** — the grid of squares at the top. Upstream's pins; nothing
here changed them.

**Saved** — the tabs you keep, above the hairline and the "New Tab" row. It
is the long block and the only one that scrolls without limit. Folders (tab
groups) live here: a Today row that joins a folder comes up with it.

**Today** — everything else, newest at the top, under the "New Tab" row. It
takes only as much of the column as it needs, up to a few hundred points.

## Which block a tab is in

An explicit flag, not a guess. `Session.Entry.saved` travels in the session
file, and `Sections.saved` holds it while the app is up. A file written by
upstream Search has no flag at all, so everything in it restores as saved —
an old session never lands in a block that archives itself.

A tab crosses the seam three ways:

- drag the row a clear step out of its block — up out of Today saves it,
  down out of Saved lets it go;
- **Save** / **Unsave** on the row's context menu;
- `./bench sections save ID` / `./bench sections unsave ID`.

Saving parks the row at the bottom of Saved, right above the seam, and the
column scrolls there so it does not look as if the tab vanished. Unsaving
puts it at the top of Today, and takes it out of its folder, since folders
are a Saved thing.

## The archive

Each tab remembers when it was last in front (`Session.Entry.seen`, Unix
seconds). At launch, every half hour, and whenever you switch to a space,
Today rows nobody has looked at inside the window are closed — through
`Browser.close`, the same path the cross on the row takes, so every one of
them waits in **Reopen Closed Tab**. Saved rows and favourites are never
touched, and neither is the row you are looking at.

The window is **Settings › Tabs › Archive Today after**: 12h, 24h (the
default), 48h, or Never.

## The bench

    ./bench sections                     counts per space, and Today with each row's age
    ./bench sections save ID
    ./bench sections unsave ID
    ./bench sections archive             the sweep the clock would have run
    ./bench sections archive 2           …against a two-hour age instead, for tests
    ./bench sections window 12h|24h|48h|never

## Importing from Arc

`./arc-import` marks Arc's per-space **pinned** tabs saved and its **open**
tabs Today, newest first, each carrying `timeLastActiveAt` as its `seen`
(Arc counts seconds from 2001; the importer adds 978307200). Arc's
favourites are still the pin grid, and Arc's folders are still tab groups.
