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

## WP-D3: full-stack live verification (2026-09-27)

The integrated round-trip deferred above is now done. Ran
`scripts/smoke-auth.sh` (which delegates the STOMP rows to
`scripts/stomp-probe.mjs`) against a real running stack: locally built
`goal/m2-auth` images (`sockbowl-game:local`, `sockbowl-questions:local`,
`sockbowl-ng:local`) under `docker-compose.yml` + `docker-compose.dev.yml
--profile full`, throwaway project `sbm2-debug-1447605`, real generated
secrets, torn down with `down -v --remove-orphans` afterward (verified zero
containers/volumes left). Two real bugs surfaced only by this live run and
were fixed in `scripts/smoke-auth.sh` (see
`docs/superpowers/specs/2026-07-05-rbac-auth-design.md`'s "Verified live
(WP-D3)" section for what they were and why they are test-fixture fixes, not
application bugs).

```
== smoke-auth: minting tokens (sockbowl-e2e password grant + sockbowl-game-backend client credentials) ==
PASS: minted tokens carry aud=sockbowl-api (sockbowl-api-audience mapper is wired end to end)
SKIP: a token from a client without the audience mapper -> 401 is proved by questions' AudienceIT/JwtAudienceValidationTest (in-JVM Keycloak fixture with a dedicated no-audience client); the real realm has no such client to mint one from without provisioning it just for this check
PASS: minted token iss matches KEYCLOAK_ISSUER_URI (plan risk #5)
PASS: create-new-game-session: guest is allowed (D1) (200)
PASS: create-new-game-session: invalid bearer -> 401 (401)
PASS: create-new-game-session: service token can't host -> 403 (403)
PASS: join-game-session-by-code: unknown code -> 404 (404)
PASS: join-game-session-authenticated: no bearer -> 401 (401)
PASS: join-game-session-authenticated: service token can't join -> 403 (403)
PASS: GET /api/v1/user/profile: anonymous -> 401 (401)
PASS: GET /api/v1/user/profile: service token -> 403 (403)
PASS: GET /api/v1/user/profile: a signed-in player -> 200 (200)
PASS: GET /api/v1/auth/me: anonymous -> 401 (401)
PASS: GET /api/v1/auth/me: a signed-in player -> 200 (200)
PASS: GET /api/v1/auth/status: public -> 200 (200)
PASS: GET /api/v1/admin/bans: anonymous -> 401 (401)
PASS: GET /api/v1/admin/bans: player -> 403 (403)
PASS: GET /api/v1/admin/bans: moderator -> 200 (200)
PASS: POST /api/v1/admin/bans: player -> 403 (403)
PASS: DELETE /api/v1/admin/bans/{id}: player -> 403 (403)
PASS: GET /api/v1/admin/probe: moderator lacks admin:access -> 403 (403)
PASS: GET /api/v1/admin/probe: admin passes the admin:access gate (404: no such controller) -> 404 (404)
PASS: deny-by-default: an unmapped path, anonymous -> 401 (never a redirect) (401)
PASS: deny-by-default: an unmapped path, authenticated -> 403 (never a redirect) (403)
PASS: removed route /api/v1/test -> 401, deny-by-default (TestController deleted) (401)
PASS: removed server-side login flow /login -> 401, never a redirect (401)
PASS: GET /api/qbreader/category-counts: public -> 200 (200)
PASS: GET /api/qbreader/taxonomy-counts: public -> 200 (200)
PASS: GET /api/qbreader/stats: public -> 200 (200)
PASS: GET /api/qbreader/dimensions: public -> 200 (200)
PASS: POST /api/qbreader/count: public -> 200 (200)
PASS: POST /api/qbreader/import-random: anonymous -> 200, an EPHEMERAL packet (D15) (200)
PASS: POST /api/qbreader/import-random: invalid bearer -> 401 (401)
PASS: POST /api/qbreader/import-random: player -> 200, an EPHEMERAL packet (D15) (200)
PASS: POST /api/qbreader/import-random: author -> 200, an owned DRAFT packet (200)
PASS: GET /api/packets/generate: anonymous -> 401 (401)
PASS: GET /api/packets/generate: player -> 403 (403)
PASS: GET game /actuator/health: public -> 200 (200)
PASS: GET questions /actuator/health: public -> 200 (200)
PASS: setPacketVisibility: PUBLISHED took effect
PASS: GraphQL mutation classification: anonymous createPacket -> UNAUTHORIZED
PASS: GraphQL mutation classification: player createPacket (no packet:create) -> FORBIDDEN
PASS: anonymous getPacketById(<draft>) -> null (no existence oracle)
PASS: anonymous reading a PUBLISHED packet: answersRedacted=true
PASS: anonymous reading a PUBLISHED packet: tossup answer is null
PASS: POST /api/v1/admin/bans: moderator bans player3 -> 201 (201)
PASS: create-new-game-session: a banned user -> 403 (403)
PASS: join-game-session-by-code: a banned user -> 403 (checked before the join code) (403)
PASS: join-game-session-authenticated: a banned user -> 403 (403)
PASS: cleanup: removed the smoke-test ban on player3
PASS: guest CONNECT with no playerSecret header -> AUTH_REQUIRED
PASS: bad secret: guest CONNECT with the wrong playerSecret -> INVALID_CREDENTIALS
PASS: CONNECT against an unknown game session -> SESSION_NOT_FOUND
PASS: CONNECT with a player id not in the session -> PLAYER_NOT_IN_SESSION
PASS: guest CONNECT with the correct playerSecret still works (D1, auth is additive)
PASS: authenticated seat CONNECT with no bearer -> AUTH_REQUIRED
PASS: identity mismatch: another user's JWT on this seat -> IDENTITY_MISMATCH
PASS: service token as a player -> INVALID_CREDENTIALS (a service identity can never be a player)
PASS: banned CONNECT: a banned user cannot connect even with a valid, matching JWT -> BANNED
PASS: forged SEND: SEND straight to a broker queue (not /app/**) -> FORBIDDEN_DESTINATION
PASS: forged identity headers on SEND: gameSessionId header not the caller's own -> IDENTITY_MISMATCH
PASS: cross-game SUBSCRIBE: another game's event queue -> FORBIDDEN_DESTINATION
PASS: service-token path: SetMatchPacket succeeds and the game reports the fetched packet (AUTH-18)

62 passed, 0 failed, 1 skipped
== smoke-auth: ALL CHECKS PASSED ==
```

`scripts/test-compose-posture.sh` was re-run first to confirm no regression
from the WP-D3 changes: all three scenarios ((a) placeholder secrets
refused, (b) dev/e2e overlay works, (c) demo users disabled without the
overlay) still pass.
