# Intelligence — model access and the model picker

Copper keeps its model access in Settings › Intelligence. There are two lanes. Jev (TypeSafe) is a separate fast helper and is unchanged.

## The two lanes

**API key** uses an OpenAI-compatible gateway (LiteLLM). Copper sends the gateway address and an API key that you enter in Settings. The gateway chooses and runs the model; no Claude account is needed.

**Claude account** signs in with a claude.ai account — Pro, Max, Team or Enterprise — like Claude Code does. Copper opens an OAuth with PKCE flow in a Copper tab, receives the callback on a loopback port, and stores the access and refresh tokens in `claude.json` with mode 0600. Tokens refresh silently. Inference goes straight to `https://api.anthropic.com/v1/messages` with the Claude Code identity headers; no API key is involved.

The Claude account lane is only for the account you sign in. Copper does not copy the account session into a page or send it through the agent link.

## The picker

The picker has three choices: **Haiku**, **Sonnet** and **Opus**. Sonnet is the default. One choice applies to the agent pane and Jev's text and extract helper. The model name for each choice is editable for each lane. The defaults are `claude-haiku-4-5`, `claude-sonnet-5` and `claude-opus-5-5` for the Claude account lane, and `haiku`, `sonnet` and `opus` for the API-key lane.

### Floating names, never pinned ones

On the API-key lane Copper sends the gateway's **floating aliases** — `haiku`, `sonnet`, `opus` — so the agent follows the gateway to the newest model (Opus 5.5 today) with no change in Copper. phi shows these as `exowatt/opus` and so on; the gateway's own names have no prefix. Any spelling of a Claude tier is sent as its float: `exowatt/opus`, `exowatt/opus-5`, `opus-5`, `claude-opus-5`, `claude-opus-5-5`, `claude-sonnet-4-5-20250929` all go as `opus` or `sonnet`. A name that is not a Claude tier (`luna`, `gpt-4o-mini`) is yours and goes as typed, less an `exowatt/` prefix.

The Claude account lane talks to Anthropic directly, which has no float, so a Claude tier in any spelling is sent as Copper's current id for it (`claude-opus-5-5` for Opus).

An `intelligence.json` saved by an older build is migrated as it is read: `routerModels`, `routerModel`, `claudeModels` and `textModel` values that are a pinned or prefixed spelling of a tier become the float (or the Claude lane's current id); custom names are kept. The same rule applies to names set with `copper intelligence set`.

Settings › Intelligence › Model says which name is sent (*Sends opus*) and, once an answer has come back, the model it reported (*last answered by claude-opus-5-5-…*); the agent pane's model menu says the same.

### What goes on the wire

Both lanes send no `temperature`, no `thinking` block (disabled or budgeted) and no forced tool: `tool_choice` is `auto` (`{"type": "auto"}` on the Messages API) whenever tools are offered. Opus 5.5 refuses the first two, and `auto` is the one choice every model takes. `Router.body` and `Claude.body` build every request.

Jev (TypeSafe) is separate and unchanged. Its key and endpoint remain the Jev fast lane; the picker controls the model used when Copper needs a model response.

## Keys from Copper Cloud

A Copper signed in to a [Copper Cloud](cloud.md) asks it for model keys — `GET /v1/intelligence`, with the same instance key and session bearer as every other `/v1` call:

```json
{"jev": {"key": "…", "endpoint": "https://api.typesafe.ai/v1/systemone", "model": "jev-latest"},
 "router": {"key": "…", "url": "https://llm.dev.exowatt.com"},
 "updated_at": "2026-10-05T12:00:00Z"}
```

Any part may be `null` or missing. A 404 (a cloud from before this route), 401 or 403 means the cloud provides nothing; no error is shown. Copper asks after a cloud sign-in, at launch when linked and signed in, when Settings opens (at most once a minute) and every 30 minutes. A network failure keeps what was known.

What the cloud provides is kept in memory and in `cloud-intelligence.json` (mode 0600, beside `cloud.json`) so an offline launch still works, and is **never written into `intelligence.json`**. Signing out of the cloud, disconnecting it, or signing in as someone else deletes it.

This Mac's settings win, field by field:

| Field | Used |
|---|---|
| Jev key, API key | a non-empty key typed on this Mac; else the cloud's |
| Jev model | a name other than the default `jev-latest` typed on this Mac; else the cloud's; else the default |
| Jev endpoint, Gateway address | an address other than the default typed on this Mac; else the cloud's **when the cloud's key is the one in use** (a key typed here is never sent to an address the cloud chose); else the default |

So a cloud user with nothing typed has a working agent pane and Jev with no setup. Settings › Intelligence (and Settings › Agents › Jev key) say *Provided by Copper Cloud (host)* for each key the cloud supplies, with the key masked (`sk-…1a2b`) in the field's placeholder; typing a key there overrides it, and clearing the field goes back to the cloud's. The agent pane's model menu reads *Copper Cloud · host* while the cloud's API key is in use.

`copper intelligence sources` lists where each one comes from — `local`, `cloud` or `none` for the keys, `local`, `cloud` or `default` for the addresses and the Jev model — and never a key. `copper intelligence refresh` asks the cloud again now; `copper intelligence status` carries the same `sources` and a `cloud` block (host, what it provides, `updatedAt`, `fetchedAt`).

## The files

- `intelligence.json` holds the Jev and API-key lane settings. It is beside Copper's session data and is mode 0600.
- `claude.json` holds the Claude account credentials. It is beside `intelligence.json` and is mode 0600.
- `cloud-intelligence.json` holds the keys Copper Cloud provided, the cloud's host and when they were fetched. Mode 0600, written atomically, deleted on cloud sign-out or disconnect.

Copper never puts a token in status output, the CLI output, or a transcript.

## What leaves the Mac

With the API-key lane, Copper sends the prompts and the page information needed by the agent or Jev helper to the gateway address you configured. With the Claude account lane, model requests go directly to Anthropic's Messages API. Jev requests go to the TypeSafe endpoint when Jev is enabled. The account token stays in `claude.json`; the agent link never carries it. Ordinary page requests still go only to the sites you open.

## CLI and bench

The loopback CLI controls the settings without printing secrets:

```sh
copper intelligence status
copper intelligence sources           # local | cloud | none per key, never the key
copper intelligence refresh           # ask Copper Cloud for its keys again
copper intelligence set --lane claude --model sonnet
copper intelligence set --lane key --router-key -
echo "$ROUTER_KEY" | copper intelligence set --router-key -
copper intelligence reload

copper claude status
copper claude signin
copper claude paste -                 # read the callback code from stdin
copper claude signout
copper claude cancel
```

`copper claude signin` opens claude.ai in the running Copper window. Sign in there and let the callback return to Copper. If the callback cannot return, use `copper claude paste -`; stdin is preferred so the code is not put in the process list. `status` reports the lane, tier, model, readiness and account email, never a token. The commands need the loopback server and bearer token, and return 0 on success, 1 when Copper refuses an operation, and 2 for usage errors or an unreachable browser.

`./bench ai` reports the active lane, tier, model, model readiness, Claude-account readiness, `sources` and `answeredBy`. `./bench ai lane key|claude` and `./bench ai tier haiku|sonnet|opus` change the active choice. `./bench ai sources|refresh` are the CLI's two. `./bench ai selftest` (also part of `./bench agent selftest`) checks the model-name migration, the local-over-cloud merge, the `/v1/intelligence` decoder and the request shapes — probe world only.

## Troubleshooting

- **The sign-in tab did not come back.** Copy the code or redirect text from claude.ai and run `copper claude paste -`, then paste it on stdin.
- **“Sign-in expired.”** Sign in again in Settings › Intelligence, or run `copper claude signin`.
- **429.** The Claude account is rate-limited. Wait and try again, or use the API-key lane.
