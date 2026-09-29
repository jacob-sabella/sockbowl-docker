# Sockbowl RBAC / Auth — Design Spec

Date: 2026-07-05
Status: Approved (taxonomy + loader), pending implementation
Repos: sockbowl-docker (Keycloak), sockbowl-questions, sockbowl-game, sockbowl-ng

## Goal

Turn authentication on across the whole stack and enforce a proper,
permission-based RBAC model that lives in Keycloak, is provisioned with
sensible defaults, and is re-composable by the operator without code changes.

## Two-layer authorization model (scope boundary)

There are two distinct kinds of authorization; only the first is RBAC/Keycloak:

1. **Platform RBAC (Keycloak realm roles).** Coarse, per-user, realm-wide
   capabilities: author packets, generate questions, ban users, administer.
   Enforced via Spring method security (`@PreAuthorize`) using authorities
   mapped from the JWT `realm_access.roles` claim.
2. **In-session authorization (game engine, unchanged).** Per-session, dynamic
   position: is this player the proctor / game owner? Gates buzzing, judging,
   advancing rounds. Owned by `GameAuthorizationPolicy` + session state. NOT a
   Keycloak role and out of scope for this work, except that the *entry* gate
   "may create/join a game" becomes a platform permission.

## Permission model

### Permission-roles (fine-grained realm roles; apps check these)

| Permission | Guards |
|---|---|
| `packet:read` | view/search packets, `getPacketById` (incl. game→questions svc call) |
| `packet:create` | create packets, add tossups/bonuses |
| `packet:update` | edit tossups/bonuses/parts |
| `packet:delete` | delete packets, remove tossups/bonuses/parts |
| `question:generate` | AI generation (generatePacket / generateTossup) |
| `taxonomy:manage` | create categories / subcategories / difficulties |
| `game:host` | create a game session (authenticated host) |
| `user:ban` | ban / unban users (moderation) |
| `admin:access` | admin console / user management |

### Composite roles (assigned to users; re-composable in Keycloak)

| Role | Bundles |
|---|---|
| `player` | `packet:read`, `game:host` |
| `author` | `player` + `packet:create`, `packet:update`, `question:generate` |
| `moderator` | `player` + `user:ban`, `taxonomy:manage` |
| `admin` | `author` + `moderator` + `packet:delete` + `admin:access` |

M3 D4 moves `taxonomy:manage` from `author` to `moderator`: taxonomy (category /
subcategory / difficulty) creation, rename and merge is a moderation action,
not an authoring one. Authors keep `packet:create`/`packet:update` and pick
from existing taxonomy entries; `admin` still has `taxonomy:manage` through
`moderator`.

New realm users default to `player` (Keycloak realm default-role).

Backward-compat note: existing code checks `hasRole('user')` / `hasRole('admin')`.
`user` and `admin` remain as roles; `admin` becomes a composite as above. The
legacy `user` role is kept as an alias for `player` (composite → player) so
existing `ROLE_USER` checks keep working during migration, and new checks use
fine-grained authorities.

## Keycloak provisioning

Single source of truth: `keycloak/rbac-model.json` — declares permission-roles,
composite roles, their memberships, the default role, and the service client.

- `scripts/load-rbac.sh` — idempotent upsert into a running Keycloak via the
  Admin REST API (create-or-update each role, set composites, set realm default
  role, ensure the service client + its service-account role mappings). Safe to
  re-run; this is the operator's "load/reload RBAC" command.
- Runs automatically as a compose init step (`rbac-init`) gated on Keycloak
  health, because `--import-realm` only applies on a fresh/empty realm and must
  not be relied on for updates.
- The base realm template keeps only realm + clients + base config; all roles
  come from the loader so there is exactly one place to change the model.

### Service account for game → questions

New confidential client `sockbowl-game-backend` (service accounts enabled,
`client_credentials` grant), granted `packet:read` via its service-account.
The game backend obtains a client-credentials token and attaches it to the
`PacketClient` GraphQL calls so server-to-server packet fetches authenticate
even though no user token is present in the WebSocket processing chain.

## Enforcement per service

### sockbowl-questions (new)

- Add `spring-boot-starter-oauth2-resource-server` + `spring-boot-starter-security`.
- Resource-server JWT validation against `KEYCLOAK_ISSUER_URI`; realm-role →
  authority converter (copy game's `keycloakJwtAuthenticationConverter`).
- `SecurityConfig` (auth on) / `NoSecurityConfig` (auth off) gated on
  `sockbowl.auth.enabled`, mirroring game. When on: **all** endpoints require a
  valid token (per decision); method-level `@PreAuthorize` on resolvers:
  - queries / packet search → `hasAuthority('packet:read')`
  - create* / add* → `packet:create`; update* → `packet:update`;
    delete*/remove* → `packet:delete`
  - generate* → `question:generate`
  - createCategory/Subcategory/Difficulty → `taxonomy:manage`
- CORS: keep the existing allowlist (already wired to `SOCKBOWL_ALLOWED_ORIGINS`).
  Auth is via bearer `Authorization` header, not cookies, so no
  `allowCredentials`/cookie handling is required.

### sockbowl-game

- Keep existing security. Replace coarse capability checks with fine-grained
  authorities where they exist:
  - `canCreateGame` / authenticated join → `game:host`
  - `AdminBanController` `hasRole('admin')` → `hasAuthority('user:ban')`
  - admin console endpoints → `admin:access`
- `GameAuthorizationPolicy` capability checks updated to consult authorities.
- Add client-credentials token acquisition (service account) + attach to
  `PacketClient`.

### sockbowl-ng

- Default `authEnabled: true`.
- Expose permissions from the access token (already decodes `realm_access.roles`);
  add a `hasPermission(p)` helper and show/hide author/moderator/admin UI by
  permission. Route guards for author/admin areas.
- No new client (uses `sockbowl-game` public client; the same token is accepted
  by both backends via issuer validation).

## Default posture

`AUTH_ENABLED` / `SOCKBOWL_AUTH_ENABLED` default to **true** in compose/.env.
Demo accounts seeded with roles: an `admin` demo user (admin composite) and a
regular demo user (player). Authoring demo user gets `author`.

## Verification (full stack)

1. `docker compose --profile full up` on a fresh volume; assert Keycloak import
   + `load-rbac.sh` succeed (roles/composites/service client present).
2. Client-credentials: obtain a `sockbowl-game-backend` token, call questions
   `getPacketById` → 200; without token → 401.
3. User flow: log in as author demo → create packet 200; as player → create
   packet 403, read 200. Unauthenticated → 401 everywhere on questions.
4. Game: host a session as player (200); ban endpoint as player 403, as
   moderator/admin 200. Packet selection in a match loads (service token path).
5. UI: author sees authoring controls; player does not.

## Out of scope

- In-session mechanics (proctor/buzz/round) authorization — unchanged.
- Multi-instance concurrency (latent; single-instance).
- Migrating to Keycloak fine-grained Authorization Services (UMA) — realm
  composite roles are sufficient and simpler.

## Revision 2, M2 (2026-09)

Implementation (M2, in waves) landed with the following refinements to this
spec. `keycloak/rbac-model.json` is the source of truth; this section
reconciles it against Revision 1 above. See `docs/auth.md` for the
maintained day-to-day summary of the decisions below.

- **D1 Guest posture.** Auth is additive, not a guest-mode toggle: guests can
  still host and join without a token, and a signed-in user hosts/joins with
  a JWT (bans, ownership and stats then apply to that identity). `game:host`
  gates authenticated hosting/joining
  (`join-game-session-authenticated`); guest hosting/joining stays
  `permitAll` (see the guest endpoint list below).
- **D2 Packet visibility.** `Packet.visibility` (`DRAFT`/`PUBLISHED`, plus
  `EPHEMERAL` — D15) drives `PacketReadPolicy`. An anonymous or player reader
  gets the answer-free `PacketProjection` (`answersRedacted: true`, tossup/
  bonus answers null) for a `PUBLISHED` packet, and `null` (no existence
  oracle) for a `DRAFT`/`EPHEMERAL` packet they can't see. Full content
  (including answers) is available to the owner, `packet:manage-any`
  holders, and — the mechanism this revision adds — a caller holding
  **`packet:read-answers`**.
- **`packet:read-answers` (new permission-role).** Granted *only* to the
  `sockbowl-game-backend` service account (no human composite holds it): this
  is how the game's server-to-server packet fetch (AUTH-18) reads full
  answers for the proctor without any human user ever being granted
  answer-read as a platform permission. `packet:read` (existence/search,
  answer-free) and `packet:read-answers` (this) are deliberately separate
  authorities. For a normal (DRAFT/PUBLISHED) packet, full read is
  `packet:read-answers` OR `packet:manage-any` OR the recorded owner; for a
  **game-only (EPHEMERAL, D15) packet** it is `packet:read-answers` *only* —
  `packet:manage-any` does not apply and there is no owner
  (`PacketReadPolicy.canReadFull`).
- **D3 Ownerless packets.** `packet:manage-any` is required to edit a packet
  with no owner. `import-random` records the caller as owner when they hold
  `packet:create`; see D15 for the no-`packet:create` case.
- **Author `packet:delete` (clarifies Revision 1).** Revision 1's composite
  table only put `packet:delete` on `admin`. Implementation gives it to
  `author` directly (`rbac-model.json` `compositeRoles.author` includes
  `packet:delete`) — an author can delete **their own** packets without
  needing `admin`; `packet:manage-any` (admin-only) is still required to
  delete an ownerless or someone else's packet. `admin`'s composite still
  lists `packet:delete` explicitly (redundant with inheriting it via
  `author`, kept for readability of the model file).
- **D15 (amends D3).** `POST /api/qbreader/import-random` stays `permitAll`
  (guests and players keep the existing UX). A caller without
  `packet:create` (guest or player) gets an ownerless, unlisted `EPHEMERAL`
  packet, game-only-readable, not editable, deleted after 24h (M4 TTL sweep
  rate-limits creation per IP). A caller with `packet:create` still gets an
  owned `DRAFT` as before.
- **D8 Bans (M2 scope).** Bans are stored app-locally in `sockbowl-game`'s
  Postgres (`BanService`), gated on `user:ban`
  (`AdminBanController`/`/api/v1/admin/bans*`). Enforced at REST
  session-create/join and at STOMP CONNECT (`StompConnectAuthenticator`,
  `BANNED`). Redis publication for questions to consult, IP/CIDR bans and
  STOMP-SEND-time (mid-game) enforcement are **not** part of M2 — they remain
  M4 scope (risk #9, "Ban gaps remain until M4").
- **D9 Compose posture.** `docker-compose.yml` is production-capable by
  default (`AUTH_ENABLED`/`CREATE_DEMO_ACCOUNTS`/`SOCKBOWL_E2E` default to
  `true`/`false`/`false`; Keycloak `start`, strict hostname). A
  `docker-compose.dev.yml` overlay turns on `CREATE_DEMO_ACCOUNTS`,
  `SOCKBOWL_E2E` (a direct-grant `sockbowl-e2e` client for tests/CI) and
  `ALLOW_INSECURE_DEFAULTS` (bypasses `scripts/check-secrets.sh`'s
  placeholder-secret refusal), and switches Keycloak to `start-dev`. See
  `scripts/test-compose-posture.sh` for the acceptance tests and
  `docker-compose.build.yml` for layering locally-built images on top.
- **The audience.** Every game/questions-bound access token must carry
  `aud` containing `sockbowl-api` (`SOCKBOWL_AUTH_AUDIENCE`, a Keycloak
  client-scope mapper reconciled by `scripts/load-rbac.sh`); both services'
  `JwtDecoderConfig` validates it and rejects a token without it with 401.
  `scripts/smoke-auth.sh` asserts a minted token's `aud` claim end-to-end;
  the specific "no audience mapper" 401 case is covered by an in-JVM fixture
  (questions' `AudienceIT`/`JwtAudienceValidationTest`, a dedicated
  no-audience Keycloak client), not by the live smoke test, since the real
  realm has no such client to mint a token from.
- **The guest endpoint list (`permitAll`, no token required; an invalid
  bearer, if sent anyway, is still rejected 401).**
  - game: `POST /api/v1/session/create-new-game-session`,
    `POST /api/v1/session/join-game-session-by-code`,
    `GET /api/v1/auth/status`, `GET /actuator/health(/**)`,
    `/sockbowl-game(/**)` (the WebSocket handshake only — authentication
    happens at STOMP CONNECT, not here).
  - questions: `POST /graphql` (open at the URL level; every mutation is
    `@PreAuthorize`'d and every packet query goes through
    `PacketReadPolicy`), the bank aggregate reads (`GET /api/qbreader/stats`,
    `/dimensions`, `/category-counts`, `/taxonomy-counts`,
    `POST /api/qbreader/count`), `POST /api/qbreader/import-random` (D15),
    `GET /actuator/health(/**)`.
- **STOMP error codes.** `StompErrorCode`: `AUTH_REQUIRED`,
  `INVALID_CREDENTIALS`, `TOKEN_EXPIRED`, `BANNED`, `SESSION_NOT_FOUND`,
  `PLAYER_NOT_IN_SESSION`, `IDENTITY_MISMATCH`, `FORBIDDEN_DESTINATION`,
  `INTERNAL`.
- **The headers/body contract.** A fatal rejection (CONNECT failures; any
  SEND/SUBSCRIBE violation) is a STOMP `ERROR` frame carrying the native
  header `x-sockbowl-error: <CODE>` and a JSON body
  `{"code": "<CODE>", "message": "...", "retryAfterSeconds": <n|null>}`; the
  server then closes the socket (`SockbowlStompErrorHandler`). A *non-fatal*
  error (e.g. a mid-game `PLAYER_NOT_IN_SESSION` on a single bad SEND) is
  instead delivered as the same JSON shape to `/user/queue/errors`
  (`StompExceptionAdvice`) and the socket stays open. Clients (the ng bot
  harness, `scripts/stomp-probe.mjs`) read `code` from the JSON body first,
  falling back to the `x-sockbowl-error`/`message` native headers.

### Verified live (WP-D3)

`scripts/smoke-auth.sh` (REST + GraphQL) and `scripts/stomp-probe.mjs`
(STOMP, delegated to from within it) exercise every row above against a real
running stack: locally built `goal/m2-auth` images
(`sockbowl-game`/`sockbowl-questions`/`sockbowl-ng`) under
`docker-compose.yml` + `docker-compose.dev.yml --profile full`, a throwaway
`sbm2-`-prefixed compose project, real generated secrets (no placeholders),
`ALLOW_INSECURE_DEFAULTS` off the app services (only the dev overlay's
Keycloak/rbac-init reconciliation uses it). Result: **62 passed, 0 failed, 1
skipped** (the skip is the no-audience-mapper 401 case, which needs a
dedicated Keycloak client and is instead covered by an in-JVM fixture — see
"The audience" above). See
`docs/superpowers/plans/2026-07-05-rbac-verification.md` for the pasted
output table.

Two real bugs surfaced only by this live run (neither visible from unit/IT
tests, which don't go through the compose stack) and were fixed in
`scripts/smoke-auth.sh` itself, not in application code:

- `CreateGameRequest` binds via its all-args constructor, so a
  `create-new-game-session` body that omits a primitive field (e.g.
  `bonusesEnabled`) gets JSON `null` for it and 400s before authorization
  even runs. The script now sends the full `GameSettings` object, as a real
  client does.
- `docker-compose.yml` wires no loader for the qbreader question-bank data
  (`BankTossup`/`BankBonus` nodes); only `base.graphml`'s
  `Packet`/`Tossup`/`Bonus` fixture is imported. A stack brought up from
  scratch therefore has an empty bank and `import-random` 404s for every
  caller regardless of role — not an authorization gap. The script now
  seeds a small bank fixture (the same shape as questions'
  `EphemeralPacketFlowIT`) over Neo4j's HTTP query endpoint before exercising
  those rows, and removes it on exit. This gap in the compose stack itself
  (no bank data outside a smoke test's own seeding) is otherwise
  undocumented; a future WP wiring a real qbreader-dump loader into compose
  should know `scripts/smoke-auth.sh`'s fixture is a workaround, not that
  loader.
