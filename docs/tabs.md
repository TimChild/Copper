# Tabs

`⌃Tab` and `⌃⇧Tab` walk the row (so do `⌘⇧]` and `⌘⇧[` in the **Tabs** menu).
In **Settings › Tabs**, **⌃Tab switches to** chooses whether Control-Tab follows
the next tab in the row or the tabs used most recently. Plain `Tab` never
switches tabs: on a page it is the page's (moving between fields, a site's own
Tab-to-accept, code editors), and in the address field, `⌘T` and `⌘K` it takes
the completion on offer — the text goes in the field with the caret after it,
and nothing opens until Return.

In **Most recent tab** mode, `⌃Tab` walks older tabs and `⌃⇧Tab` walks back
toward newer ones. The list belongs to the current space. It is frozen while
Control is held and committed when Control is released, so two quick presses
flip between the two latest tabs. Holding Control for about 180 ms reveals the
same walk as a small strip over the page; a quick press does not flash it.

Tab renaming keeps its existing Tab behaviour.
Closing a tab removes it from the list, and changing spaces rebuilds the list
from that space's row.

## Links from other apps

A link clicked in Slack, Mail, Forca or a terminal's `open https://…` opens in a new tab
in front of you (or in the blank tab you are on): the browser window at the top of the
stack, skipping Settings and other panels, then one in the Dock, then the first window
brought back if every window is closed. LaunchServices may hand the link to an agent's
headless or test-world Copper instead of yours; that probe passes it on to the main
Copper by pid (docs/headless.md). `.html`, `.webloc` and `.url` files opened with
Copper open their page (`Fork/LinkRelay.swift`).

## Coming back to a sleeping tab

A tab that went to sleep shows its last picture the instant it is picked — drawn at
the size it was taken, from the page's top-left corner, on the page's own background
colour, inside the stage as it is now (the picture never sizes the stage, so the
sidebar never moves) — and the picture comes down once the rebuilt page has painted.
The rebuilt page loads once its view is in the window (with one bounded fallback for
an offscreen view); putting the tab back to sleep or sending it elsewhere cancels that
restore's delayed work.
