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
| `copper signin [--account USER] [--otp] [--no-submit]` | Fill a shared saved account on the current tab (submits by default). |
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
| `copper --launch …` | Explicitly opt into launching Copper when it is down (also `COPPER_LAUNCH=1`). |

Examples:

```bash
copper run "search Acme invoices for March 2026 and stop when the result is visible"
copper observe -n 20 --no-text
copper extract "Return the visible flight options with airline, time, and price" --schema '{"type":"array"}'
```

## Saved sign-in (no-secret contract)

`copper signin` calls the `browser_sign_in` tool for the current tab. It fills a
saved account inside Copper and submits by default; use `--account USER` when
several shared accounts match, `--otp` for the saved one-time code, or
`--no-submit` to leave the form filled. The MCP tool has the same arguments:
`account`, `what` (`password` or `otp`), and `submit`.

The password and one-time code never appear in tool results, CLI output, Jev
traces, logs, or model-visible page reads. Sharing is controlled by Settings ›
Passwords › **Agent access**: the `shareAll` switch and per-item toggles are
the user-controlled policy. A Bitwarden item in the `Agents` folder is shared;
a custom field `copper-agent: deny` always denies sharing. Unshared credentials
simply return an error and are never prompted for or read by an agent.

The Jev fast path exposes a `SIGN_IN` control when the current page has a
password field and at least one permitted account. It uses the same in-process
fill and no-secret contract as `browser_sign_in`.

The CLI does not launch Copper by default. When it is down, commands print `copper: Copper isn't running (or Settings › Agents is off). Start it with \`open -a Copper\`, or pass --launch.` and exit 2. This is deliberate: probes during a quit must not create a second app instance. `copper session restore` refuses while Copper is running unless `--quit` is supplied; it saves the current session before replacing it and relaunches after the copy.

`copper link …` reaches the app through the same local server, so it needs **Settings › Agents › Let agents drive this window** on even though the agent link itself does not. It exits 1 when the agents app refuses (a bad token, an unknown bot) and 2 on usage errors or when Copper is unreachable. Never echo the `fxb_` token back into a transcript.

Jev's DONE is a claim, not proof: read the page again with `copper observe` or
`snapshot` before reporting that an action succeeded.
