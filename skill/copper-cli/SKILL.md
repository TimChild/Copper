---
name: copper-cli
description: Use this when an agent needs to drive the user's own signed-in Copper browser from bash; prefer `copper run "<goal with every concrete value>"` for multi-step tasks, use `copper observe` or `copper extract` to read, and verify DONE yourself.
---

# Copper CLI

`copper` drives the Copper window already open on the user's Mac. It uses the
same local MCP server as the agent integration; no new browser or sign-in is
created. Enable **Settings › Agents › Let agents drive this window** once.

| Command | Use |
|---|---|
| `copper tabs` | List tabs. |
| `copper signin [--account USER] [--otp] [--no-submit] [--json]` | Fill a shared saved account on the current tab (submits by default). |
| `copper autofill card|identity|field [--name NAME] [--submit]` | Fill a shared Bitwarden card, identity, or custom field; vault values are never returned. |
| `copper health` | Check connectivity and Jev mode. |
| `copper open URL` / `copper go URL` | Open a tab / navigate the current tab. |
| `copper run "GOAL" [--url URL] [--new-tab]` | Let Jev complete a multi-step goal. |
| `copper observe [-n N]` | Fast indexed read of the visible page. |
| `copper extract "INSTRUCTION" [--full]` | Return a structured page read. |
| `copper snapshot` / `copper text` / `copper find TEXT` | Read the page. |
| `copper click REF` / `copper type REF TEXT` / `copper key KEY` | Act on a snapshot ref. |
| `copper shot [PATH]` / `copper eval 'JS'` | Save a screenshot / evaluate JavaScript. |
| `copper --json COMMAND` | Return the raw result object for scripts. |
| `copper tools` | Inspect available capabilities. |
| `copper session list` | List session.json and session.previous.json with counts and mtimes. |
| `copper session restore [PATH] [--quit]` | Restore a session backup; default is session.previous.json. |
| `copper link [status\|on\|off]` | The agent link: let the owner's bots use this browser (`--json` for status). |
| `copper link token fxb_…` / `copper link api URL` | Set the personal token / app address. |
| `copper link grants` / `grant @bot` / `revoke @bot` | Who has access; give or take one bot's access. |
| `copper link revoke` | Revoke the whole link — every bot loses the tools, Copper disconnects. |
| `copper link calls` | Recent calls bots made through the link (`--json` for scripts). |
| `copper intelligence [status]` | Jev/router readiness as JSON: `{jevReady, routerReady, routerURL, routerModel, jevModel}` — never a key. |
| `copper intelligence set [--jev K] [--router-key K] [--router-url U] [--router-model M] [--text-model M]` | Write keys/settings into `intelligence.json` (0600) through the running app; a value of `-` is read from stdin. |
| `copper intelligence reload` | Re-read `intelligence.json` (same as `kill -HUP` on the app). |
| `copper bitwarden [status]` | The Bitwarden vault as JSON: `{ok, cli, cliVersion, state, email, server, lastSync, agentAccess, stayUnlocked, counts}` — never a password, key or session. |
| `copper bitwarden login -` | Sign in + unlock from ONE JSON object on stdin (`server, email, password, clientId, clientSecret, otp, otpMethod, share, stayUnlocked`); secrets are refused on argv. |
| `copper bitwarden lock` / `logout` / `sync` | Drop the session / sign out and wipe the CLI state / pull the vault now. |
| `copper bitwarden policy [--share folder\|all] [--stay-unlocked on\|off]` | What agents may use (the `Agents` folder, or everything) and whether the session survives a restart. |
| `copper --launch …` | Explicitly opt into launching Copper when it is down (also `COPPER_LAUNCH=1`). |

Examples:

```bash
copper run "search Acme invoices for March 2026 and stop when the result is visible"
copper observe -n 20 --no-text
copper extract "Return the visible flight options with airline, time, and price" --schema '{"type":"array"}'
```

## Saved sign-in (no-secret contract)

`copper signin` calls the `browser_sign_in` tool for the current tab. It fills a
shared saved account inside Copper and submits by default; use `--account USER`
when several shared accounts match, `--otp` for the saved one-time code, or
`--no-submit` to leave the form filled. Add `--json` for the raw status object
(the flag is global and may appear anywhere). The MCP tool has the same
arguments: `account`, `what` (`password` or `otp`), and `submit`.

The operation returns only status, host, username, source/what, and submitted
state (or usernames when choosing among candidates). The password, one-time
code, and Bitwarden session key never appear in its MCP result, CLI output, or
Jev trace. `copper autofill card|identity|field [--name NAME] [--submit]` fills
from the unlocked Bitwarden vault; card numbers, security codes, addresses, and
custom-field values are never returned in MCP, CLI output, or Jev traces.
Sharing is controlled by Settings › Passwords › **Agent access**:
the share-everything switch and per-item toggles are the user-controlled policy.
A Bitwarden item in the `Agents` folder is shared automatically; a custom field
`copper-agent: deny` always denies sharing. Unshared credentials return an
error; there is no prompt in this flattened implementation. This is not a page
sandbox: with `--no-submit`, the secret remains in the DOM by design, so do not
follow it with ordinary `copper snapshot`, `copper text`, or `copper eval` reads.

The Jev fast path exposes a `SIGN_IN` control labelled “Sign in with the saved
account for this site” only when the current page has a password field and at
least one permitted account. It uses the same in-process password fill and
submit path as `browser_sign_in`; use `browser_sign_in`/`copper signin --otp`
for a one-time-code field. Private (`shy`) tabs, missing fields, locked
Bitwarden, and unshared credentials return errors.

The CLI does not launch Copper by default. When it is down, commands print `copper: Copper isn't running (or Settings › Agents is off). Start it with \`open -a Copper\`, or pass --launch.` and exit 2. This is deliberate: probes during a quit must not create a second app instance. `copper session restore` refuses while Copper is running unless `--quit` is supplied; it saves the current session before replacing it and relaunches after the copy.

`copper link …` reaches the app through the same local server, so it needs **Settings › Agents › Let agents drive this window** on even though the agent link itself does not. It exits 1 when the agents app refuses (a bad token, an unknown bot) and 2 on usage errors or when Copper is unreachable. Never echo the `fxb_` token back into a transcript.

`copper bitwarden …` also goes through the local server; it exits 0 on `ok: true`, 1 on `ok: false` (with a one-line `error`), 2 on usage or when Copper is unreachable. Never put the master password or API secret on the command line — pipe them into `copper bitwarden login -`, and never echo them into a transcript.

`copper intelligence …` also goes through the local server. Its output is always JSON and never contains a key; pass keys with `-` (stdin) rather than on the command line where you can, and never echo them into a transcript. `copper health --json` reports `headless: true` when Copper runs as a background service (`Copper --headless`, docs/headless.md) — then there is no window to look at, dialogs are auto-declined, and the port may be set by `SEARCH_MCP_PORT` (the CLI honours it too).

Jev's DONE is a claim, not proof: read the page again with `copper observe` or
`snapshot` before reporting that an action succeeded.
