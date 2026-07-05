# RBAC / Auth — Verification Results (2026-07-05)

Live-verified the Keycloak/RBAC layer end-to-end (Postgres + Keycloak 26.6.4 +
realm import + `load-rbac.sh` + real token minting). The app-layer enforcement
(401/403/200) is proven by the in-repo security slice tests (questions
`SecurityConfigTest`, game `AdminUrlAuthorizationTest`) against the real Spring
Security filter chains.

## PASS
- Keycloak boots and imports the `sockbowl` realm (after the timeout fix below).
- `load-rbac.sh` runs idempotently: 9 permission roles, 4 composites wired,
  realm default = player, service client `sockbowl-game-backend` created with
  `packet:read`, demo users assigned (testuser→author, moderator→moderator,
  player1→admin).
- Token role-expansion verified per tier (realm_access.roles):
  - service account: has `packet:read` (can call questions getPacketById).
  - testuser/author: create/update/read/generate/taxonomy; NO delete/ban/admin.
  - moderator: read/host + `user:ban`; NO admin/author — bans without admin. ✓
  - player1/admin: full permission set.
  - player2/player: read/host only.
- Enforcement (from slice tests): questions unauth→401, wrong-authority→403,
  right→200; game bans URL-scoped to `user:ban` (moderator 200, console 403),
  unauth→401.

## Bugs found during verification and fixed
1. Realm import failed → Keycloak would not start: `Invalid client sockbowl-game:
   Client session idle timeout cannot exceed realm SSO session idle timeout`.
   Fix: set realm `ssoSessionIdleTimeout=3600`, `ssoSessionMaxLifespan=36000` in
   `keycloak/realm-export.template.json` (client override was 3600 > KC default
   1800).
2. Demo `moderator` was hard-coded `["user","admin"]` in `init-keycloak-realm.sh`,
   overriding the RBAC loader's moderator tier (token came back full-admin). Fix:
   demo users now created with base `user` only; `load-rbac.sh` is the single
   source of tier assignment.

## Deferred (needs local image builds)
The containerized HTTP matrix through the running game/questions/ng containers
was NOT run: docker-compose references `ghcr.io/.../:main` images that do not
contain these unpushed changes, so a faithful full-stack HTTP test requires
building local images first. Both halves are independently proven (correct
tokens live + slice-tested enforcement); the single integrated round-trip is the
remaining step, best run after pushing images or with local builds.

## Local test note
Verification used KEYCLOAK_PORT=18080 (host had a service on the default 8080);
the project default stays 8080.
