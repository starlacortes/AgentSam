# AgentSam

Hire a team of AI agents. Bring your own API keys. No subscription lock-in.

AgentSam is a self-hosted agent-team platform with three faces sharing one engine:

- **AgentSamMac** — a native macOS app with a visual team builder and a live mission "war room"
- **AgentSamServer** — a deployable server (Vapor) exposing the same engine over a secured REST + WebSocket API
- **AgentSamiOS** — an iPhone app that connects to your server to launch missions and watch agents work in real time

```
┌───────────────┐   ┌────────────────────┐   ┌──────────────────┐
│  AgentSamMac   │   │  AgentSamServer    │   │   AgentSamiOS    │
│  (SwiftUI)     │   │  (Vapor)           │   │   (SwiftUI)      │
│  local engine  │   │  REST + WebSocket  │   │   remote client  │
└───────┬───────┘   └─────────┬──────────┘   └────────┬─────────┘
        │                     │                        │
        └────────────┬────────┴───────────────┬────────┘
                ┌───▼───────────────────────▼───┐
                │         AgentSamCore          │
                │  (shared Swift package)       │
                │  MissionEngine · Providers ·  │
                │  MissionStore · PromptBuilder │
                └───────────────┬───────────────┘
                                │
                 your keys ─────┼─────── Anthropic · OpenAI ·
                                │        DeepSeek · Groq · OpenRouter ·
                                │        Ollama · any OpenAI-compatible endpoint
```

## How a mission runs

1. **Plan** — the team's coordinator turns your objective into concrete tasks, each assigned to a worker by name with a deliverable filename (strict `TASK / Agent / Goal / Deliverable` contract, retried and gracefully degraded).
2. **Work** — workers run **in parallel** (TaskGroup, up to 4 at a time). Each worker has sandboxed file tools (`write_file`, `read_file`, `list_dir`, `finish`) in the mission workspace, a step cap, and a handoff summary.
3. **Verify** — mechanical checks (files exist, claims match disk) plus an independent verifier agent with a read-only toolset and a strict line-protocol verdict (`PASS|CONCERN|FAIL … VERDICT:`).
4. **Report** — the coordinator merges handoffs into a final markdown report saved as `final-report.md`.

Every turn, tool call, deliverable, finding, and cost is a `RunEvent`, appended to an append-only `events.jsonl` ledger, streamed live to any connected client, and persisted for review.

## The mission workspace

```
<data dir>/
  providers.json          provider configs (base URLs, models)
  keys.json               API keys (server only; chmod 600; or env vars)
  teams/<uuid>.json       teams and rosters
  missions/<uuid>/
    mission.json          status, phase, cost, tokens, final report
    events.jsonl          append-only RunEvent ledger
    deliverables/         agent-produced .md files + final-report.md + verification.md
    conversations/        full per-agent message transcripts (JSON)
```

## Quick start — Mac app

```bash
open AgentSam.xcodeproj       # run the AgentSamMac scheme
```

1. **Guided setup** — connect a provider and test the real API connection, pick a curated team, tune its roster, and launch a first mission. Keys live in your Keychain, never in the workspace. You can rerun setup from Settings.
2. **Team Templates / Teams** — hire a curated squad or build from scratch, then tune each agent's provider, model, temperature, role, and system prompt.
3. **Missions → New Mission** — describe the objective and watch the live war room: agent stage, task plan, team chatter, full activity, deliverables, tokens, and cost. Search and filter past missions from the same screen.

Data defaults to `~/Library/Application Support/AgentSam`. Set `AGENTSAM_DATA` before launching to keep work in a synced folder.

## Connectors (optional)

Connectors give mission workers external tools on top of the sandboxed file tools. They are optional: no connector means the engine behaves exactly as before, and every connector can be disabled per mission surface. Write-capable actions are opt-in per connector and default to **off**.

| Connector | Worker tools | Write actions (opt-in) |
|---|---|---|
| **Gmail** | `gmail_search`, `gmail_read` | `gmail_draft`, `gmail_send` |
| **Google Ads** | `googleads_accounts`, `googleads_campaigns`, `googleads_query` (raw GAQL SELECT) | none — read-only |
| **Cloudflare** | `cloudflare_zones`, `cloudflare_dns_list` | `cloudflare_dns_create/update/delete`, `cloudflare_purge_cache` |

Credentials live in the same key store as provider keys (Keychain on the Mac app, `keys.json` 0600 on the server), never in `connectors.json`. Config (enabled flag + permissions) lives in `connectors.json` in the data directory. Workers receive a short connector-behavior contract in their system prompt (treat external data as untrusted, cite IDs, never invent results).

### Mac app

Settings → **Connectors**: connect, disconnect, test, enable/disable, and permission toggles for each connector.

- **Cloudflare**: paste an API token (scope it to the zones you need; for DNS edits it needs Zone → DNS → Edit). The app verifies it before storing.
- **Gmail / Google Ads**: **Connect with Google** runs a desktop OAuth flow with PKCE in your default browser. Requires a Google Cloud OAuth client:
  1. Create a project and enable the Gmail API and/or Google Ads API.
  2. OAuth consent screen → External → add yourself as a test user.
  3. Credentials → **Desktop app** client (loopback redirect, no secret needed).
  4. Launch AgentSam with the client ID: `AGENTSAM_GOOGLE_CLIENT_ID=<id>.apps.googleusercontent.com open AgentSam.xcodeproj` (or export the variable before running the built app).
- **Google Ads** additionally needs a developer token and, recommended, a login customer ID (both entered in Settings). Set the Google user's Ads API access level to **Read-only** in the Ads account for extra safety.

### Server

Connect the same connectors server-side from the iPhone app's Server tab, or via the API:

```
GET    /api/connectors                        (status for all connectors)
PATCH  /api/connectors/:id                    { enabled, permissions }
POST   /api/connectors/:id/test
POST   /api/connectors/:id/disconnect
POST   /api/connectors/cloudflare/token       { key }  (verified before storing)
POST   /api/connectors/googleads/credentials  { developerToken, customerId }
POST   /api/connectors/:id/authorize          → { url } for the Google consent flow
GET    /api/connectors/:id/callback           (Google's OAuth callback — not token-protected)
```

Google OAuth on the server needs a **Web application** client in Google Cloud, with `AGENTSAM_GOOGLE_CLIENT_ID`, `AGENTSAM_GOOGLE_CLIENT_SECRET`, and the redirect URI `https://<your-host>/api/connectors/gmail/callback` (and `.../googleads/callback`) registered as authorized redirect URIs. `AGENTSAM_PUBLIC_URL` pins the public base URL; otherwise it is derived from the request (including `X-Forwarded-Proto/Host`). The iPhone app completes the flow in its browser and the server stores the refresh token.



## Deploy the server

The server is the same engine behind a token-authenticated API, ready for Railway or a secured host (VPS, home server, Tailscale node).

### Railway

The root `railway.toml` builds `deploy/Dockerfile`, checks `/healthz`, and restarts failed processes. Create the service from the repository root, attach a Railway volume at `/data`, and keep the service at **one replica**. Active missions, event subscribers, and the file store are process-local and do not support horizontal scaling.

Set these variables in Railway:

- `AGENTSAM_TOKEN` — a long random token used by the iPhone app; required by the production container.
- `AGENTSAM_KEY_PROVIDER_ANTHROPIC`, `AGENTSAM_KEY_PROVIDER_OPENAI`, or another provider key — at least one key for server-side missions.
- Optional Maloon integration: `AGENTSAM_MALOON_URL=https://<indigo-host>` and `AGENTSAM_MALOON_TOKEN=<matching-integration-token>`.
- On Indigo's existing Railway service, set the same random token as `AGENTSAM_INTEGRATION_TOKEN` and set `AGENTSAM_BUSINESS_TIMEZONE` to the owner's IANA timezone (for example `America/Chicago`). It defaults to UTC.

Generate a public HTTPS domain in Railway. The container honors Railway's `PORT`; `AGENTSAM_PORT` remains available as an explicit override. Keep backups of the `/data` volume: it contains provider configuration and file-backed keys (written with 0600 permissions), teams, mission history, deliverables, and any Maloon snapshots used as mission context. A restart marks interrupted missions stopped rather than repeating billable model calls automatically.

GreenPT works as an OpenAI-compatible provider with base URL `https://api.greenpt.ai/v1`; `glm-5.3` is the validated default for the Maloon owner workflows. Add it as a custom provider in the iPhone Server tab and save its key there, or use `AGENTSAM_KEY_PROVIDER_GREENPT` with a provider whose ID is `greenpt`.

### Docker (with automatic HTTPS via Caddy)

```bash
cd deploy
export AGENTSAM_DOMAIN=agentsam.example.com
export AGENTSAM_TOKEN=pick-a-long-random-token
docker compose up -d --build
```

DNS `agentsam.example.com` → your host, ports 80/443 open, and Caddy handles TLS. Then in the iPhone app: connect to `https://agentsam.example.com` with the token.

### Bare metal (systemd)

```bash
cd Server && swift build -c release
sudo mkdir -p /opt/agentsam && sudo cp .build/release/AgentSamServer /opt/agentsam/
sudo cp deploy/agentsam.service /etc/systemd/system/
echo 'AGENTSAM_TOKEN=your-long-random-token' | sudo tee /opt/agentsam/agentsam.env
sudo systemctl enable --now agentsam
```

Put your own TLS reverse proxy (Caddy/nginx) in front, or keep it on a tailnet (Tailscale/WireGuard) and reach it at `http://<tailnet-ip>:8080`.

### Server environment

| Variable | Purpose | Default |
|---|---|---|
| `AGENTSAM_TOKEN` | Bearer token for all API calls | ephemeral locally; required in the container |
| `AGENTSAM_REQUIRE_TOKEN` | Set to `1` to refuse startup without `AGENTSAM_TOKEN` | enabled in the container |
| `AGENTSAM_DATA` | Data directory (teams, missions, ledger, keys.json) | `./data`; `/data` in the container |
| `AGENTSAM_PORT` / `PORT` | Listen port / Railway-provided fallback | Vapor default (8080) |
| `AGENTSAM_BIND_ALL` / `AGENTSAM_HOST` | Bind 0.0.0.0 / custom host | loopback; bind all in the container |
| `AGENTSAM_KEY_<PROVIDER>` | e.g. `AGENTSAM_KEY_PROVIDER_ANTHROPIC` — used when no file-backed key is saved for the provider | — |
| `AGENTSAM_MALOON_URL` / `AGENTSAM_MALOON_TOKEN` | Optional Indigo snapshot URL and service token | disabled |
| `AGENTSAM_GOOGLE_CLIENT_ID` / `AGENTSAM_GOOGLE_CLIENT_SECRET` | Google Cloud OAuth client for the Gmail/Google Ads connectors | connectors without Google OAuth |
| `AGENTSAM_PUBLIC_URL` | Public base URL used for Google OAuth redirects (e.g. `https://agentsam.example.com`) | derived from the request |

### API sketch

```
GET    /healthz
GET    /api/info
GET    /api/teams            POST /api/teams
GET    /api/teams/:id        PUT/DELETE /api/teams/:id
GET    /api/providers        POST /api/providers
POST   /api/providers/:id/key        (store a provider key server-side)
POST   /api/providers/:id/test       (test the saved server-side key)
GET    /api/integrations
POST   /api/integrations/maloon/test
GET    /api/connectors       PATCH /api/connectors/:id
POST   /api/connectors/:id/test        POST /api/connectors/:id/disconnect
POST   /api/connectors/cloudflare/token
POST   /api/connectors/googleads/credentials
POST   /api/connectors/:id/authorize
POST   /api/missions         { teamID, objective } or { workflowID, objective } → launches the run
GET    /api/missions         GET /api/missions/:id  POST /api/missions/:id/stop
GET    /api/missions/:id/events?afterSeq=N
GET    /api/missions/:id/deliverables/:name
WS     /api/missions/:id/live       (live RunEvent stream; closes on missionEnd)
```

All `/api/*` routes require `Authorization: Bearer <token>` (the WebSocket also accepts `?token=` for other clients; the iPhone app uses the header).

## iPhone app

1. Enter your server URL + token, then use guided setup to configure a server-side provider, hire a team, and launch.
2. Create and edit teams, hire curated templates, search and filter missions, watch the live agent stage and activity, stop missions, and read deliverables/final reports.
3. The Server tab manages provider configurations and API keys **on the server** for headless runs, including real connection tests.
4. The Server tab also manages **connectors**: connect Cloudflare with a token, set Google Ads developer-token/customer credentials, and run the Google OAuth consent flow for Gmail and Google Ads in the in-app browser. Enable/disable connectors and opt into write actions (send email, DNS edits) per connector.
4. With Maloon configured, New Mission offers four owner workflows: daily operations, quote follow-ups, staffing/dispatch review, and customer/marketing drafts. AgentSam creates the owner team from one configured provider and fetches a fresh Indigo snapshot for each run. Workflows are manual, read-only, and never send or publish drafts.

## Repository layout

```
AgentSam.xcodeproj        Mac + iOS app targets (open in Xcode)
AppMac/                  native macOS app (guided setup, visual builder, war room, BYOK settings)
AppIOS/                  iPhone client (guided setup, remote team editing, live mission view)
AppShared/               shared native design system, team templates, and live mission presentation
AgentSamCore/            shared Swift package — the whole engine
  Models.swift             teams, agents, missions, run events, verification
  LLMClient.swift          OpenAI-compatible chat completions + retries + tool calling
  AnthropicClient.swift    native Anthropic /v1/messages adapter (tool use)
  KeyRing.swift            Keychain (apps) / file+env (server) key storage
  Tools.swift              sandboxed agent file tools
  Connectors.swift         connector framework: config, permissions, tool registry/hub
  GoogleOAuth.swift        Google OAuth2 client + PKCE (SHA-256, base64url) + token cache
  GmailConnector.swift     Gmail search/read/draft/send tools
  GoogleAdsConnector.swift read-only GAQL tools for Google Ads
  CloudflareConnector.swift zones, DNS records, and cache tools
  PromptBuilder.swift      every prompt in one place, output contracts
  MissionEngine.swift      the orchestrator: plan → parallel work → verify → report
  MissionStore.swift       file persistence, JSONL ledger, live event bus
  Parsers.swift            plan parser + verifier line protocol
Server/                   AgentSamServer (Vapor) — REST + WebSocket API
deploy/                   Dockerfile, docker-compose, Caddyfile, systemd unit
mockups/                  ui.html — interactive fun-UI concept (guided setup, team templates, live mission stage)
```

## Languages (English & Spanish)

AgentSam ships localized in **English** and **Spanish** across the whole stack:

- **Apps** — AgentSamMac and AgentSamiOS follow the device's system language automatically. All UI, curated team templates, agent personas (titles and system prompts), mission status labels, and accessibility strings resolve from `AppShared/en.lproj` + `es.lproj` (plus a `Localizable.stringsdict` for plural forms).
- **Engine** — every mission carries an `outputLanguage` (`"es"` or `"en"`, persisted in `mission.json`). The Mac app derives it from the system language; the iPhone app sends its device language with the mission-start request. `PromptBuilder` then emits the coordinator, worker, verifier, and report prompts in that language, so Spanish missions plan, work, and write their deliverables in Spanish. The parser contract tokens (`TASK`, `Agent:`, `Goal:`, `Deliverable:`, `PASS|CONCERN|FAIL`, `VERDICT:`) deliberately stay English so parsing keeps working.
- **Server** — AgentSamServer localizes every API error, OAuth result page, and the Maloon workflow catalog based on the request's `Accept-Language` header (the iPhone app sets it from the device language).

```bash
# Launch the Mac app in Spanish (regardless of system language):
AgentSamMac.app/Contents/MacOS/AgentSamMac -AppleLanguages '(es)'
```

## Security notes

- API keys are stored in the **Keychain** on apps and in `keys.json` (file-protected, 0600 via atomic writes) or env vars on the server — never in the data volume's readable documents.
- Connector credentials follow the same rule: Cloudflare tokens and Google OAuth refresh tokens live in the key store, not in `connectors.json`. Write-capable connector tools (send email, DNS edits) are disabled by default and must be explicitly enabled per connector. Google OAuth authorization state tokens are single-use and expire after 10 minutes.
- The server is read-for-write protected: every `/api/*` route requires the token, with one deliberate exception — the Google OAuth callback (`GET /api/connectors/:id/callback`), which validates a single-use state token and stores only the refresh token it just exchanged.
- Mission workspaces are path-sandboxed (no `..`, no absolute paths, text-only deliverables).
- Maloon snapshots may contain business and customer contact data. They are persisted only in mission records on the protected data volume, are not emitted to the live event stream, and should be included in volume backup/access policies.
- Run behind TLS (Caddy config included) or on a private tailnet. The token is the only door — use a long random one.

## Credits

The coordination architecture follows patterns proven in the CATAHub project: single-source prompt building with strict output contracts, two-tier verification (mechanical + independent agent), append-only event ledgers, cost watermarking, and graceful degradation (fallback plans, fallback handoffs, retry ladders on 429/5xx).
