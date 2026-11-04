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

## Deploy the server

The server is the same engine behind a token-authenticated API, ready for a secured host (VPS, home server, Tailscale node).

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
| `AGENTSAM_TOKEN` | Bearer token for all API calls (required in production) | ephemeral, printed at startup |
| `AGENTSAM_DATA` | Data directory (teams, missions, ledger, keys.json) | `./data` |
| `AGENTSAM_PORT` | Listen port | Vapor default (8080) |
| `AGENTSAM_BIND_ALL` / `AGENTSAM_HOST` | Bind 0.0.0.0 / custom host | loopback |
| `AGENTSAM_KEY_<PROVIDER>` | e.g. `AGENTSAM_KEY_PROVIDER_ANTHROPIC` — env keys beat keys.json | — |
| `AGENTSAM_WEB_DIR` | Folder holding the built web app (`Web/dist`) | `./Public` (`/app/Public` in Docker) |
| `AGENTSAM_INSECURE_COOKIES` | Set only for local plain-HTTP development; drops the `Secure` cookie flag | unset |

## Web app

The server also serves a browser UI at `/` (built from `Web/`, a Vite + React + TypeScript app, into the Docker image).

- **First run:** open the server URL and create the admin account. This step asks for `AGENTSAM_TOKEN` to prove you own the server, and only works while no accounts exist.
- **People:** admins invite others from the People page. An invite is a one-time link that expires in 7 days. Roles: **admin** (manage people, provider configs and keys, delete missions) and **member** (teams and missions). Everyone shares the same teams and missions.
- **Sessions:** sign-in sets an `HttpOnly`, `Secure`, `SameSite=Strict` cookie (14 days). Passwords are bcrypt-hashed in `accounts.json`; sessions are stored hashed in `sessions.json` (both 0600). Repeated failed sign-ins from one address are locked out for 15 minutes.
- The iPhone and Mac apps keep using `AGENTSAM_TOKEN` as before; it acts as an admin.

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
POST   /api/missions         { teamID, objective }  → launches the run
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
GET    /api/users    PATCH/DELETE /api/users/:id                    (admin)
GET    /api/invites  POST /api/invites  DELETE /api/invites/:id     (admin)
```

All other `/api/*` routes require either `Authorization: Bearer <AGENTSAM_TOKEN>` (the WebSocket also accepts `?token=`) or a signed-in session cookie. Cookie-authenticated writes must send `X-AgentSam-Request: 1`. Provider changes, key storage, connection tests and mission deletion are admin-only.

## iPhone app

1. Enter your server URL + token, then use guided setup to configure a server-side provider, hire a team, and launch.
2. Create and edit teams, hire curated templates, search and filter missions, watch the live agent stage and activity, stop missions, and read deliverables/final reports.
3. The Server tab manages provider configurations and API keys **on the server** for headless runs, including real connection tests.

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
  PromptBuilder.swift      every prompt in one place, output contracts
  MissionEngine.swift      the orchestrator: plan → parallel work → verify → report
  MissionStore.swift       file persistence, JSONL ledger, live event bus
  Parsers.swift            plan parser + verifier line protocol
Server/                   AgentSamServer (Vapor) — REST + WebSocket API
deploy/                   Dockerfile, docker-compose, Caddyfile, systemd unit
mockups/                  ui.html — interactive fun-UI concept (guided setup, team templates, live mission stage)
```

## Security notes

- API keys are stored in the **Keychain** on apps and in `keys.json` (file-protected, 0600 via atomic writes) or env vars on the server — never in the data volume's readable documents.
- The server is read-for-write protected: every route requires the token; mission workspaces are path-sandboxed (no `..`, no absolute paths, text-only deliverables).
- Run behind TLS (Caddy config included) or on a private tailnet. The token is the only door — use a long random one.

## Credits

The coordination architecture follows patterns proven in the CATAHub project: single-source prompt building with strict output contracts, two-tier verification (mechanical + independent agent), append-only event ledgers, cost watermarking, and graceful degradation (fallback plans, fallback handoffs, retry ladders on 429/5xx).
