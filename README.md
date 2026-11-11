# AgentSam

Hire a team of AI agents. Bring your own API keys. No subscription lock-in.

AgentSam is one server that runs the agent engine and serves a web app. Use it in any browser; on a phone, add it to the home screen and it opens like an app.

```
 Browser (desktop, or phone as an installed web app)
        │  HTTPS + WebSocket
 ┌──────▼─────────────────────────────────────────────┐
 │ Railway: one service, one replica, /data volume     │
 │   Web UI (Web/)  →  API (Server/)  →  engine        │
 │                                       (AgentSamCore)│
 └──────────┬──────────────────────────────┬───────────┘
            │ model calls                  │ speech (optional)
   Anthropic · OpenAI · GreenPT ·      Kokoro or any OpenAI-style
   any OpenAI-compatible endpoint      /audio/speech endpoint
```

The Mac and iPhone apps were retired to keep one product surface. They live in git history at commit `5a44abe` (`git checkout 5a44abe -- AppMac AppIOS AppShared AgentSam.xcodeproj` brings them back).

## How a mission runs

1. **Plan** — the team's coordinator turns your objective into concrete tasks, each assigned to a worker by name with a deliverable filename (strict `TASK / Agent / Goal / Deliverable` contract, retried and gracefully degraded).
2. **Work** — workers run **in parallel** (TaskGroup, up to 4 at a time). Each worker has sandboxed file tools (`write_file`, `read_file`, `list_dir`, `finish`) in the mission workspace, a step cap, and a handoff summary.
3. **Verify** — mechanical checks (files exist, claims match disk) plus an independent verifier agent with a read-only toolset and a strict line-protocol verdict (`PASS|CONCERN|FAIL … VERDICT:`).
4. **Report** — the coordinator merges handoffs into a final markdown report saved as `final-report.md`.

Every turn, tool call, deliverable, finding, and cost is a `RunEvent`, appended to an append-only `events.jsonl` ledger, streamed live to the web app, and persisted for review.

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

## Deploy on Railway

The root `railway.toml` builds `deploy/Dockerfile`, checks `/healthz`, and restarts failed processes. Create the service from the repository root, attach a Railway volume at `/data`, and keep the service at **one replica**. Active missions, event subscribers, and the file store are process-local and do not support horizontal scaling.

Set these variables in Railway:

- `AGENTSAM_TOKEN` — a long random token used by scripts and to create the first account; required by the production container.
- `AGENTSAM_KEY_PROVIDER_ANTHROPIC`, `AGENTSAM_KEY_PROVIDER_OPENAI`, or another provider key — at least one key for server-side missions.
- Optional Maloon integration: `AGENTSAM_MALOON_URL=https://<indigo-host>` and `AGENTSAM_MALOON_TOKEN=<matching-integration-token>`. The web app has no screen for its owner workflows yet; start one with `POST /api/missions` and a `workflowID`.
- On Indigo's existing Railway service, set the same random token as `AGENTSAM_INTEGRATION_TOKEN` and set `AGENTSAM_BUSINESS_TIMEZONE` to the owner's IANA timezone (for example `America/Chicago`). It defaults to UTC.

Generate a public HTTPS domain in Railway. The container honors Railway's `PORT`; `AGENTSAM_PORT` remains available as an explicit override. Keep backups of the `/data` volume: it contains provider configuration and file-backed keys (written with 0600 permissions), teams, mission history, deliverables, and any Maloon snapshots used as mission context. A restart marks interrupted missions stopped rather than repeating billable model calls automatically.

GreenPT works as an OpenAI-compatible provider with base URL `https://api.greenpt.ai/v1`; `glm-5.3` is the validated default for the Maloon owner workflows. Add it as a provider in the web app's Settings and save its key there, or use `AGENTSAM_KEY_PROVIDER_GREENPT` with a provider whose ID is `greenpt`.

## Server environment

| Variable | Purpose | Default |
|---|---|---|
| `AGENTSAM_TOKEN` | Bearer token for scripts and first-time setup; acts as an admin | ephemeral locally; required in the container |
| `AGENTSAM_REQUIRE_TOKEN` | Set to `1` to refuse startup without `AGENTSAM_TOKEN` | enabled in the container |
| `AGENTSAM_DATA` | Data directory (teams, missions, ledger, keys.json) | `./data`; `/data` in the container |
| `AGENTSAM_PORT` / `PORT` | Listen port / Railway-provided fallback | Vapor default (8080) |
| `AGENTSAM_BIND_ALL` / `AGENTSAM_HOST` | Bind 0.0.0.0 / custom host | loopback; bind all in the container |
| `AGENTSAM_KEY_<PROVIDER>` | e.g. `AGENTSAM_KEY_PROVIDER_ANTHROPIC` — used when no file-backed key is saved for the provider | — |
| `AGENTSAM_MALOON_URL` / `AGENTSAM_MALOON_TOKEN` | Optional Indigo snapshot URL and service token | disabled |
| `AGENTSAM_GOOGLE_CLIENT_ID` / `AGENTSAM_GOOGLE_CLIENT_SECRET` | Google Cloud OAuth client for the Gmail/Google Ads connectors | connectors without Google OAuth |
| `AGENTSAM_GOOGLE_ADS_API_VERSION` | Google Ads API version for the Ads connector | `v25` |
| `AGENTSAM_PUBLIC_URL` | Public base URL used for Google OAuth redirects (e.g. `https://agentsam.example.com`) | derived from the request |
| `AGENTSAM_WEB_DIR` | Folder holding the built web app (`Web/dist`) | `./Public` (`/app/Public` in Docker) |
| `AGENTSAM_INSECURE_COOKIES` | Set only for local plain-HTTP development; drops the `Secure` cookie flag | unset |

## Web app

The server also serves a browser UI at `/` (built from `Web/`, a Vite + React + TypeScript app, into the Docker image).

- **First run:** open the server URL and create the admin account. This step asks for `AGENTSAM_TOKEN` to prove you own the server, and only works while no accounts exist.
- **People:** admins invite others from the People page. An invite is a one-time link that expires in 7 days. Roles: **admin** (manage people, provider configs and keys, delete missions) and **member** (teams and missions). Everyone shares the same teams and missions.
- **Sessions:** sign-in sets an `HttpOnly`, `Secure`, `SameSite=Strict` cookie (14 days). Passwords are bcrypt-hashed in `accounts.json`; sessions are stored hashed in `sessions.json` (both 0600). Repeated failed sign-ins from one address are locked out for 15 minutes.
- **App tokens:** each user can create personal tokens (`asam_…`) on their Account page and use one in place of `AGENTSAM_TOKEN` (for example in a script), so it acts as that user with their role. Tokens are stored hashed and can be revoked.
- `AGENTSAM_TOKEN` keeps working for scripts and acts as an admin. Keep it private; share invite links and app tokens instead.

Local development:

```bash
cd Server && AGENTSAM_TOKEN=dev AGENTSAM_INSECURE_COOKIES=1 swift run   # API on :8080
cd Web && npm install && npm run dev                                     # UI on :5173, proxies /api
```

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

Accounts (web app):

```
GET    /api/auth/status              (public: { needsSetup })
POST   /api/auth/setup               (public, once: first admin; needs AGENTSAM_TOKEN)
POST   /api/auth/login | logout      (public)
GET    /api/auth/invite/:secret      POST /api/auth/accept-invite   (public)
GET    /api/auth/me                  POST /api/auth/password
GET    /api/auth/tokens  POST /api/auth/tokens  DELETE /api/auth/tokens/:id   (personal app tokens)
GET    /api/templates    POST /api/templates/:id/hire
DELETE /api/providers/:id  DELETE /api/providers/:id/key                     (admin)
GET    /api/users    PATCH/DELETE /api/users/:id                    (admin)
GET    /api/invites  POST /api/invites  DELETE /api/invites/:id     (admin)
```

All other `/api/*` routes require either `Authorization: Bearer <AGENTSAM_TOKEN>` (the WebSocket also accepts `?token=`) or a signed-in session cookie. Cookie-authenticated writes must send `X-AgentSam-Request: 1`. Provider changes, key storage, connection tests and mission deletion are admin-only. Client-visible API messages follow the request's `Accept-Language` header (`en` | `es`).

## Connectors

Connectors give mission agents tools beyond their own files. Set them up on the **Connectors** page (admins only). Anything that sends or changes something is off until you switch it on.

| Connector | Agent tools | Off until you switch it on |
|---|---|---|
| **Gmail** | `gmail_search`, `gmail_read` | `gmail_draft`, `gmail_send` |
| **Google Ads** | `googleads_accounts`, `googleads_campaigns`, `googleads_query` (GAQL SELECT) | none, read-only |
| **Web** | `web_fetch` (public pages as text); `web_search` once a Brave Search key is saved | none |
| **Cloudflare** | `cloudflare_zones`, `cloudflare_dns_list` | `cloudflare_dns_create/update/delete`, `cloudflare_purge_cache` |

Agents treat everything a connector returns as untrusted data. `web_fetch` refuses localhost, private networks, cloud metadata addresses and internal names, including after redirects.

### Google (Gmail and Google Ads)

1. In Google Cloud, create a project and enable the Gmail API and the Google Ads API.
2. OAuth consent screen: External, and set it to **In production** (it can stay unverified for your own account). In Testing mode Google expires the sign-in every 7 days.
3. Credentials: create a **Web application** client with these redirect URIs: `https://<your-host>/api/connectors/gmail/callback` and `https://<your-host>/api/connectors/googleads/callback`.
4. In Railway, set `AGENTSAM_GOOGLE_CLIENT_ID`, `AGENTSAM_GOOGLE_CLIENT_SECRET` and `AGENTSAM_PUBLIC_URL=https://<your-host>`.
5. On the Connectors page, choose **Connect with Google**. For Gmail, switch on drafts or sending first; if you switch them on later, connect again so Google grants the extra permission.
6. Google Ads also needs a developer token (Ads API Center) and, if you use a manager account, its customer ID. The connector calls Ads API `v25`; set `AGENTSAM_GOOGLE_ADS_API_VERSION` when Google retires it.

### Web search

Get a key from the [Brave Search API](https://brave.com/search/api/) and save it on the Connectors page. Without a key, agents can still read pages with `web_fetch`.

### API

```
GET    /api/connectors                        (status for all connectors)
PATCH  /api/connectors/:id                    { enabled, permissions }
POST   /api/connectors/:id/test
POST   /api/connectors/:id/disconnect
POST   /api/connectors/web/key                { key }  (Brave Search, verified before storing)
POST   /api/connectors/cloudflare/token       { key }  (verified before storing)
POST   /api/connectors/googleads/credentials  { developerToken, customerId }
POST   /api/connectors/:id/authorize          → { url } for the Google consent flow
GET    /api/connectors/:id/callback           (Google's OAuth callback; returns to /connectors)
```

## Repository layout

```
AgentSamCore/            the engine (Swift package)
  Models.swift             teams, agents, missions, run events, verification
  LLMClient.swift          OpenAI-compatible chat completions + retries + tool calling
  AnthropicClient.swift    native Anthropic /v1/messages adapter (tool use)
  CoordinatorChat.swift    the coordinator chat and its tools
  Speech.swift             speech-to-text and text-to-speech providers
  KeyRing.swift            file + env key storage
  Tools.swift              sandboxed agent file tools
  Connectors.swift, Gmail*, GoogleAds*, Web*, Cloudflare*   connectors (outside tools for agents)
  PromptBuilder.swift      every prompt in one place, output contracts
  MissionEngine.swift      the orchestrator: plan → parallel work → verify → report
  MissionStore.swift       file persistence, JSONL ledger, live event bus
  Parsers.swift            plan parser + verifier line protocol
Server/                   AgentSamServer (Vapor): REST + WebSocket API, serves the web app
Web/                      the web app (Vite + React + TypeScript)
deploy/Dockerfile         the one image Railway builds (web build + server)
design/, mockups/         icon sources and the original UI concept
```

## Languages

The web app is in English. Each mission still carries an `outputLanguage` (`en` or `es`), and `PromptBuilder` writes the coordinator, worker, verifier and report prompts in that language, so Spanish missions plan, work and write deliverables in Spanish.

## Security notes

- API keys are stored in `keys.json` (file-protected, 0600 via atomic writes) or env vars on the server — never in the data volume's readable documents.
- Connector credentials follow the same rule: Cloudflare tokens and Google OAuth refresh tokens live in the key store, not in `connectors.json`. Write-capable connector tools (send email, DNS edits) are disabled by default and must be explicitly enabled per connector. Google OAuth authorization state tokens are single-use and expire after 10 minutes.
- The server is read-for-write protected: every `/api/*` route requires the token, with one deliberate exception — the Google OAuth callback (`GET /api/connectors/:id/callback`), which validates a single-use state token and stores only the refresh token it just exchanged.
- Mission workspaces are path-sandboxed (no `..`, no absolute paths, text-only deliverables).
- Maloon snapshots may contain business and customer contact data. They are persisted only in mission records on the protected data volume, are not emitted to the live event stream, and should be included in volume backup/access policies.
- Run behind TLS (Railway provides it). The token is the only door — use a long random one.

## Credits

The coordination architecture follows patterns proven in the CATAHub project: single-source prompt building with strict output contracts, two-tier verification (mechanical + independent agent), append-only event ledgers, cost watermarking, and graceful degradation (fallback plans, fallback handoffs, retry ladders on 429/5xx).
