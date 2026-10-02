# Intelligence — model access and the model picker

Copper keeps its model access in Settings › Intelligence. There are two lanes. Jev (TypeSafe) is a separate fast helper and is unchanged.

## The two lanes

**API key** uses an OpenAI-compatible gateway (LiteLLM). Copper sends the gateway address and an API key that you enter in Settings. The gateway chooses and runs the model; no Claude account is needed.

**Claude account** signs in with a claude.ai account — Pro, Max, Team or Enterprise — like Claude Code does. Copper opens an OAuth with PKCE flow in a Copper tab, receives the callback on a loopback port, and stores the access and refresh tokens in `claude.json` with mode 0600. Tokens refresh silently. Inference goes straight to `https://api.anthropic.com/v1/messages` with the Claude Code identity headers; no API key is involved.

The Claude account lane is only for the account you sign in. Copper does not copy the account session into a page or send it through the agent link.

## The picker

The picker has three choices: **Haiku**, **Sonnet** and **Opus**. Sonnet is the default. One choice applies to the agent pane and Jev's text and extract helper. The model name for each choice is editable for each lane. The defaults are `claude-haiku-4-5`, `claude-sonnet-5` and `claude-opus-5-5` for the Claude account lane, and `haiku`, `sonnet` and `opus` for the API-key lane.

Jev (TypeSafe) is separate and unchanged. Its key and endpoint remain the Jev fast lane; the picker controls the model used when Copper needs a model response.

## The files

- `intelligence.json` holds the Jev and API-key lane settings. It is beside Copper's session data and is mode 0600.
- `claude.json` holds the Claude account credentials. It is beside `intelligence.json` and is mode 0600.

Copper never puts a token in status output, the CLI output, or a transcript.

## What leaves the Mac

With the API-key lane, Copper sends the prompts and the page or tab information needed by the feature to the gateway address you configured. With the Claude account lane, model requests go directly to Anthropic's Messages API. Jev requests go to the TypeSafe endpoint when Jev is enabled. The account token stays in `claude.json`; the agent link never carries it. Ordinary page requests still go only to the sites you open.

## CLI and bench

The loopback CLI controls the settings without printing secrets:

```sh
copper intelligence status
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

`./bench ai` reports the active lane, tier, model, model readiness and Claude-account readiness. `./bench ai lane key|claude` and `./bench ai tier haiku|sonnet|opus` change the active choice.

## Troubleshooting

- **The sign-in tab did not come back.** Copy the code or redirect text from claude.ai and run `copper claude paste -`, then paste it on stdin.
- **“Sign-in expired.”** Sign in again in Settings › Intelligence, or run `copper claude signin`.
- **429.** The Claude account is rate-limited. Wait and try again, or use the API-key lane.
