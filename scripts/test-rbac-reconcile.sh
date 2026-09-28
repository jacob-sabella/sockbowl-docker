#!/usr/bin/env bash
#
# test-rbac-reconcile.sh: acceptance test for scripts/load-rbac.sh,
# scripts/verify-rbac.sh and scripts/check-secrets.sh against a real Keycloak.
#
# Boots a throwaway postgres + Keycloak (the Keycloak and postgres tags are
# read from docker-compose.yml) with docker compose, runs the loader and the
# verifier inside an alpine container like the rbac-init service, and walks
# through the reconcile scenarios:
#   1. first load, verify passes
#   2. second load reports no changes
#   3. injected drift (extra composite child, stray foo:bar role, a client
#      flag, a deleted mapper, extra service-account and demo-user roles) is
#      detected by verify and removed by the loader
#   4. rotating SOCKBOWL_GAME_BACKEND_SECRET: the new secret works, the old fails
#   5. sockbowl-e2e password-grant tokens carry aud=sockbowl-api; the SPA client
#      refuses the password grant (unauthorized_client)
#   6. SOCKBOWL_E2E=false deletes sockbowl-e2e
#   7. CREATE_DEMO_ACCOUNTS=false disables the demo users
#   8. turning both back on restores them
#   9. a pre-M2 realm (SPA client with ROPC and no audience, backend client
#      created by the old add-only loader, demo users on role "user") is
#      upgraded in place and verifies clean
# plus check-secrets unit cases (run under the host sh and alpine's ash).
#
# Usage: scripts/test-rbac-reconcile.sh
#   RBAC_TEST_PROJECT  compose project name (default sbm2-rbac-<pid>)
#   RBAC_TEST_KEEP     true keeps the stack up after the run (default false)
#
# Requires docker (with compose v2) and jq on the host. Needs no host ports.
#
set -euo pipefail
shopt -s inherit_errexit

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="${ROOT}/scripts/test-rbac-reconcile.compose.yml"
PROJECT="${RBAC_TEST_PROJECT:-sbm2-rbac-$$}"
KEEP="${RBAC_TEST_KEEP:-false}"
KC="http://keycloak:8080"
REALM="sockbowl"
KC_ADMIN_PASSWORD="rbac-test-kc-admin-secret"
SECRET1="rbac-test-backend-secret-one"
SECRET2="rbac-test-backend-secret-two"
DEMO_PW="rbac-test-demo-password"
OUT="$(mktemp)"

export RBAC_TEST_KEYCLOAK_IMAGE RBAC_TEST_POSTGRES_IMAGE
RBAC_TEST_KEYCLOAK_IMAGE="$(grep -oE 'quay\.io/keycloak/keycloak:[^[:space:]"]+' "${ROOT}/docker-compose.yml" | head -n1)"
RBAC_TEST_POSTGRES_IMAGE="$(grep -oE 'image:[[:space:]]*postgres:[^[:space:]"]+' "${ROOT}/docker-compose.yml" | head -n1 | sed 's/image:[[:space:]]*//')"
: "${RBAC_TEST_KEYCLOAK_IMAGE:?could not read the keycloak image from docker-compose.yml}"
: "${RBAC_TEST_POSTGRES_IMAGE:?could not read the postgres image from docker-compose.yml}"

PASSED=0
FAILED=0
pass() { PASSED=$((PASSED + 1)); echo "  PASS: $*"; }
failc() { FAILED=$((FAILED + 1)); echo "  FAIL: $*"; }
check() { local desc="$1"; shift; if "$@"; then pass "$desc"; else failc "$desc"; fi; }
section() { echo; echo "== $*"; }

dc() { docker compose -p "$PROJECT" -f "$COMPOSE_FILE" "$@"; }

teardown() {
  local rc=$?
  rm -f "$OUT"
  if [ "$KEEP" = "true" ]; then
    echo "Keeping stack ${PROJECT} (RBAC_TEST_KEEP=true); remove it with: docker compose -p ${PROJECT} -f ${COMPOSE_FILE} down -v"
  else
    dc down -v --remove-orphans >/dev/null 2>&1 || true
  fi
  exit "$rc"
}
trap teardown EXIT

# ------------------------------------------------------------ helpers

# Env for the loader/verifier. Override per call: E2E=... DEMO=... SECRET=...
loader_env() {
  printf '%s\n' \
    "KEYCLOAK_URL=${KC}" "KEYCLOAK_REALM=${KEYCLOAK_REALM_OVERRIDE:-$REALM}" "KEYCLOAK_ADMIN=admin" \
    "KEYCLOAK_ADMIN_PASSWORD=${KC_ADMIN_PASSWORD}" "RBAC_MODEL=${RBAC_MODEL_OVERRIDE:-/keycloak/rbac-model.json}" \
    "SOCKBOWL_GAME_BACKEND_SECRET=${SECRET:-$SECRET1}" "SOCKBOWL_E2E=${E2E:-true}" \
    "CREATE_DEMO_ACCOUNTS=${DEMO:-true}" "DEMO_PASSWORD=${DEMO_PW}" \
    "APP_PROTOCOL=http" "APP_HOST=localhost" "SOCKBOWL_GAME_PORT=7000" "KC_ACCESS_TOKEN_LIFESPAN=300" \
    "RBAC_CLIENTS_DIR=${RBAC_CLIENTS_DIR:-}"
}

in_tools() {
  local -a envs=()
  local line
  while IFS= read -r line; do envs+=(-e "$line"); done < <(loader_env)
  dc exec -T "${envs[@]}" tools "$@"
}

# run_loader: runs load-rbac.sh, output in $OUT (also echoed); returns its status.
run_loader() { local rc=0; in_tools bash /scripts/load-rbac.sh >"$OUT" 2>&1 || rc=$?; sed 's/^/    | /' "$OUT"; return "$rc"; }
run_verify() { local rc=0; in_tools bash /scripts/verify-rbac.sh >"$OUT" 2>&1 || rc=$?; grep -E 'DRIFT|OK|FAILED|ERROR' "$OUT" | sed 's/^/    | /' || true; return "$rc"; }
# with VAR=VALUE... CMD...: run CMD in a subshell with the overrides applied.
with() { ( while [[ "$1" == *=* ]]; do export "${1?}"; shift; done; "$@" ) }
changes_reported() { grep -c 'CHANGE:' "$OUT" || true; }

jqe() { jq -e "$@" >/dev/null; }
tcurl() { dc exec -T tools curl -sS "$@"; }

admin_token() {
  tcurl -X POST "${KC}/realms/master/protocol/openid-connect/token" \
    -d grant_type=password -d client_id=admin-cli -d username=admin -d "password=${KC_ADMIN_PASSWORD}" | jq -r .access_token
}

# admin METHOD PATH [JSON] -> prints the HTTP status (body discarded)
admin() {
  local tok; tok="$(admin_token)"
  local -a a=(-o /dev/null -w '%{http_code}' -X "$1" "${KC}/admin/realms/${REALM}$2" -H "Authorization: Bearer ${tok}" -H 'Content-Type: application/json')
  [ -z "${3:-}" ] || a+=(--data-binary "$3")
  tcurl "${a[@]}"
}
admin_get() { local tok; tok="$(admin_token)"; tcurl "${KC}/admin/realms/${REALM}$1" -H "Authorization: Bearer ${tok}"; }

client_uuid() { admin_get "/clients?clientId=$1" | jq -r --arg c "$1" '[.[] | select(.clientId == $c)][0].id // empty'; }
user_json() { admin_get "/users?username=$1&exact=true" | jq -c '.[0] // empty'; }

# token_req FORM... -> prints the token endpoint response JSON
token_req() { tcurl -X POST "${KC}/realms/${REALM}/protocol/openid-connect/token" "$@"; }
jwt_claims() {
  jq -r '.access_token // empty' | cut -d. -f2 | jq -Rr 'gsub("-"; "+") | gsub("_"; "/")
    | if length % 4 == 2 then . + "==" elif length % 4 == 3 then . + "=" else . end | @base64d'
}
password_token() { token_req -d grant_type=password -d "client_id=$1" -d "username=$2" -d "password=${3:-$DEMO_PW}" -d scope=openid; }
backend_token() { token_req -d grant_type=client_credentials -d client_id=sockbowl-game-backend -d "client_secret=$1"; }

has_access_token() { jq -e '.access_token | length > 0' >/dev/null 2>&1; }
aud_has_api() { jq -e '(.aud | if type == "array" then . else [.] end) | index("sockbowl-api") != null' >/dev/null; }

# ------------------------------------------------- check-secrets unit cases

run_check_secrets() {
  # run_check_secrets SHELL VAR=VALUE... -> exit status of check-secrets.sh
  local shell="$1"; shift
  env -i PATH="$PATH" "$@" "$shell" "${ROOT}/scripts/check-secrets.sh" >/dev/null 2>&1
}
expect_ok() { run_check_secrets "$@"; }
expect_fail() { ! run_check_secrets "$@"; }

section "check-secrets.sh (host sh)"
check "real secrets pass" expect_ok sh KEYCLOAK_ADMIN_PASSWORD=s3cret-Value POSTGRES_PASSWORD=x9-real SOCKBOWL_GAME_BACKEND_SECRET=abc123def
check "unset/empty secrets are not checked" expect_ok sh KEYCLOAK_ADMIN_PASSWORD=
for bad in admin123 admin 123456789 changeme CHANGE_ME CHANGE_ME_KEYCLOAK_ADMIN_PASSWORD; do
  check "KEYCLOAK_ADMIN_PASSWORD=${bad} fails" expect_fail sh "KEYCLOAK_ADMIN_PASSWORD=${bad}"
done
check "KEYCLOAK_USER_PASSWORD=admin123 fails" expect_fail sh KEYCLOAK_USER_PASSWORD=admin123
check "POSTGRES_PASSWORD=123456789 fails" expect_fail sh POSTGRES_PASSWORD=123456789
check "backend secret change-me-game-backend-secret fails" expect_fail sh SOCKBOWL_GAME_BACKEND_SECRET=change-me-game-backend-secret
check "backend secret CHANGE_ME_BACKEND fails" expect_fail sh SOCKBOWL_GAME_BACKEND_SECRET=CHANGE_ME_BACKEND
check "ALLOW_INSECURE_DEFAULTS=true lets defaults through" expect_ok sh ALLOW_INSECURE_DEFAULTS=true KEYCLOAK_ADMIN_PASSWORD=admin123 SOCKBOWL_GAME_BACKEND_SECRET=change-me-x
msg="$(env -i PATH="$PATH" KEYCLOAK_ADMIN_PASSWORD=CHANGE_ME sh "${ROOT}/scripts/check-secrets.sh" 2>&1 || true)"
check "failure message names the variable and the placeholder" grep -q 'KEYCLOAK_ADMIN_PASSWORD is a' <<<"$msg"
check "failure message mentions ALLOW_INSECURE_DEFAULTS" grep -q 'ALLOW_INSECURE_DEFAULTS=true' <<<"$msg"

# ------------------------------------------------------------ stack

section "Booting ${PROJECT} (${RBAC_TEST_KEYCLOAK_IMAGE}, ${RBAC_TEST_POSTGRES_IMAGE})"
dc up -d --wait --wait-timeout 420

section "check-secrets.sh (alpine ash, as in the init containers)"
check "ash: placeholder fails" bash -c "! docker compose -p '$PROJECT' -f '$COMPOSE_FILE' exec -T -e KEYCLOAK_ADMIN_PASSWORD=CHANGE_ME tools sh /scripts/check-secrets.sh >/dev/null 2>&1"
check "ash: real secret passes" docker compose -p "$PROJECT" -f "$COMPOSE_FILE" exec -T -e KEYCLOAK_ADMIN_PASSWORD=Real-Secret-1 tools sh /scripts/check-secrets.sh

section "0. loader refuses a placeholder backend secret"
rc=0; SECRET=change-me-game-backend-secret run_loader || rc=$?
check "loader exits non-zero" test "$rc" -ne 0
check "loader names the placeholder" grep -q 'SOCKBOWL_GAME_BACKEND_SECRET is a placeholder' "$OUT"
check "nothing was applied" test "$(changes_reported)" -eq 0

section "0b. static model validation (M3/D4 taxonomy:manage move)"
rbac_model="${ROOT}/keycloak/rbac-model.json"
check "author composite excludes taxonomy:manage" jqe '(.compositeRoles.author | index("taxonomy:manage")) == null' <"$rbac_model"
check "moderator composite includes taxonomy:manage" jqe '.compositeRoles.moderator | index("taxonomy:manage")' <"$rbac_model"

section "1. first load, then verify"
check "loader succeeds" run_loader
check "loader reported changes" test "$(changes_reported)" -gt 0
check "verify-rbac passes" run_verify

section "2. second load is a no-op (client templates via RBAC_CLIENTS_DIR)"
check "loader succeeds" with RBAC_CLIENTS_DIR=/keycloak/clients run_loader
check "no changes reported" test "$(changes_reported)" -eq 0
check "summary says 0 changes" grep -q 'RBAC load complete: 0 change(s) applied' "$OUT"

section "2b. rbac-init container layout (/load-rbac.sh, /rbac-model.json, /realm-settings.json, /keycloak-clients)"
rc=0; with RBAC_MODEL_OVERRIDE=/rbac-model.json in_tools bash /load-rbac.sh >"$OUT" 2>&1 || rc=$?; sed 's/^/    | /' "$OUT"
check "loader succeeds from the compose mount layout" test "$rc" -eq 0
check "no changes reported" test "$(changes_reported)" -eq 0

section "3. drift is detected and removed"
player_id="$(admin_get "/roles/player" | jq -r .id)"
userban="$(admin_get "/roles/user:ban")"
check "inject: user:ban into player composite" test "$(admin POST "/roles-by-id/${player_id}/composites" "[${userban}]")" = 204
check "inject: stray role foo:bar" test "$(admin POST /roles '{"name":"foo:bar"}')" = 201
game_uuid="$(client_uuid sockbowl-game)"
game_rep="$(admin_get "/clients/${game_uuid}")"
check "inject: sockbowl-game direct grants on" test "$(admin PUT "/clients/${game_uuid}" "$(jq -c '.directAccessGrantsEnabled = true | .attributes["pkce.code.challenge.method"] = ""' <<<"$game_rep")")" = 204
aud_mapper="$(admin_get "/clients/${game_uuid}/protocol-mappers/models" | jq -r '.[] | select(.name == "sockbowl-api-audience") | .id')"
check "inject: delete the sockbowl-game audience mapper" test "$(admin DELETE "/clients/${game_uuid}/protocol-mappers/models/${aud_mapper}")" = 204
backend_uuid="$(client_uuid sockbowl-game-backend)"
sa_id="$(admin_get "/clients/${backend_uuid}/service-account-user" | jq -r .id)"
check "inject: game:host on the service account" test "$(admin POST "/users/${sa_id}/role-mappings/realm" "[$(admin_get "/roles/game:host")]")" = 204
p2_id="$(user_json player2 | jq -r .id)"
check "inject: admin tier on player2" test "$(admin POST "/users/${p2_id}/role-mappings/realm" "[$(admin_get "/roles/admin")]")" = 204
check "inject: registration off" test "$(admin PUT "" '{"registrationAllowed": false}')" = 204
rc=0; run_verify || rc=$?
check "verify-rbac detects the drift (exit 1)" test "$rc" -eq 1
for d in 'composite player' 'stray permission roles: \["foo:bar"\]' 'client sockbowl-game settings differ' 'client sockbowl-game mappers' 'service account sockbowl-game-backend roles' 'demo user player2 tier roles' 'realm settings differ'; do
  check "verify reports: ${d}" grep -qE "DRIFT: ${d}" "$OUT"
done
check "loader succeeds" run_loader
check "loader removed user:ban from player" grep -q 'composite player: removed \["user:ban"\]' "$OUT"
check "loader deleted foo:bar" grep -q 'stray permission role deleted: foo:bar' "$OUT"
check "verify-rbac passes after reconcile" run_verify
check "foo:bar is gone (404)" test "$(admin GET /roles/foo:bar)" = 404

section "4. backend secret rotation"
check "old secret works before rotation" has_access_token < <(backend_token "$SECRET1")
check "loader with the new secret succeeds" with SECRET="$SECRET2" run_loader
check "rotation reported" grep -q 'client sockbowl-game-backend: secret rotated' "$OUT"
check "new secret gets a token" has_access_token < <(backend_token "$SECRET2")
check "old secret is rejected" bash -c '! jq -e ".access_token" >/dev/null' < <(backend_token "$SECRET1")
backend_claims="$(backend_token "$SECRET2" | jwt_claims)"
check "service token aud contains sockbowl-api" aud_has_api <<<"$backend_claims"
check "service token has packet:read-answers" jqe '.realm_access.roles | index("packet:read-answers")' <<<"$backend_claims"
check "service token has no game:host (no default roles)" jqe '(.realm_access.roles | index("game:host")) == null' <<<"$backend_claims"
SECRET="$SECRET2"
check "verify-rbac passes with the new secret" run_verify

section "5. audience on user tokens, SPA client refuses the password grant"
p2_claims="$(password_token sockbowl-e2e player2 | jwt_claims)"
check "player2 via sockbowl-e2e: aud contains sockbowl-api" aud_has_api <<<"$p2_claims"
check "player2 has game:host" jqe '.realm_access.roles | index("game:host")' <<<"$p2_claims"
check "player2 lacks packet:create" jqe '(.realm_access.roles | index("packet:create")) == null' <<<"$p2_claims"
check "player2 lacks packet:read-answers" jqe '(.realm_access.roles | index("packet:read-answers")) == null' <<<"$p2_claims"
tu_claims="$(password_token sockbowl-e2e testuser | jwt_claims)"
check "testuser (author) has packet:create" jqe '.realm_access.roles | index("packet:create")' <<<"$tu_claims"
check "testuser (author) lacks taxonomy:manage" jqe '(.realm_access.roles | index("taxonomy:manage")) == null' <<<"$tu_claims"
mod_claims="$(password_token sockbowl-e2e moderator | jwt_claims)"
check "moderator has taxonomy:manage" jqe '.realm_access.roles | index("taxonomy:manage")' <<<"$mod_claims"
check "moderator has user:ban" jqe '.realm_access.roles | index("user:ban")' <<<"$mod_claims"
p1_claims="$(password_token sockbowl-e2e player1 | jwt_claims)"
check "player1 (admin) has packet:manage-any and admin:access" jqe '(.realm_access.roles | index("packet:manage-any")) and (.realm_access.roles | index("admin:access"))' <<<"$p1_claims"
check "sockbowl-game refuses the password grant (unauthorized_client)" jqe '.error == "unauthorized_client"' < <(password_token sockbowl-game player2)
game_rep="$(admin_get "/clients/$(client_uuid sockbowl-game)")"
check "sockbowl-game requires PKCE S256" jqe '.attributes["pkce.code.challenge.method"] == "S256"' <<<"$game_rep"
check "sockbowl-game has post-logout redirect URIs" jqe '.attributes["post.logout.redirect.uris"] == "http://localhost/*##http://localhost:4200/*"' <<<"$game_rep"
realm_rep="$(admin_get "")"
check "realm rotates refresh tokens" jqe '.revokeRefreshToken == true and .refreshTokenMaxReuse == 0 and .sslRequired == "external"' <<<"$realm_rep"

section "6. SOCKBOWL_E2E=false deletes sockbowl-e2e"
check "loader succeeds" with E2E=false run_loader
check "deletion reported" grep -q 'client deleted: sockbowl-e2e' "$OUT"
check "sockbowl-e2e no longer exists" test -z "$(client_uuid sockbowl-e2e)"
check "password grant via sockbowl-e2e now fails" bash -c '! jq -e ".access_token" >/dev/null' < <(password_token sockbowl-e2e player2)
check "verify-rbac passes with SOCKBOWL_E2E=false" with E2E=false run_verify

section "7. CREATE_DEMO_ACCOUNTS=false disables the demo users"
check "loader succeeds" with E2E=false DEMO=false run_loader
check "5 demo users disabled" test "$(grep -c 'demo user disabled:' "$OUT")" -eq 5
for u in player1 player2 player3 testuser moderator; do
  check "${u} exists but is disabled" jq -e '.enabled == false' < <(user_json "$u")
done
check "verify-rbac passes with CREATE_DEMO_ACCOUNTS=false" with E2E=false DEMO=false run_verify
rc=0; run_verify >/dev/null || rc=$?
check "verify-rbac flags the realm when the env expects demo users and e2e (exit 1)" test "$rc" -eq 1

section "8. turning dev features back on restores them"
check "loader succeeds" run_loader
check "verify-rbac passes" run_verify
check "player2 can log in via sockbowl-e2e again" has_access_token < <(password_token sockbowl-e2e player2)

section "9. upgrade of a pre-M2 realm (import-created SPA client with ROPC, loader-created backend, demo users on role 'user')"
tok="$(admin_token)"
legacy_realm='{
  "realm": "legacy", "enabled": true, "sslRequired": "none",
  "roles": {"realm": [{"name": "user"}, {"name": "admin"}, {"name": "packet:read"}]},
  "clients": [{
    "clientId": "sockbowl-game", "publicClient": true, "standardFlowEnabled": true,
    "directAccessGrantsEnabled": true, "redirectUris": ["http://localhost/*"],
    "attributes": {"access.token.lifespan": "1800"}
  }],
  "users": [{
    "username": "player2", "enabled": true, "email": "player2@sockbowl.com", "firstName": "Player",
    "lastName": "Two", "emailVerified": true, "realmRoles": ["user"],
    "credentials": [{"type": "password", "value": "demo123", "temporary": false}]
  }]
}'
check "create legacy realm" test "$(tcurl -o /dev/null -w '%{http_code}' -X POST "${KC}/admin/realms" -H "Authorization: Bearer ${tok}" -H 'Content-Type: application/json' --data-binary "$legacy_realm")" = 201
check "create legacy backend client the way the old loader did" test "$(tcurl -o /dev/null -w '%{http_code}' -X POST "${KC}/admin/realms/legacy/clients" -H "Authorization: Bearer ${tok}" -H 'Content-Type: application/json' --data-binary '{"clientId":"sockbowl-game-backend","serviceAccountsEnabled":true,"standardFlowEnabled":false,"publicClient":false,"secret":"change-me-game-backend-secret"}')" = 201
rc=0; with KEYCLOAK_REALM_OVERRIDE=legacy run_verify || rc=$?
check "verify-rbac reports the legacy realm as drifted" test "$rc" -eq 1
check "loader reconciles the legacy realm" with KEYCLOAK_REALM_OVERRIDE=legacy run_loader
check "legacy: SPA client lost direct grants" grep -q 'client updated: sockbowl-game .*directAccessGrantsEnabled' "$OUT"
check "legacy: backend secret replaced" grep -q 'client sockbowl-game-backend: secret rotated' "$OUT"
check "legacy: player2 moved from 'user' to 'player'" grep -q 'demo user player2 roles: removed \["user"\]' "$OUT"
check "verify-rbac passes on the upgraded realm" with KEYCLOAK_REALM_OVERRIDE=legacy run_verify
check "second load on the upgraded realm is a no-op" with KEYCLOAK_REALM_OVERRIDE=legacy run_loader
check "no changes reported" test "$(changes_reported)" -eq 0

echo
echo "test-rbac-reconcile: ${PASSED} passed, ${FAILED} failed"
[ "$FAILED" -eq 0 ]
