# Changelog

What changes in Search from one version to the next, newest first.

**Unreleased** gathers what is done since the last version, as it lands:
every fix and every addition gets its line the day it is merged. When a
version ships, the section takes its number and date, its gist becomes the
paragraph in `NOTES.md` (what Settings and the updater show), and the list
is what gets posted as the update. What is planned but not done yet lives
in [ROADMAP.md](ROADMAP.md).

## Unreleased

### Added (Copper)

- **Safe CLI and session recovery.** `copper` no longer launches Copper during a probe unless `--launch` (or `COPPER_LAUNCH=1`) is explicit; `copper session list` and `session restore` expose the retained backup, while ⌘K can restore `session.previous.json`. Session writes refuse launch-time empty overwrites, rotate one previous copy before a large drop, and stay atomic.
- **Copper feed updates.** Settings › Updates, ⌘K, and `./bench updates` check the internal feed and can back up the session, upgrade through Homebrew (or the feed installer), and relaunch without losing tabs.
- **Agents drive the window you have open.** Settings › Agents turns on an MCP server on 127.0.0.1 (bearer token, Origin-checked) with Playwright MCP's tool names — `browser_snapshot`, `browser_click`, `browser_type`, `browser_navigate`, `browser_take_screenshot`, `browser_tabs` and the rest — so a skill written for Playwright works on your real tabs and sign-ins. Clicks and keys arrive as real events; refs come from an accessibility snapshot. Copy-config buttons for Claude Code / phi (HTTP) and Claude Desktop (`--mcp-stdio` pipe, launches Copper if needed). `./bench agent`.
- **Jev mode — ultrafast.** Settings › Agents › *Let the agent hand Copper a goal* adds `jev_run`, `jev_step` and `jev_observe` to the MCP: browser-use's [jev-ultrafast](https://github.com/browser-use/jev-ultrafast) loop ported to run natively in the tab you have open. One TypeSafe request per cycle picks the operation (CLICK, TYPE_TEXT, SELECT, SCROLL, WAIT, DONE, BLOCKED) and an indexed element at once; the router writes any text; freshness guards and occlusion checks run before every real click or keystroke. An agent hands over one plain-English goal and gets the trace back in seconds ("open the Wikipedia article on Gödel's incompleteness theorems": 2 actions, 5.2 s). `jev_extract` reads values off the page as one JSON object (optionally to a schema). A **Text model** field picks the small model that types and extracts, separate from the grouping router. Two **Copy prompt** pills — one for the Playwright-shaped tools, one for Jev mode — give the agent a paragraph on where Copper listens, the token, and what to call. `./bench agent jev on|off`.
- **The agent in the window (⌘E).** Copper as an MCP *client*: a chat pane beside the page whose model has Copper's own tools bound locally — `browser_*`, and the Jev tools when Jev mode is on — plus whatever MCP servers `mcp.json` names (the shape Claude Code and phi read; Streamable HTTP and stdio, `${VAR}` from the environment), shown as `server__tool`. ⌘⇧E is *Ask About This Page*. Tool calls are chips you can read; screenshots go back to the model as pictures. Settings › Agents › *The agent in the window*: model, page context, mcp.json, connected servers. `./bench agent ask|chat|servers`.
- **Jev-first terminal setup.** The bundled `copper` CLI now installs with `copper setup phi|claude|cli|status`; phi and Claude Code get eager Copper tools plus a `/jev` command whose first action is `mcp_copper_jev_run`, with endpoint and bearer-token merges kept at mode 0600. The generated prompts put frontmatter first and retain the setup marker for status checks.
- **Tab groups**, with a colour and a header in the sidebar; fold, rename, recolour, ungroup, close all. Drag a tab into a run to join it. ⌃G, the tab's context menu › Group, and a Groups menu.
- **Smart grouping.** A second after a page lands, Copper weighs it against your groups: your rules first (`github.com → Code`), then Jev (TypeSafe System One — one typed choice, ~200 ms, with a confidence), then the router (LiteLLM, Sonnet by default) when Jev is unsure or a new group needs a name, then a plain same-site match with no keys at all. Ask mode puts a one-line chip under the tab; Automatic just does it. Only the tab's address and title and your group names leave the Mac.
- **Settings › Intelligence**: paste a Jev key and a router key (eye/paste buttons, 0600 file beside the session), pick the router model, set Jev's confidence bar, add rules, and test both lanes with one click. `./bench ai`, `./bench groups`.

### Added

- ⌘S folds the sidebar away and the page takes the whole window; the left edge brings the tabs back out. Thanks [@kndpt](https://github.com/kndpt) ([#7](https://github.com/driceroland/Search/pull/7))
- A skill that teaches coding agents to drive Search with `./bench`. Thanks [@jasonkneen](https://github.com/jasonkneen) ([#14](https://github.com/driceroland/Search/pull/14))

### Fixed

- A private tab now leaves nothing behind: it no longer shows up in Recently Closed. Thanks [@yuxino](https://github.com/yuxino) ([#6](https://github.com/driceroland/Search/pull/6))
- ⌘L then Return keeps the whole address, the part after `?` included. Thanks [@yuxino](https://github.com/yuxino) ([#5](https://github.com/driceroland/Search/pull/5))
- A floating video shows the whole picture on YouTube, and the page comes back to its tab when it lands. Thanks [@Chinteyley](https://github.com/Chinteyley) ([#9](https://github.com/driceroland/Search/pull/9))
- No white flash when a link opens a new tab in dark mode. Thanks [@RanaOsamaAsif](https://github.com/RanaOsamaAsif) ([#3](https://github.com/driceroland/Search/pull/3))
- Typing no longer makes the Mac beep when a page hasn't put its cursor in a field yet — starting a reply on X, for one. ([cc8aa58](https://github.com/driceroland/Search/commit/cc8aa58))

## 1.0 — 23 September 2026

The first version. A browser for the Mac with nothing in the way: tabs in a row or down the side, pinned tabs that keep their place, and one field for addresses and searches. Ads blocked before they load, passwords and passkeys in your keychain, anything on a page hidden for good, reading mode, floating video, Chrome extensions from the Chrome Web Store (macOS 15.4 or later), and tabs that sleep after half an hour. 2.9 MB, on the engine already in macOS.
