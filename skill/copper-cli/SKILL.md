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
| `copper open URL` / `copper go URL` | Open a tab / navigate the current tab. |
| `copper run "GOAL" [--url URL] [--new-tab]` | Let Jev complete a multi-step goal. |
| `copper observe [-n N]` | Fast indexed read of the visible page. |
| `copper extract "INSTRUCTION" [--full]` | Return a structured page read. |
| `copper snapshot` / `copper text` / `copper find TEXT` | Read the page. |
| `copper click REF` / `copper type REF TEXT` / `copper key KEY` | Act on a snapshot ref. |
| `copper shot [PATH]` / `copper eval 'JS'` | Save a screenshot / evaluate JavaScript. |
| `copper --json COMMAND` | Return the raw result object for scripts. |
| `copper tools` / `copper health` | Inspect capabilities or connectivity. |

Examples:

```bash
copper run "search Acme invoices for March 2026 and stop when the result is visible"
copper observe -n 20 --no-text
copper extract "Return the visible flight options with airline, time, and price" --schema '{"type":"array"}'
```

Jev's DONE is a claim, not proof: read the page again with `copper observe` or
`snapshot` before reporting that an action succeeded.
