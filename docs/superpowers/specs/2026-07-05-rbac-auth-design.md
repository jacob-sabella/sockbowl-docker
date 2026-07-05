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
| `author` | `player` + `packet:create`, `packet:update`, `question:generate`, `taxonomy:manage` |
| `moderator` | `player` + `user:ban` |
| `admin` | `author` + `moderator` + `packet:delete` + `admin:access` |

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
