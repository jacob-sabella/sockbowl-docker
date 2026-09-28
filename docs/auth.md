# Authentication and RBAC

This is the docker-repo reference for how Keycloak-backed authentication and
role-based access control are wired into the compose stack. It exists so
nothing in this repo has to cite a design-phase implementation plan that
lives outside this repo to explain itself.
`docs/superpowers/specs/2026-07-05-rbac-auth-design.md` and
`docs/superpowers/plans/2026-07-05-rbac-auth.md` are the original in-repo
spec and implementation-verification notes, kept for history; this page is
the maintained summary.

## Two modes

- **`AUTH_ENABLED=false`** — guest mode. No Keycloak required. Fastest path
  for local iteration; every request is treated as an anonymous guest.
- **`AUTH_ENABLED=true`** (default, the supported path) — Keycloak-backed
  login with RBAC. `sockbowl-game` and `sockbowl-questions` both validate the
  bearer token's issuer (`KEYCLOAK_ISSUER_URI`) and audience (`aud` must
  contain `SOCKBOWL_AUTH_AUDIENCE`, default `sockbowl-api`) before trusting
  it. Without a matching `SOCKBOWL_AUTH_AUDIENCE`/audience mapper, both
  services fall back to `NoSecurityConfig` (permit-all) even with
  `AUTH_ENABLED=true` — silently disabling every `@PreAuthorize` check — so a
  broken audience mapper fails safe by rejecting tokens, not by opening up.

Both apps' WebSocket (STOMP) endpoints enforce the same rules as their REST
and GraphQL endpoints, in both auth modes: guest connections still go through
`StompInboundGuard`, which authenticates CONNECT, binds a principal, and
restricts SUBSCRIBE/SEND destinations. STOMP failures come back as typed
`ERROR` frames (`StompErrorCode`, e.g. `RATE_LIMITED`, `IP_BANNED`,
`INVALID_CREDENTIALS`), never a silently dropped message, and a handful of
codes are fatal (the client must not auto-reconnect on them).

## RBAC model

`keycloak/rbac-model.json` is the single source of truth. `scripts/load-rbac.sh`
(run by the `rbac-init` compose job on every stack start) **reconciles** the
realm against it — composites, clients, demo users, the audience mapper, and
realm settings are all added, updated *and pruned* to match the model, not
just added to. Re-running it against a realm that already matches is a no-op.

**Permission roles** (leaf, `resource:action` shaped):
`packet:read`, `packet:create`, `packet:update`, `packet:delete`,
`question:generate`, `taxonomy:manage`, `game:host`, `user:ban`,
`admin:access`, `packet:manage-any`, `packet:read-answers`.

**Composite (tier) roles**, each accumulating the ones above it:

| Tier | Composed of | Can do |
|---|---|---|
| `player` (default role) | `packet:read`, `game:host` | Host/join games, browse published packets |
| `author` | `player` + `packet:create/update/delete`, `question:generate` | Create and generate questions, own-packet CRUD |
| `moderator` | `player` + `user:ban`, `taxonomy:manage` | Ban/unban users, manage categories/subcategories/difficulties |
| `admin` | `author` + `moderator` + `admin:access`, `packet:manage-any` | Everything, including the admin console and other users' packets |

An authenticated user with none of these composites is treated as `player`.
Anonymous callers are `guest`. `packet:read-answers` is granted **only** to
the `sockbowl-game-backend` service account — it is how the game service
reads full packet content (including answers) when fetching a match's
packet, while every other caller (including a packet's own author before
publish) sees only the answer-free `PUBLISHED` projection unless they own it
or hold `packet:manage-any`. Answers are never sent to a game's broadcast
channel; game reads them once from questions over the service-to-service
call and evaluates buzzes server-side.

## Tokens

- Every game/questions-bound access token must carry `aud` containing
  `SOCKBOWL_AUTH_AUDIENCE` (`sockbowl-api` by default). Keycloak adds this via
  an `oidc-audience-mapper` on the `sockbowl-game`, `sockbowl-game-backend`
  and `sockbowl-e2e` clients (`keycloak/clients/*.json`).
- `KC_ACCESS_TOKEN_LIFESPAN` (default `300`s) sets the access-token lifespan
  on the `sockbowl-game` and `sockbowl-e2e` clients. It is **not** read by
  `sockbowl-game` or `sockbowl-questions` themselves — a token's `exp` is
  entirely Keycloak's doing. To actually shorten the tokens a running stack
  issues (for example to exercise a refresh-token test), set it when bringing
  the overlay up, or re-run just the `rbac-init` job against an already-up
  stack (it reconciles the client in place, no restart needed) — see the
  README's "Testing token refresh" section for the exact commands.
- A token whose `azp` (authorized party) is `sockbowl-game-backend` is treated
  as a **service** identity, not a user: it can't host or join games and is
  rejected at `/api/v1/user/**` and at STOMP CONNECT.

## Compose posture (D9)

`docker-compose.yml` alone is **production-capable by default**:

- Keycloak runs `start` (not `start-dev`), with strict hostname validation
  against `KEYCLOAK_PUBLIC_URL` (`KC_HOSTNAME_STRICT=true`). A mismatch
  between `KEYCLOAK_PUBLIC_URL` and `KEYCLOAK_ISSUER_URI` fails issuer
  validation everywhere the token is checked.
- `CREATE_DEMO_ACCOUNTS` and `SOCKBOWL_E2E` default to `false` — no demo
  users, no password-grant client.
- `scripts/check-secrets.sh` (sourced by `init-keycloak-realm.sh` and
  `load-rbac.sh`) refuses to bring the realm up while
  `POSTGRES_PASSWORD`, `KEYCLOAK_ADMIN_PASSWORD`, `KEYCLOAK_USER_PASSWORD` or
  `SOCKBOWL_GAME_BACKEND_SECRET` still hold a `CHANGE_ME_*` placeholder or a
  well-known-weak value (`admin`, `admin123`, `password`, `demo123`, ...).

`docker-compose.dev.yml` is the local/e2e overlay: `start-dev`, relaxed
hostname checking, demo accounts and the `sockbowl-e2e` direct-grant client
turned on, and `ALLOW_INSECURE_DEFAULTS=true` (which is what lets
`check-secrets.sh`'s placeholder values through). It maps the five demo
logins (password `DEMO_PASSWORD`, default `demo123`) to the four tiers —
see the README's "Authentication modes" section for the exact mapping.
Never use this overlay for a real deployment.

## Client IP and reverse proxies

`ClientIpResolver` (used by both the RBAC layer's audit/ban logic and the
rate limiter — see `docs/limits.md`) trusts `request.getRemoteAddr()` only,
unless `SOCKBOWL_FORWARD_HEADERS_STRATEGY=native` **and**
`SOCKBOWL_TRUSTED_PROXIES_REGEX` is a non-blank regex anchored to the actual
reverse proxy's address. Both apps refuse to start with the `framework`
strategy (it would trust `X-Forwarded-*` from any peer, with no proxy-count
check at all), and `native` with a blank regex is refused too (an empty
regex would trust every peer as a proxy). See `.env.example`'s "Client IP"
comment next to `SOCKBOWL_TRUSTED_PROXIES_REGEX` for the exact env vars,
including the Cloudflare-specific `SOCKBOWL_REMOTE_IP_HEADER` case.

## Single full-stack constraint

Every service in `docker-compose.yml` runs with `network_mode: host`, so
only one full stack (`--profile full`) can be up on a host at a time —
a second `-p` project would collide on the same host ports. Scripts and
CI that bring up a full stack (`scripts/clean-clone-test.sh`,
`scripts/test-compose-posture.sh`, `scripts/test-limits-wiring.sh`, the
`auth-smoke.yml` workflow) serialize on a machine-wide lock; the caller is
responsible for holding it, not the script itself. Named data volumes
(`postgres_data`, `neo4j_data`, ...) are per compose-project, so a throwaway
`-p` project's `down -v` never touches another project's data.

## See also

- `docs/limits.md` — rate limiting, quotas and abuse controls (M4), which
  build on the same identity (`LimitSubject`) and tier model described above.
- README.md — "Authentication modes", "Production secrets" and "Testing
  token refresh" for the exact commands.
- `docs/superpowers/specs/2026-07-05-rbac-auth-design.md` and
  `docs/superpowers/plans/2026-07-05-rbac-auth.md` — the original design
  spec and its implementation-verification notes.
