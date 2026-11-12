# Multi, Separated-Account Creation — Architecture & Controls

Status: implemented in the Vapor server and web admin UI. This document records
the delivered architecture, API contract, and separation invariants. Accounts
still share the existing teams and missions; this is identity separation, not
tenant isolation.

## 1. Context: what exists today

Server (Vapor, `Server/Sources/AgentSamServer/`):

- `AccountStore` (actor) persists users, invites, and API tokens to
  `<data>/accounts.json` (mode 0600, atomic writes). A user is
  `email / name / role (admin|member) / passwordHash (bcrypt-12) / disabled`.
- Two creation paths only: first-admin `POST /api/auth/setup` (gated by
  `AGENTSAM_TOKEN`) and single-invite `POST /api/auth/invites` (admin-only,
  one-time secret link in the URL fragment, 7-day expiry).
- Auth: `AuthMiddleware` accepts the shared server token, personal `asam_`
  API tokens, or a session cookie. Cookie writes require the
  `X-AgentSam-Request` CSRF header. `LoginThrottle` locks a client IP after
  10 failures / 15 min.
- All users share one tenant: the same teams and missions.

Web (`Web/src/`):

- Admin surface is `pages/PeoplePage.tsx`: invite form, members table,
  pending-invites table. Thin same-origin `api()` wrapper in `api/client.ts`.
- The Mac/iOS apps are retired; the web app is the only client.

## 2. Goals

- An admin can create **many accounts at once** (a *batch*), with per-account
  status, retry, and cancellation, instead of sending invites one at a time.
- Every created account is **identity-separated**: nothing about one account
  lets an observer (another user, a log reader, a member listing) link it to
  its siblings in the same batch.
- Controls are a **backend API** plus an **admin UI in the web app**. No
  native-app work.
- Additive: the existing setup/login/invite flows keep working unchanged.

Non-goals (explicitly out of scope here):

- Tenant/workspace data isolation (separate mission stores per account).
- Infrastructure separation (proxies, browser profiles) — irrelevant for
  accounts on our own server.
- Self-service sign-up. Creation remains admin-driven.

## 3. Identity-separation invariants

These are the rules every implementation must uphold. "Linked" means an
observer could infer two accounts were created together.

1. **Emails are not enumerable patterns.** Local-parts are random
   (`k7x2.mercer@…`), never counters (`user001@…`) or batch-derived strings.
   The batch picks from a configured set of domains so accounts don't all
   share one domain.
2. **Credentials are independent.** Each account gets its own CSPRNG password
   (or its own invite secret). Nothing is reused or derived from a batch seed.
3. **Names are decorrelated.** Display names come from a built-in name pool
   drawn without replacement within a batch; no numbering.
4. **Timestamps are jittered.** Items are created on a paced schedule with
   random jitter (default: 30–120 s between items, configurable), so
   `createdAt` values do not cluster.
5. **Members can't see batch structure.** `GET /api/users` already returns all
   users to admins only; provisioning endpoints are admin-only and member
   surfaces never expose batch IDs or provisioning provenance.
6. **One account, one failure domain.** A failed item does not roll back or
   block siblings, and its error is stored on the item, not the batch.

## 4. Architecture

### 4.1 New server module — `Provisioning.swift` (new file)

Kept in its own file so agents editing `Accounts.swift`/`Auth.swift` for other
account work don't conflict. It composes the existing `AccountStore` rather
than modifying it, **except** for the two extension points in §4.4.

```
actor ProvisioningStore          // <data>/provisioning.json, 0600, via SecureFile
actor ProvisioningRunner         // paces and executes one batch at a time
struct IdentityGenerator         // emails, names, passwords (testable, pure)
```

Persistence is a **separate file** (`provisioning.json`) so `accounts.json`
stays owned by `AccountStore` and its write path is untouched.

### 4.2 Data model

```swift
struct ProvisioningBatch: Codable, Identifiable {
    var id: UUID
    var createdBy: UUID?            // nil when created via server token
    var createdAt: Date
    var spec: BatchSpec
    var status: BatchStatus         // queued | running | paused | done | cancelled
    var items: [ProvisioningItem]
}

struct BatchSpec: Codable {
    var count: Int                  // 1...maxBatchSize
    var role: UserRole              // default .member
    var domains: [String]           // pool; random choice per item
    var delivery: Delivery          // .inviteLinks | .directPasswords
    var paceSeconds: ClosedRange<Double>  // default 30...120
    var expiresInDays: Int?         // invite lifetime override
}

enum Delivery: Codable { case inviteLinks, directPasswords }

struct ProvisioningItem: Codable, Identifiable {
    var id: UUID
    var state: ItemState            // pending | creating | done | failed | cancelled
    var email: String?              // assigned when creation starts, not before
    var userID: UUID?
    var attemptCount: Int
    var lastError: String?
    var completedAt: Date?
}
```

`provisioning.json` contains **no plaintext credentials**. Until acknowledgement,
the generated password or raw invite secret is retained under the item ID in the
existing `KeyRing`, so credentials remain retrievable across server restarts.
File deployments use `keys.json` (mode 0600); this file is protected by
filesystem permissions, **not encrypted**. Account records retain only the
invite's SHA-256 hash or the password's bcrypt hash. Copying or downloading
acknowledges the item and deletes its plaintext credential from the key ring.

### 4.3 Execution model

- One `ProvisioningRunner` task per running batch; batches run **sequentially**
  (a FIFO queue) to keep pacing and throttling simple.
- Per item: generate identity → validate → create (invite or user) → persist
  item state → sleep `Double.random(in: spec.paceSeconds)`.
- Transient failure (e.g. a generated email collides): regenerate identity,
  retry up to 3 attempts, then mark `failed`. The batch continues.
- On server restart, `queued`/`running` batches resume; items in `creating`
  are reconciled back to `pending` (mirrors `reconcileInterruptedMissions()`).
- Pause/cancel flip batch status; the runner checks status between items, so
  an in-flight item finishes but no new one starts.

### 4.4 Extension points into existing code (coordinate!)

Only two small additions to files other agents may be touching:

1. `AccountStore.createUser(…)` already covers direct creation — **no change
   needed**. For invite delivery, `createInvite(email:role:createdBy:lifetime:)`
   is reused as-is.
2. `ServerContext` gains one field: `let provisioning: ProvisioningStore` plus
   the runner, wired in `ServerContext.make()` next to `accounts`/`sessions`.

Nothing else in `Accounts.swift`, `Auth.swift`, or the existing route handlers
changes.

### 4.5 API contract (all admin-only, under the existing `adminAPI` group)

Mounted at `/api/admin/provisioning/…` in a new `provisioningRoutes(_:ctx:admin:)`
function called from `routes()` — one line added to `Routes.swift`.

| Method & path | Body → Response | Notes |
|---|---|---|
| `POST /api/admin/provisioning/batches` | `BatchSpec` + optional `confirmRole` → `201 PublicBatch` | Validates against limits (§5). Returns batch with items in `pending`. |
| `GET /api/admin/provisioning/batches` | → `[PublicBatch]` | Summary list, newest first. |
| `GET /api/admin/provisioning/batches/:id` | → `{ batch: PublicBatch }` | `BatchDetail` envelope; includes item emails and unacknowledged secrets. |
| `POST /api/admin/provisioning/batches/:id/pause` | → `PublicBatch` | Idempotent. |
| `POST /api/admin/provisioning/batches/:id/resume` | → `PublicBatch` | |
| `POST /api/admin/provisioning/batches/:id/retry-failed` | → `PublicBatch` | `failed` → `pending`. |
| `DELETE /api/admin/provisioning/batches/:id` | → `AckResult` | Cancels; already-created accounts remain and are listed. |

On the JSON wire, `paceSeconds` is a two-element array
(`[lowerBound, upperBound]`), matching Swift's `ClosedRange` coding—not an
object with `lowerBound` and `upperBound` properties.

`BatchDetail` includes `secret` only for items whose secret has not yet been
*acknowledged*. `POST /api/admin/provisioning/batches/:id/ack` with
`{ itemIDs: [UUID] }` marks them acknowledged (exported/copied by the admin),
deletes the plaintext credential, and prevents subsequent responses returning
it. Until acked, a restarted admin session can still retrieve it—a deliberate
usability choice over today's show-once invites. For invite delivery, `secret`
is the server-relative `/invite#<secret>`; the web client expands it to an
absolute URL for display, copying, and CSV export. Direct delivery returns the
generated password itself.

`PublicBatch` omits item emails unless the batch detail endpoint is used;
member-role principals receive `403` from `RequireAdminMiddleware` as usual.

### 4.6 Admin UI — new web page, `pages/ProvisioningPage.tsx` (new file)

Separate page + route (`/provisioning`) linked from `PeoplePage` ("Provision
accounts in bulk →"), keeping `PeoplePage.tsx` nearly untouched for other
agents. Reuses `api/client.ts`, `components/ui.tsx`, and existing CSS classes
(`card`, `table`, `btn`, `chip`, `notice`) — no new styling system.

Sections:

1. **New batch form** — count, role, delivery method, domain checkboxes,
   pace preset (careful/standard/fast), optional invite expiry. Client-side
   mirrors server limits.
2. **Batch list** — status chip, progress `done/total`, created date,
   pause/resume/retry/cancel buttons.
3. **Batch detail** — per-item table (state, email, error, attempts) with
   polling (`setInterval` ~3 s while any item is non-terminal, like
   `useLiveMission` does for missions).
4. **Credential reveal** — for done, un-acked items: per-row copy buttons and
   a **Download CSV** (generated client-side from the fetched detail, never
   re-fetchable after ack). A confirm dialog warns that downloading acks the
   secrets. CSV columns: `email,password_or_invite_link`.

### 4.7 Identity generation

`IdentityGenerator` is pure and unit-testable (`Server/Tests`):

- **Email:** `word.word` or `wordNN` local-part from a ~2k-word list, plus a
  random 2–4 char suffix, at a uniformly random domain from `spec.domains`.
  Collision with an existing user triggers regeneration, not failure.
- **Name:** sampled without replacement from a built-in first/last pool; if a
  batch exceeds the pool, falls back to `name + middle initial`.
- **Password** (direct delivery): 20 chars, base64url alphabet via
  `Secrets.randomToken`-style CSPRNG, satisfying the existing 12–72 byte rule;
  hashed with the existing `Passwords.hash` (bcrypt-12, off the event loop).

## 5. Controls & limits

| Control | Default | Mechanism |
|---|---|---|
| Max batch size | 50 | `AGENTSAM_PROVISIONING_MAX_BATCH` env; `422` above |
| Max new accounts / rolling 24 hours | 200 | `AGENTSAM_PROVISIONING_DAILY_LIMIT` env; includes outstanding reservations; `429` above; `0` disables provisioning entirely (kill switch) |
| Pacing | 30–120 s/item, jittered | `BatchSpec.paceSeconds`, clamped to ≥ 5 s |
| Concurrency | 1 batch at a time | FIFO queue in `ProvisioningRunner` |
| Retries | 3 per item | Regenerate identity on collision; error otherwise |
| Role safety | Batches default to `member`; `admin` batches require `confirmRole: "admin"` in the request body | Prevents fat-fingered mass admin creation |
| Auth | Admin principal + CSRF header (cookie flow) | Existing middleware, unchanged |
| Audit | Batch lifecycle events (`created/paused/done/…`), control actor, item counts—**no emails or secrets** | Compact JSONL at `provisioning-log.jsonl` |

## 6. Security notes

- `provisioning.json` is written via `SecureFile.save` (0600, atomic), same as
  `accounts.json`. Each audit-log update also uses an atomic write and sets
  mode 0600; JSONL is not written through `SecureFile.save`.
- Account records follow the established pattern: SHA-256 invite hashes and
  bcrypt password hashes. To support retrieval until acknowledgement, plaintext
  credentials are also held in the existing `KeyRing`; in file deployments,
  `keys.json` has mode 0600 but is **not encrypted**. `provisioning.json` and
  the audit log never contain these plaintext credentials.
- Require TLS in production. Unacknowledged credentials can be returned more
  than once; acknowledgement deletes the key-ring entry, after which
  `BatchDetail` returns state and emails only.
- Rate limits apply even to the server-token principal, so a leaked
  `AGENTSAM_TOKEN` can't mint unlimited accounts quickly.
- Login throttling, disable/delete semantics, and the last-admin guard are
  untouched and apply to provisioned accounts like any other.

## 7. Compatibility & rollout

1. Server: `Provisioning.swift` composes the existing account store and is
   wired through `ServerContext` and `Routes.swift`. Existing setup, login, and
   invite flows are unchanged; no migration is needed.
2. Web: `ProvisioningPage.tsx`, an admin-only route, and a link in `PeoplePage`.
3. Native apps: none (retired). The `asam_` token comments mentioning them
   are pre-existing and out of scope.

## 8. Defaults and scope decisions

- **Ack-and-retrieve:** credentials remain available until copied/downloaded,
  rather than being lost when the admin closes a tab. This trades temporary
  plaintext key-ring retention for recoverability.
- **Per-batch domains:** domains are supplied in `BatchSpec`; there is no
  server-level domain-pool setting. The UI defaults to reserved
  `example.com`, `example.net`, and `example.org` for local testing; custom
  domains are supported for real accounts.
- **No automatic team assignment:** provisioned members stay team-less until
  an admin assigns them through the existing team controls.
- **Identity separation only:** accounts still share teams and missions; no
  tenant, infrastructure, or native-app separation is introduced.
