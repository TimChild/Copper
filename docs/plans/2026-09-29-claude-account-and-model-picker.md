# Claude account sign-in + Haiku/Sonnet/Opus picker

Plan and **binding contract** for the parallel implementers. Every symbol named here
is the interface the other agents code against — keep names, signatures and
semantics exactly; add what you need *beside* them, never rename.

## What Felipe asked for

1. Model access has two lanes, chosen in Settings › Intelligence and remembered:
   - **API key** — what exists today: an OpenAI-compatible gateway (LiteLLM) with a key
     and an address (`Intelligence.Keys.routerKey` / `routerURL`).
   - **Claude account** — sign in with a claude.ai account (Pro / Max / Team / Enterprise)
     the way Claude Code does: OAuth with PKCE in a browser tab, no API key, tokens kept
     locally, refreshed silently. Inference then goes straight to Anthropic's Messages API
     with the account token.
2. A model picker — **Haiku / Sonnet / Opus**, default **Sonnet**, nothing else (no
   Fable) — in the agent pane's header (the ⌘E sidebar chat) and in Settings. One
   choice for the whole app: the pane and Jev's text/extract helper.
3. Simple and easy. Sign-in is one click in Settings or from the pane's empty state.
4. Validated live, then merged to `fork`, pushed, and released through the tap.

## Verified facts (tested 2026-09-29 with a real account token — do not re-derive)

- OAuth (same public client Claude Code / pi / OpenCode use):
  - client id `9d1c250a-e61b-44d9-88ed-5944d1962f5e`
  - authorize `https://claude.ai/oauth/authorize` with query
    `code=true&client_id=…&response_type=code&redirect_uri=…&scope=…&code_challenge=…&code_challenge_method=S256&state=…`
  - scopes `org:create_api_key user:profile user:inference`
  - redirect `http://localhost:<port>/callback` (any local port; the callback carries
    `code` and `state`). `state` **is the PKCE verifier** (that is what the reference
    clients send, and the token endpoint is given it back).
  - token `https://platform.claude.com/v1/oauth/token`, JSON POST
    `{grant_type: "authorization_code", client_id, code, state, redirect_uri, code_verifier}`
    → `{access_token, refresh_token, expires_in}`; refresh with
    `{grant_type: "refresh_token", client_id, refresh_token}` (same reply shape; the
    refresh token rotates — save both).
  - profile `GET https://api.anthropic.com/api/oauth/profile` (Bearer) →
    `{account: {email, display_name, full_name, …}, organization: {name, organization_type, …}}`.
- Inference with the account token: `POST https://api.anthropic.com/v1/messages`, headers
  `authorization: Bearer <token>`, `anthropic-version: 2023-06-01`,
  `anthropic-beta: claude-code-20250219,oauth-2025-04-20`, `user-agent: claude-cli/2.1.283`,
  `x-app: cli`, `accept: application/json`, `anthropic-dangerous-direct-browser-access: true`,
  `content-type: application/json`. The **first system block must be exactly**
  `You are Claude Code, Anthropic's official CLI for Claude.` (without it the API answers
  429). Do **not** send `temperature` and do **not** send a `thinking` parameter
  (`thinking.type=disabled` is rejected by Opus 5.5; adaptive thinking is the default and
  spends ~0 tokens on small asks). Give `max_tokens` headroom (asks ≥ 4096, agent 8192):
  thinking tokens count against it.
- Model ids that work with the token today: `claude-haiku-4-5`, `claude-sonnet-5`,
  `claude-opus-5-5`. Opus replies can start with a `thinking` block (empty text + signature)
  — echo assistant blocks back **sanitised** (below) on the next turn; tool loops verified.
- Tool use: `tools: [{name, description, input_schema}]`, `tool_choice: {type: "auto"}`;
  assistant `tool_use` blocks `{type, id, name, input}` (the API adds `caller` — strip it);
  results go back as a **user** message of `{type: "tool_result", tool_use_id, content}`
  blocks. Consecutive same-role messages must be merged into one.

## Files and owners

| agent | owns (only these) |
|---|---|
| `schema` (wave 0) | `Sources/Search/Fork/Intelligence.swift` additions; stub `Fork/ClaudeAccount.swift`; stub `Fork/Claude.swift` |
| `oauth` | `Sources/Search/Fork/ClaudeAccount.swift` (replaces the stub) |
| `api` | `Sources/Search/Fork/Claude.swift` (replaces the stub) |
| `core` | `Fork/Intelligence.swift` (`Router.ask` dispatch), `Fork/Agent/Agent.swift`, `Fork/MCP/Ultrafast.swift` guards |
| `ui` | `Fork/SettingsFork.swift`, `Fork/Agent/AgentPane.swift` |
| `cli-docs` | `Fork/MCP/CLI.swift`, `Fork/MCP/MCP.swift` (one route), `Fork/Fork.swift` (bench `ai`), `docs/*.md`, `README.md`, `CHANGELOG.md`, `skill/copper-cli/SKILL.md` |

No agent runs `git commit/push/merge/rebase/checkout` — the orchestrator merges.
Build check: `export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk SEARCH_SIGN_IDENTITY=-; swift build -c release --jobs 3`
(the tap builds on macos-15's older Xcode: Swift 5 mode, no bleeding-edge syntax,
no long `|`-chains in one expression).

## Contract

### `Intelligence` (Fork/Intelligence.swift — owner `schema`)

```swift
extension Intelligence {
    /// Where the model comes from.
    enum Lane: String, Codable, CaseIterable, Identifiable {
        case key      // API key + gateway address (LiteLLM, OpenAI-compatible)
        case claude   // Claude account (OAuth), straight to Anthropic
        var id: String { rawValue }
        var title: String   // "API key" / "Claude account"
    }
    /// The three sizes. One choice for the whole app.
    enum Tier: String, Codable, CaseIterable, Identifiable {
        case haiku, sonnet, opus
        var id: String { rawValue }
        var title: String   // "Haiku" / "Sonnet" / "Opus"
        var blurb: String   // "Quick" / "The balance" / "Thinks hardest"
    }
}

struct Keys {                       // existing fields stay; these are added
    var lane: Lane = .key
    var tier: Tier = .sonnet
    /// tier.rawValue → model id at Anthropic (Claude account lane)
    var claudeModels: [String: String] = Keys.defaultClaudeModels
    /// tier.rawValue → model name on the gateway (API key lane)
    var routerModels: [String: String] = Keys.defaultRouterModels
    static let defaultClaudeModels = ["haiku": "claude-haiku-4-5", "sonnet": "claude-sonnet-5", "opus": "claude-opus-5-5"]
    static let defaultRouterModels = ["haiku": "haiku", "sonnet": "sonnet", "opus": "opus"]
}
```

Lenient decoding as the existing fields do (a missing field takes the default; a map
with missing tiers is filled from the defaults). Migration: an old file whose
`routerModel` is set to something other than `haiku|sonnet|opus` and has no
`routerModels` seeds `routerModels["sonnet"] = routerModel` (what you asked for before
is what Sonnet means on your gateway). `routerModel` stays in the file, unused otherwise.

```swift
// Intelligence (MainActor) members
var lane: Lane { keys.lane }
var tier: Tier { keys.tier }
var routerReady: Bool                 // unchanged: key + parsable URL
var claudeReady: Bool                 // ClaudeAccount.shared.signedIn
var modelReady: Bool                  // lane == .key ? routerReady : claudeReady
var configured: Bool                  // jevReady || modelReady
/// The model name for the active lane. `named` may be a tier name ("opus"), a full
/// model name (returned as is), or empty/nil (→ the chosen tier's model).
func model(_ named: String? = nil, tier: Tier? = nil) -> String
var modelName: String                 // model()
/// One short line for menus and headers:
/// "Claude account · farce@exowatt.com" | "API key · llm.dev.exowatt.com" | "Not set up".
var accessLine: String
```

`status` keeps its old keys and adds `lane`, `tier`, `model` (resolved), `modelReady`,
`claudeReady`, `claudeAccount` (email or ""). `control(set)` additionally accepts
`lane` (`key|claude`), `tier` (`haiku|sonnet|opus`), `haikuModel`, `sonnetModel`,
`opusModel` (write the **active lane's** map), and keeps `routerModel` for compatibility
(writes `routerModels[tier]`). Unknown values → `["error": …]`, never a crash.

### `ClaudeAccount` (Fork/ClaudeAccount.swift — owner `oauth`)

```swift
@MainActor
final class ClaudeAccount: ObservableObject {
    static let shared: ClaudeAccount

    struct Credential: Codable, Equatable {
        var access: String
        var refresh: String
        var expires: Date          // real expiry (now + expires_in)
        var email = ""
        var name = ""              // display_name, else full_name
        var organization = ""
    }
    enum Phase: Equatable { case idle, waiting, exchanging, failed(String) }
    struct Failure: LocalizedError { let text: String; var errorDescription: String? { text } }

    @Published private(set) var credential: Credential?
    @Published private(set) var phase: Phase          // .idle at rest
    var signedIn: Bool                                // credential != nil
    var email: String                                 // credential?.email ?? ""
    /// "Felipe Arce · farce@exowatt.com", else the email, else "Signed in".
    var who: String

    /// Starts the flow: PKCE, a one-shot loopback listener on an ephemeral port,
    /// then opens the authorize URL in a new foreground tab of `browser`.
    func signIn(in browser: Browser)
    /// Manual fallback: the redirect URL, `code#state`, `code=…&state=…`, or a bare code.
    func complete(pasted: String)
    func cancel()                                     // stops the listener, phase → .idle
    func signOut()                                    // forgets the file and the credential
    /// A valid access token; refreshes when within 5 min of expiry (one in-flight refresh
    /// shared by concurrent callers). Throws Failure when signed out or refresh fails
    /// (a refresh failure with HTTP 400/401 also signs out).
    func token() async throws -> String
    /// After the API said 401: refresh regardless of expiry, return the new token.
    func refreshNow() async throws -> String
    /// Never a token: signedIn, email, name, organization, expires (ISO-8601 or ""),
    /// phase ("idle|waiting|exchanging|failed"), trouble (the failure text or "").
    var status: [String: Any]
    /// The `copper/claude` loopback method (CLI `copper claude …`):
    /// op status (default) | signin (needs `browser`; opens the tab) | paste {code} | signout | cancel.
    func control(_ params: [String: Any], in browser: Browser?) -> [String: Any]
}
```

File: `Store.file("claude.json")`, written 0600 like intelligence.json. On success:
save, fetch the profile (best effort), set `Intelligence.shared.keys.lane = .claude`,
close the sign-in tab it opened if that tab is still on claude.ai / the callback, and
`browser.announce("Signed in to Claude as …")`. The listener answers the callback with a
small HTML page ("Copper is signed in with your Claude account. You can close this tab.")
using the existing `Connection` / `HTTPRequest` / `HTTPResponse` from `Fork/MCP/MCP.swift`
(`HTTPResponse.contentType` is a `var`). Listener gives up after 10 minutes.

### `Claude` (Fork/Claude.swift — owner `api`)

```swift
/// Anthropic's Messages API, spoken with a Claude account token.
enum Claude {
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let identity = "You are Claude Code, Anthropic's official CLI for Claude."
    static let userAgent = "claude-cli/2.1.283"
    static let betas = "claude-code-20250219,oauth-2025-04-20"

    struct Failure: LocalizedError { let status: Int; let text: String; var errorDescription: String? { text } } // status 0 = transport

    /// One non-streaming completion. `messages` are Anthropic-shaped. Returns the whole
    /// payload (content, stop_reason, usage, model). Throws Failure on anything but 200.
    static func complete(token: String, model: String, system: String, messages: [[String: Any]],
                         tools: [[String: Any]] = [], maxTokens: Int = 8192, timeout: TimeInterval = 180) async throws -> [String: Any]
    /// A JSON ask in Router.Reply's shape (json via Router.json(in:)); max_tokens floored at 4096.
    static func ask(token: String, model: String, system: String, user: String,
                    timeout: TimeInterval = 40, maxTokens: Int = 400) async throws -> Router.Reply

    // The agent keeps its transcript in OpenAI chat shape; these translate.
    static func messages(fromChat: [[String: Any]]) -> [[String: Any]]
    static func tools(fromChat: [[String: Any]]) -> [[String: Any]]
    /// → ["role": "assistant", "content": String, "tool_calls": [OpenAI-shaped] (only if any), "_blocks": sanitised blocks]
    static func chatMessage(from payload: [String: Any]) -> [String: Any]
    static func sanitised(_ blocks: [[String: Any]]) -> [[String: Any]]
    static func text(in payload: [String: Any]) -> String
}
```

`messages(fromChat:)`: drop `role: system`; `user` string → string; `user` parts
(`{type: text}`, `{type: image_url, image_url: {url: "data:image/png;base64,…"}}`) →
`text` / `image {source: {type: base64, media_type, data}}`; `assistant` → its
`_blocks` (sanitised) when present, else a `text` block from `content` plus one
`tool_use` per `tool_calls[]` (`arguments` JSON string → object); consecutive `tool`
messages → one `user` message of `tool_result` blocks (`content` as a string); then
merge any consecutive same-role messages. `sanitised`: keep only
`text{text}`, `tool_use{id,name,input}`, `thinking{thinking,signature}`,
`redacted_thinking{data}`. `chatMessage`: `content` = joined text blocks,
`tool_calls` = `[{id, type: "function", function: {name, arguments: <JSON string>}}]`.
Errors: 401 → "Claude sign-in expired or was revoked — sign in again in Settings ›
Intelligence"; 429 → "Claude is rate-limiting this account right now — try again in a
moment"; 503/529 → "Claude is overloaded right now"; otherwise `error.message` from the body.

### Wiring (owner `core`)

- `Router.ask(...)`: when `keys.lane == .claude` → `ClaudeAccount.shared.token()` →
  `Claude.ask(token:model: Intelligence.shared.model(override), system:user:timeout:maxTokens:)`.
  The router lane is unchanged, except the default model is `Intelligence.shared.model(override)`.
- `Agent.complete(...)`: same lane switch → `Claude.complete(token:, model:, system: Agent.system,
  messages: Claude.messages(fromChat:), tools: Claude.tools(fromChat:))` → `Claude.chatMessage(from:)`.
  On `Claude.Failure` 401 → `refreshNow()` once, retry once.
- `Agent.run`: carry `reply["_blocks"]` into the assistant message it appends; `modelName` →
  `Intelligence.shared.modelName`; `ready` → `Intelligence.shared.modelReady`; the not-ready
  note: "Not set up yet — sign in with your Claude account or add an API key in Settings › Intelligence."
- `Ultrafast.fieldText` / `jev_extract` guards → `modelReady` (hop to the main
  actor where the caller is not on it), messages say "the model (Settings › Intelligence)".
- `Agent.Config.model` stays decodable but is no longer used.

### UI (owner `ui`)

Settings › Intelligence:
- Caption **Model access** → Card: `Line("Use", …) { Segmented(Lane) }`; then per lane —
  Claude: `Line("Claude account", signed-in → "Signed in as <who>" | waiting → "Finish signing
  in in the tab that opened, or paste what claude.ai shows here" | failed → the text)
  { Pill("Sign in"/"Sign out") ; while waiting a paste TextField + Ring + Pill("Cancel") }`;
  API key: the existing key / address rows. Then `Line("Model", tier.blurb…) { Segmented(Tier) }`
  and a compact `Line("Model names", "What Haiku, Sonnet and Opus are called <at Anthropic|on your gateway>")`
  with three small monospaced fields bound to the active lane's map. Then the existing
  **Check** row (lane-aware labels: "Claude ✓ claude-sonnet-5 812 ms").
- Caption **Jev — the fast lane** → Card with the Jev key row (moved out of "Keys").
- Agents page: drop the free-form "Model" row of *The agent in the window*; the Text model
  detail says "empty means the model you picked (<modelName>)"; every "router key" string
  becomes lane-aware ("Settings › Intelligence › Model access").
- AgentPane header: the model name becomes a `Menu` (borderless, chevron): three tier
  items with a checkmark on the current one, a divider, a disabled `accessLine`, and
  "Model access…" which opens Settings › Intelligence. Empty state when not ready: one
  sentence + two pills — **Sign in with Claude** (`ClaudeAccount.shared.signIn(in: browser)`)
  and **Use an API key** (open Settings › Intelligence). Composer placeholder likewise.
- Add `extension Browser { func openSettings(_ page: SettingsPanel.Page) }` in
  SettingsFork.swift: `settingsPage = page; Store.settings.set(page.rawValue, forKey: "settings.page"); tuning = true`.

### CLI, bench, docs (owner `cli-docs`)

- `copper intelligence set` gains `--lane key|claude`, `--model haiku|sonnet|opus` (tier),
  `--haiku-model`, `--sonnet-model`, `--opus-model`; usage text updated; `status` documents
  the new keys.
- New `copper claude status|signin|paste -|signout|cancel` → loopback method `copper/claude`
  (route it in `MCP.swift` beside `copper/intelligence`, calling
  `ClaudeAccount.shared.control(params, in: self.browser)`); `paste -` reads stdin. Output
  is the status JSON, never a token.
- `Fork.swift` bench `ai` adds `lane`, `tier`, `model`, `modelReady`, `claudeReady`.
- Docs: new `docs/intelligence.md` (the two lanes, sign-in, the picker, the files, what
  leaves the Mac); touch `docs/agents.md`, `docs/headless.md`, `docs/groups.md`,
  `README.md`, `skill/copper-cli/SKILL.md`; `CHANGELOG.md` Unreleased gets one **Added** line.
