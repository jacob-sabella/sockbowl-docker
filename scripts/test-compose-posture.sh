#!/usr/bin/env bash
#
# test-compose-posture.sh — compose posture acceptance tests (D9: prod
# default plus dev/e2e overlay; see docs/auth.md "Compose posture").
#
#  (a) .env.example copied as-is, no overlay -> keycloak-realm-init exits
#      non-zero with scripts/check-secrets.sh's placeholder-secret message.
#  (b) with the dev/e2e overlay -> infra + rbac-init come up healthy, player2
#      can obtain a token via the sockbowl-e2e client, and sockbowl-game
#      refuses the password grant (unauthorized_client).
#  (c) without the overlay but with real secrets set -> demo users are
#      disabled.
#
# (b) and (c) exercise the *reconciling* RBAC loader (keycloak/clients/
# *.json, and the "clients"/"demoUsers" keys in keycloak/rbac-model.json). If
# those artifacts are ever absent from a branch under test, this script
# detects that and SKIPs (b) and (c) with an explicit message instead of
# failing.
#
# Uses network_mode: host (like the rest of this compose file), so it cannot
# run concurrently with another full/keycloak+postgres stack on this host —
# serialize full-stack runs (see docs/auth.md "Single full-stack constraint").
set -euo pipefail
cd "$(dirname "$0")/.."

PROJECT="sbm2-compose-posture-$$"
ENV_FILE="$(mktemp)"
STATUS=0

compose() {
  docker compose -p "$PROJECT" --env-file "$ENV_FILE" -f docker-compose.yml "$@"
}
compose_dev() {
  docker compose -p "$PROJECT" --env-file "$ENV_FILE" -f docker-compose.yml -f docker-compose.dev.yml "$@"
}
load_env() {
  # Exports $ENV_FILE's KEY=VALUE lines into this shell, so the curl/admin-API
  # checks below see the same values Compose passed to the containers instead
  # of coincidentally-matching hardcoded fallbacks.
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
}

cleanup() {
  compose_dev down -v --remove-orphans >/dev/null 2>&1 || true
  compose down -v --remove-orphans >/dev/null 2>&1 || true
  rm -f "$ENV_FILE"
}
trap cleanup EXIT

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; STATUS=1; }
skip() { echo "SKIP: $*"; }

d1_artifacts_present() {
  [ -d keycloak/clients ] \
    && [ -f keycloak/realm-settings.json ] \
    && grep -q '"clients"' keycloak/rbac-model.json 2>/dev/null \
    && grep -q '"demoUsers"' keycloak/rbac-model.json 2>/dev/null
}

wait_for_state() {
  # wait_for_state <compose-fn> <service> <state-substring> <timeout-s>
  # Matches against Compose's {{.State}} (running/exited/created/...).
  local fn="$1" svc="$2" want="$3" timeout="${4:-120}" waited=0 state
  while true; do
    state="$($fn ps -a --format '{{.State}}' "$svc" 2>/dev/null || true)"
    if echo "$state" | grep -qi "$want"; then
      return 0
    fi
    waited=$((waited + 3))
    if [ "$waited" -ge "$timeout" ]; then
      echo "  (last state for $svc: '$state')" >&2
      return 1
    fi
    sleep 3
  done
}

wait_for_healthy() {
  # wait_for_healthy <compose-fn> <service> <timeout-s>
  # Matches against Compose's {{.Health}} (starting/healthy/unhealthy), which
  # is a separate field from {{.State}} (running/exited/...).
  local fn="$1" svc="$2" timeout="${3:-180}" waited=0 health
  while true; do
    health="$($fn ps -a --format '{{.Health}}' "$svc" 2>/dev/null || true)"
    if echo "$health" | grep -qi "healthy" && ! echo "$health" | grep -qi "unhealthy"; then
      return 0
    fi
    waited=$((waited + 3))
    if [ "$waited" -ge "$timeout" ]; then
      echo "  (last health for $svc: '$health')" >&2
      return 1
    fi
    sleep 3
  done
}

echo "== test-compose-posture: project $PROJECT =="

### (a) .env.example as-is, no overlay -> keycloak-realm-init fails with the
###     placeholder-secret message.
echo "--- (a) placeholder secrets refused (production posture) ---"
cp .env.example "$ENV_FILE"
load_env
compose up -d keycloak-realm-init >/dev/null 2>&1 || true
if wait_for_state compose keycloak-realm-init exited 60; then
  code="$(compose ps -a --format '{{.ExitCode}}' keycloak-realm-init 2>/dev/null || echo "")"
  logs="$(compose logs keycloak-realm-init 2>&1 || true)"
  if [ "$code" != "0" ] && echo "$logs" | grep -qi "check-secrets"; then
    pass "(a) keycloak-realm-init exited $code with the check-secrets.sh placeholder message"
  else
    fail "(a) expected a non-zero exit with the check-secrets.sh message; got exit=$code. Logs:\n$logs"
  fi
else
  fail "(a) keycloak-realm-init never reached 'exited'"
fi
compose down -v --remove-orphans >/dev/null 2>&1 || true

if ! d1_artifacts_present; then
  skip "(b) requires WP-D1 (keycloak/clients/*.json, rbac-model.json 'clients'/'demoUsers' keys) — not yet merged onto this branch"
  skip "(c) requires WP-D1 (same artifacts)"
  echo "== test-compose-posture: (a) checked; (b)/(c) pending WP-D1 merge =="
  exit "$STATUS"
fi

### (b) with the dev/e2e overlay -> infra + rbac-init healthy, player2 gets a
###     token via sockbowl-e2e, sockbowl-game refuses the password grant.
echo "--- (b) dev/e2e overlay brings up a working, insecure-by-design stack ---"
cp .env.example "$ENV_FILE"
load_env
compose_dev up -d postgres keycloak-realm-init keycloak rbac-init >/dev/null 2>&1
if wait_for_healthy compose_dev keycloak 180 \
  && wait_for_state compose_dev rbac-init exited 120; then
  rbac_code="$(compose_dev ps -a --format '{{.ExitCode}}' rbac-init 2>/dev/null || echo "")"
  if [ "$rbac_code" = "0" ]; then
    pass "(b) infra + rbac-init came up healthy"
    KEYCLOAK_URL="${APP_PROTOCOL:-http}://${APP_HOST:-localhost}:${KEYCLOAK_PORT:-8080}"
    token_resp="$(curl -fsS -X POST "$KEYCLOAK_URL/realms/sockbowl/protocol/openid-connect/token" \
      -d grant_type=password -d client_id=sockbowl-e2e \
      -d username=player2 -d "password=${DEMO_PASSWORD:-demo123}" 2>&1 || true)"
    if echo "$token_resp" | grep -q '"access_token"'; then
      pass "(b) player2 obtained a token via sockbowl-e2e"
    else
      fail "(b) player2 could not obtain a token via sockbowl-e2e: $token_resp"
    fi
    # No -f: a rejected grant is an *expected* non-2xx response here, and -f
    # would make curl discard the JSON error body we need to check.
    game_resp="$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$KEYCLOAK_URL/realms/sockbowl/protocol/openid-connect/token" \
      -d grant_type=password -d client_id=sockbowl-game \
      -d username=player2 -d "password=${DEMO_PASSWORD:-demo123}" 2>&1 || true)"
    game_body="$(curl -sS -X POST "$KEYCLOAK_URL/realms/sockbowl/protocol/openid-connect/token" \
      -d grant_type=password -d client_id=sockbowl-game \
      -d username=player2 -d "password=${DEMO_PASSWORD:-demo123}" 2>&1 || true)"
    if echo "$game_body" | grep -q "unauthorized_client"; then
      pass "(b) sockbowl-game refuses the password grant (unauthorized_client)"
    else
      fail "(b) sockbowl-game did not refuse the password grant as unauthorized_client: http=$game_resp body=$game_body"
    fi
  else
    fail "(b) rbac-init exited non-zero ($rbac_code). Logs:\n$(compose_dev logs rbac-init 2>&1 || true)"
  fi
else
  fail "(b) keycloak/rbac-init never reached the expected state"
fi
compose_dev down -v --remove-orphans >/dev/null 2>&1 || true

### (c) without the overlay but with real secrets set -> demo users disabled.
#
# Real secrets are set from the start (not swapped in partway through): the
# Keycloak master-realm admin password is only honored on that realm's first
# boot (KC_BOOTSTRAP_ADMIN_PASSWORD), so changing it after the fact on the
# same Postgres volume wouldn't take effect. What *does* change between the
# two phases below is the compose file set (dev/e2e overlay -> prod-only) and
# CREATE_DEMO_ACCOUNTS, which is exactly the "same deployment, drop the
# overlay" scenario this test is meant to cover.
echo "--- (c) production posture with real secrets: demo users disabled ---"
cp .env.example "$ENV_FILE"
{
  echo "POSTGRES_PASSWORD=a-real-generated-secret-1"
  echo "NEO4J_PASSWORD=a-real-generated-secret-2"
  echo "KEYCLOAK_ADMIN_PASSWORD=a-real-generated-secret-3"
  echo "KEYCLOAK_USER_PASSWORD=a-real-generated-secret-4"
  echo "SOCKBOWL_GAME_BACKEND_SECRET=a-real-generated-secret-5"
} >> "$ENV_FILE"
load_env
KEYCLOAK_URL="${APP_PROTOCOL:-http}://${APP_HOST:-localhost}:${KEYCLOAK_PORT:-8080}"

admin_token() {
  curl -fsS -X POST "$KEYCLOAK_URL/realms/master/protocol/openid-connect/token" \
    -d grant_type=password -d client_id=admin-cli \
    -d username="${KEYCLOAK_ADMIN:-admin}" -d "password=a-real-generated-secret-3" \
    | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4 || true
}
player2_enabled() {
  curl -fsS -H "Authorization: Bearer $(admin_token)" \
    "$KEYCLOAK_URL/admin/realms/sockbowl/users?username=player2&exact=true" \
    | grep -o '"enabled":[a-z]*' || true
}

# Phase 1 (dev/e2e overlay): creates player2, enabled, on a fresh volume.
compose_dev up -d postgres keycloak-realm-init keycloak rbac-init >/dev/null 2>&1
if wait_for_healthy compose_dev keycloak 180 && wait_for_state compose_dev rbac-init exited 120; then
  rbac_code="$(compose_dev ps -a --format '{{.ExitCode}}' rbac-init 2>/dev/null || echo "")"
  phase1_enabled="$(player2_enabled)"
  if [ "$rbac_code" = "0" ] && [ "$phase1_enabled" = '"enabled":true' ]; then
    # Phase 2: same volumes, same secrets, drop the overlay (prod posture,
    # CREATE_DEMO_ACCOUNTS reverts to its .env.example default of false).
    # `compose up` (no -f dev overlay) recreates the changed services in place.
    compose up -d postgres keycloak-realm-init keycloak rbac-init >/dev/null 2>&1
    if wait_for_healthy compose keycloak 180 && wait_for_state compose rbac-init exited 120; then
      rbac_code2="$(compose ps -a --format '{{.ExitCode}}' rbac-init 2>/dev/null || echo "")"
      if [ "$rbac_code2" = "0" ]; then
        phase2_enabled="$(player2_enabled)"
        if [ "$phase2_enabled" = '"enabled":false' ]; then
          pass "(c) demo user player2 went from enabled to disabled when the overlay was dropped"
        else
          fail "(c) expected player2 to be disabled after dropping the overlay; got: '$phase2_enabled'"
        fi
      else
        fail "(c) rbac-init exited non-zero ($rbac_code2) in the production posture. Logs:\n$(compose logs rbac-init 2>&1 || true)"
      fi
    else
      fail "(c) keycloak/rbac-init never reached the expected state in the production posture"
    fi
  else
    fail "(c) phase 1 (dev/e2e) setup didn't leave player2 enabled (rbac_code=$rbac_code, enabled='$phase1_enabled')"
  fi
else
  fail "(c) keycloak/rbac-init never reached the expected state in phase 1 (dev/e2e)"
fi
compose down -v --remove-orphans >/dev/null 2>&1 || true

if [ "$STATUS" = "0" ]; then
  echo "== test-compose-posture: all checks passed =="
else
  echo "== test-compose-posture: FAILURES ABOVE ==" >&2
fi
exit "$STATUS"
