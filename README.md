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
  conversations/
    <uuid>.json           chat history (the web app's conversations, with any recurring schedule)
    <uuid>/files/         files Ada wrote directly in chat (see below)
  workspace/archive-settings.json  each owner's archive retention (null = never delete)
  projects/<owner>/<project>/ files shared by that owner's chats and missions in a project
  host-grants.json         owner-scoped, admin-managed server folder grants
  access-audit.jsonl       project, host, terminal, and approval activity
  action-requests/         expiring, one-use connector-write and file-delete approvals
  workspace/knowledge/<user>/
    state.json            discovery state, snapshot fingerprint, and refresh timestamps
    capabilities.md       providers, direct tools, teams, and permissions
    connections.md        connector state and active tools (never credentials or content)
    projects.md           the user's project names, conversation counts, and activity
```

## Ada's chat workspace

In a direct chat, Ada can do more than answer. She has a private workspace for the conversation:

- `chat_write_file` / `chat_read_file` / `chat_list_files` — files live under `conversations/<uuid>/files/`, shown in the chat as chips that open the preview and files sidebar. Ada's router and direct-response prompts receive the project, schedule state, and a recursive file manifest with sizes; contents remain on demand. `chat_read_file` supports `start_line` for continued reads. When Ada finishes a reply that wrote files, the sidebar opens them itself: an HTML page goes straight to the live preview, anything else to the file list. (It opens once per reply, and only for replies you watched finish — not when reopening old chats.) Paths are jailed to that folder (no escaping the workspace with `..` or absolute paths) and reads are limited to text formats, the same allowlist as mission deliverables.
- `mission_list_files` / `mission_read_file` — inspect text deliverables from missions already linked to the conversation. The engine authorizes only those referenced mission IDs; these tools cannot read arbitrary mission history.
- `run_program` — runs JavaScript (Node), Python, or C (compiled with gcc) in a throwaway sandbox under the conversation's folder. Runs have a 20-second wall-clock timeout, capped output, and a scrubbed environment so no server secrets reach the child. The sandbox is deleted after each run; the toolchains come from the Docker image. There is a combined limit of 4 program and terminal executions per reply.
- `project_list_files` / `project_read_file` / `project_write_file` — use a workspace shared by the signed-in owner's conversations in the same project, rather than one chat's private files. The upload button accepts non-empty files up to 5 MB; text previews and binary downloads are available in the files sidebar. Ada's text writes are limited to 200 KB. `chat_patch_file` / `project_patch_file` make unique text replacements, and `chat_move_file` / `project_move_file` rename without overwriting. Deleting a single file requires a one-use approval card. Uploads reject secret-like names, paths cannot escape the project, and project data is isolated by owner and project name.
- `run_terminal` / `project_terminal` — run shell commands in a persistent session rooted at the conversation or shared project workspace. Files and the working directory persist across calls, but exported environment variables and long-running processes do not. Each command has a 30-second timeout, a 20,000-byte command limit, capped output, and a scrubbed environment. Writes are confined to the selected workspace; there is no host shell. macOS uses `sandbox-exec`, Linux uses `bubblewrap` (installed in the Docker image). If the OS sandbox is unavailable, no command runs.
- `host_list_grants` / `host_list_files` / `host_read_file` / `host_write_file` — inspect and edit text files in a specific **server-side** folder granted by an admin in Settings. Grants and their audit entries are owner-scoped. Read/write grants are separate from read-only grants, writes are limited to 200 KB, and revoking a grant leaves existing files unchanged. Secret-like filenames, symlink escapes, the filesystem root, the whole home folder, and the AgentSam data folder are refused.
- `chat_schedule_run` / `chat_schedule_cancel` — set or clear a **recurring schedule** for the conversation: a prompt the server sends automatically on a timer (every 15 or 30 minutes, hourly, every 6 or 12 hours, or daily). When a schedule is due, the scheduler fires the prompt into the conversation as a user message flagged `scheduled`, Ada runs it with her normal tools, and the reply lands in the chat labeled as a scheduled run — so "update this every hour without me asking" is real platform behavior, not something Ada has to be nudged for. The user can also set or stop a schedule from the clock button in the chat header (`PUT`/`DELETE` `/api/conversations/:id/schedule`). Schedules persist with the conversation; overdue schedules fire once on restart and then resume their interval.

When a task is Ada's to do herself but is a real job — several steps, deliverables to produce, code to verify — she routes it as **SOLO** instead of answering inline. A SOLO run is a full mission on the **Ada (solo)** team, her permanent one-agent roster: Ada as coordinator and only worker, with the mission workspace, the full step budget, `run_program`, and a final report. Readable files from the conversation workspace are copied into every SOLO or specialist mission before launch, so follow-up work starts from the actual files. Shared project text files are also copied under `project/`; after a linked mission completes, its readable deliverables are synchronized back into the same owner's shared project. The run appears in chat with the usual mission chips ("Watch work" console, deliverables, preview) and in mission history like any other run. Ada never routes specialist work to the solo team; it exists only for self-directed work.

Connector reads remain available directly. Connector write tools (sending or drafting mail, committing to GitHub, DNS changes, pausing campaigns) follow the toggles on the Connectors page and require an approval card showing the exact operation and arguments, in direct chat and linked missions as well as for teams; nothing runs before approval. The same auto-open applies to a finished SOLO or team run: if the run produced an HTML page, the preview opens on it when the run completes.

**Photos.** The camera button in the composer attaches up to 4 photos to a message: on a phone it offers *Take a photo* or *Photo library*; on a computer it opens the file picker, and pasted or dropped images attach too. The browser shrinks each photo to 1568 px on the long edge as a JPEG (which also strips metadata such as GPS location) and shows a removable preview before sending. Photos upload to `POST /api/conversations/:id/photos`, are stored beside the conversation under `conversations/<uuid>/photos/` (never inside the conversation JSON or the chat workspace), and the message refers to them by id. Only Ada's direct reply looks at photos: they go to the model as Anthropic `image` blocks or OpenAI-style `image_url` parts, along with photos from the last few turns (at most 4) so follow-up questions still work. Routing, SOLO and team missions, and consolidation get a note that photos were attached. When Ada's model is known to be text-only (for example DeepSeek, Llama 3, or gpt-oss), or the provider rejects the images, Ada answers without them and says in one sentence that a vision model can be chosen in Settings.

**Archiving chats.** Hover a chat in the sidebar and press its × to archive it (the title fades out under the button); on a phone, the open chat shows its ×, and swiping left on any other chat reveals one. The first archive asks how long to keep archived chats: 7, 30, or 90 days, a year, or never delete. Archived chats leave the sidebar and stop their schedule; **Archived chats** under the project list shows them with their deletion date, opens or restores them, and changes the retention. Sending a message in an archived chat restores it. Once an archive is older than the retention, the scheduler deletes the chat with its private folder (photos and chat files); project files and missions are kept.

**Voice replies.** Messages sent from voice mode are flagged `spoken`, and every reply prompt for them (direct, consolidation, and the clarify question) gets a voice style: lead with the answer, two to four short sentences, no Markdown, lists, links, or file paths. A short spoken question (25 words or fewer, no photo, no work words like *build*, *send*, or *schedule*, and not an answer to a question Ada just asked) skips the routing call and goes straight to Ada's direct reply, so speech starts sooner. Anything else is routed as usual. Typed replies follow the direct prompt's length rules: answer first, as short as the request allows, structure only when it helps.

Workspace memory is compacted separately for each signed-in user and is never shared across accounts. Installations using the legacy shared server token retain the original shared-token memory files. Direct-chat, routing, consolidation, identity, and memory prompts use the same versioned `prompts.json` store as mission prompts (an untouched version-1 seed in that file follows the built-in prompt of the running release; a prompt edited through the API keeps the edit); direct tool loops also compact oversized turns and retry provider context overflows.

Workspace knowledge is discovered on each user's first launch and maintained as three per-user Markdown documents: `capabilities.md`, `connections.md`, and `projects.md`. Open **Knowledge** in any project's sidebar to inspect, refresh, or export them. Discovery reads the actual provider, team, tool, connector, and project registries without a model call, without testing external services, and without reading connector content. Credentials and private agent prompts are excluded. Ada receives a compact version in direct chats and mission handoffs. A background scheduler checks for changes every minute and reconciles documents at least daily; unchanged snapshots are not rewritten. Users can also force a refresh with `POST /api/workspace/knowledge/refresh`.

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

The persistent terminal uses macOS's built-in `sandbox-exec` or Linux `bubblewrap`. The Docker image installs `bubblewrap`; install it separately on other Linux hosts. Without a supported OS sandbox, terminal calls report that no command ran.

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
POST   /api/connectors/github/token
POST   /api/connectors/googleads/credentials
POST   /api/connectors/:id/authorize
POST   /api/missions         { teamID, objective } or { workflowID, objective } → launches the run
GET    /api/missions         GET /api/missions/:id  POST /api/missions/:id/stop
GET    /api/missions/:id/events?afterSeq=N
GET    /api/missions/:id/deliverables/:name
GET    /api/conversations/:id/files             (Ada's chat workspace)
GET    /api/conversations/:id/files/:name       (one chat workspace file, text only)
GET    /api/conversations/:id/project/files     (shared project file list)
GET    /api/conversations/:id/project/files/:name (one shared project text file)
POST   /api/conversations/:id/project/uploads   (raw bytes; X-AgentSam-Path; at most 5 MB)
GET    /api/conversations/:id/project/download/:name (shared project file download)
GET    /api/conversations/:id/actions           (owner-scoped approval requests)
POST   /api/conversations/:id/actions/:actionID { approve } (one use; expires after 15 minutes)
GET    /api/access/audit                       (owner-scoped recent access activity)
GET    /api/access/host-grants                 POST /api/access/host-grants (admin)
DELETE /api/access/host-grants/:grantID         (admin; revoke without deleting files)
GET    /api/workspace/knowledge                 (discover or read maintained workspace docs)
POST   /api/workspace/knowledge/refresh         (force a workspace knowledge refresh)
GET    /api/workspace/knowledge/:id/export      (capabilities, connections, or projects Markdown)
PUT    /api/conversations/:id/schedule          (set a recurring schedule)
DELETE /api/conversations/:id/schedule          (cancel it)
GET    /api/conversations?archived=1            (archived chats, newest archive first)
POST   /api/conversations/:id/archive           DELETE /api/conversations/:id/archive (restore)
GET    /api/workspace/archive                   PUT /api/workspace/archive { retentionDays: 7|30|90|365|null }
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

All other `/api/*` routes require either `Authorization: Bearer <AGENTSAM_TOKEN>` (the WebSocket also accepts `?token=`) or a signed-in session cookie. Cookie-authenticated writes must send `X-AgentSam-Request: 1`. Provider changes, key storage, connection tests, host-folder grants and mission deletion are admin-only. Project files, approvals and access-audit entries are scoped to their owner; admins manage only their own owner's host grants. Client-visible API messages follow the request's `Accept-Language` header (`en` | `es`).

## Connectors

Connectors give Ada and mission agents tools beyond their own files. Set them up on the **Connectors** page (admins only). Anything that sends or changes something is off until you switch it on.

Every connector write also needs a person's explicit, one-use approval, in direct chat as well as in a linked mission. The approval card shows the tool and exact arguments, expires after 15 minutes, and cannot be approved twice. Denial and expiry perform no external action; a refused or failed operation is not marked completed. The connector must remain enabled and configured, its relevant write permission must be on, and mission team scopes still apply. Read-only connector tools do not require approval.

| Connector | Agent tools | Off until you switch it on |
|---|---|---|
| **Gmail** | `gmail_search`, `gmail_read` | `gmail_draft`, `gmail_send` |
| **Google Ads** | `googleads_accounts`, `googleads_campaigns`, `googleads_query` (GAQL SELECT) | `googleads_set_campaign_status` (pause or enable one campaign) |
| **GitHub** | `github_repos`, `github_read` (files and directories), `github_search`, `github_issues`, `github_issue` | `github_write_file` (commit to an existing non-default branch), `github_comment` |
| **Web** | `web_fetch` (public pages as text); `web_search` once a Brave Search key is saved | none |
| **Cloudflare** | `cloudflare_zones`, `cloudflare_dns_list` | `cloudflare_dns_create/update/delete`, `cloudflare_purge_cache` |

Agents treat everything a connector returns as untrusted data. `web_fetch` refuses localhost, private networks, cloud metadata addresses and internal names, including after redirects.

### Google (Gmail and Google Ads)

1. In Google Cloud, create a project and enable the Gmail API and the Google Ads API.
2. OAuth consent screen: External, and set it to **In production** (it can stay unverified for your own account). In Testing mode Google expires the sign-in every 7 days.
3. Credentials: create a **Web application** client with these redirect URIs: `https://<your-host>/api/connectors/gmail/callback` and `https://<your-host>/api/connectors/googleads/callback`.
4. In Railway, set `AGENTSAM_GOOGLE_CLIENT_ID`, `AGENTSAM_GOOGLE_CLIENT_SECRET` and `AGENTSAM_PUBLIC_URL=https://<your-host>`.
5. On the Connectors page, choose **Connect with Google**. For Gmail, switch on drafts or sending first; if you switch them on later, connect again so Google grants the extra permission.
6. Google Ads access comes from your Google Cloud project: enabling the Google Ads API gives Test access, and the Google Ads API page in the Cloud Console is where you apply for Explorer access or higher to read live accounts. No developer token is needed (one can still be saved for older setups). If you use a manager account, save its customer ID. The connector calls Ads API `v25`; set `AGENTSAM_GOOGLE_ADS_API_VERSION` when Google retires it.

### Web search

Get a key from the [Brave Search API](https://brave.com/search/api/) and save it on the Connectors page. Without a key, agents can still read pages with `web_fetch`.

### API

```
GET    /api/connectors                        (status for all connectors)
PATCH  /api/connectors/:id                    { enabled, permissions: { sendEmail, createDraft, dnsWrite, githubWrite, adsWrite } }
POST   /api/connectors/:id/test
POST   /api/connectors/:id/disconnect
POST   /api/connectors/web/key                { key }  (Brave Search, verified before storing)
POST   /api/connectors/cloudflare/token       { key }  (verified before storing)
POST   /api/connectors/github/token           { key }  (verified before storing)
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
  CoordinatorChat.swift    the legacy team-coordinator chat and its tools
  ConversationEngine.swift Ada's routing, direct tools, mission handoffs, and memory
  ConversationPrompts.swift shared Ada context and versioned prompt rendering
  AgentAccess.swift        owner-scoped host grants, access audit, and one-use approvals
  ExtendedWorkspaceTools.swift shared project files, scoped host files, and terminal tools
  WorkspaceTerminal.swift  persistent macOS/Linux-sandboxed terminal sessions
  WorkspaceKnowledge.swift first-launch discovery, maintained docs, and refresh scheduler
  Speech.swift             speech-to-text and text-to-speech providers
  KeyRing.swift            file + env key storage
  Tools.swift              sandboxed agent file tools
  Connectors.swift, Gmail*, GoogleAds*, Web*, Cloudflare*   connectors (outside tools for agents)
  PromptBuilder.swift      mission prompt rendering and typed context
  PromptStore.swift        versioned Ada and mission prompt templates
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
- Connector credentials follow the same rule: Cloudflare and GitHub tokens and Google OAuth refresh tokens live in the key store, not in `connectors.json`. Write-capable connector tools (send email, DNS edits) are disabled by default and must be explicitly enabled per connector. Google OAuth authorization state tokens are single-use and expire after 10 minutes.
- The server is read-for-write protected: every `/api/*` route requires the token, with one deliberate exception — the Google OAuth callback (`GET /api/connectors/:id/callback`), which validates a single-use state token and stores only the refresh token it just exchanged.
- Mission workspaces are path-sandboxed (no `..`, no absolute paths, text-only deliverables).
- Maloon snapshots may contain business and customer contact data. They are persisted only in mission records on the protected data volume, are not emitted to the live event stream, and should be included in volume backup/access policies.
- Run behind TLS (Railway provides it). The token is the only door — use a long random one.

## Credits

The coordination architecture follows patterns proven in the CATAHub project: single-source prompt building with strict output contracts, two-tier verification (mechanical + independent agent), append-only event ledgers, cost watermarking, and graceful degradation (fallback plans, fallback handoffs, retry ladders on 429/5xx).
