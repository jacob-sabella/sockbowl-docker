#!/usr/bin/env bash
#
# test-kc-rotate.sh — acceptance test for scripts/deploy/rotate-kc-admin.sh
# (WP KC-ROT). Boots a throwaway Postgres + Keycloak
# (test-kc-rotate.compose.yml), with the master admin bootstrapped to a
# well-known-default-shaped OLD password — exactly the shape a real
# migrated-data restore hands the new stack (blocker V1-B01) — then:
#
#   1. rotate-kc-admin.sh, with a real KEYCLOAK_ADMIN_PASSWORD_MIGRATE_FROM
#      set to the OLD password: must exit 0, the NEW password must then
#      authenticate, the OLD password must then be refused, and
#      KEYCLOAK_ADMIN_PASSWORD_MIGRATE_FROM must be gone from .env.
#   2. run it again, unchanged .env (no MIGRATE_FROM line left): must exit 0
#      as a no-op (the NEW password already works) and finish fast.
#   3. a from-scratch .env (NEW password only, no MIGRATE_FROM line at all)
#      against a Keycloak whose bootstrap admin already *is* that NEW
#      password: must exit 0 as a no-op too (the "fresh install" case).
#   4. a broken .env (a NEW password that doesn't work, and no
#      MIGRATE_FROM to roll forward from): must exit 1 — this is the "never
#      silently let rbac-init run against an unrotated admin" guard.
#
# Nothing here ever echoes a password: every value lives only in a
# generated, chmod-600 .env under a throwaway scratch dir, torn down (shred,
# then rm -rf) on exit.
#
# Usage: scripts/deploy/test-kc-rotate.sh
#   KC_ROTATE_TEST_PROJECT  compose project name (default sbdt-kcrot-<pid>)
#   KC_ROTATE_TEST_KEEP     true keeps the stack up after the run (default false)
#
# Requires docker (with compose v2). Needs no host ports. This file itself
# must pass ShellCheck and `bash -n` (§ "Add or extend a test script", WP
# KC-ROT).
set -euo pipefail
shopt -s inherit_errexit

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/test-kc-rotate.compose.yml"
PROJECT="${KC_ROTATE_TEST_PROJECT:-sbdt-kcrot-$$}"
KEEP="${KC_ROTATE_TEST_KEEP:-false}"

OLD_PASSWORD="kcrot-test-well-known-default-old-pw"
NEW_PASSWORD="kcrot-test-freshly-generated-new-pw-$$"
WRONG_PASSWORD="kcrot-test-this-never-worked"

export KC_ROTATE_TEST_KEYCLOAK_IMAGE KC_ROTATE_TEST_POSTGRES_IMAGE KC_ROTATE_TEST_OLD_PASSWORD
KC_ROTATE_TEST_KEYCLOAK_IMAGE="$(grep -oE 'quay\.io/keycloak/keycloak:[^[:space:]"]+' "${ROOT}/docker-compose.yml" | head -n1)"
KC_ROTATE_TEST_POSTGRES_IMAGE="$(grep -oE 'image:[[:space:]]*postgres:[^[:space:]"]+' "${ROOT}/docker-compose.yml" | head -n1 | sed 's/image:[[:space:]]*//')"
KC_ROTATE_TEST_OLD_PASSWORD="$OLD_PASSWORD"
: "${KC_ROTATE_TEST_KEYCLOAK_IMAGE:?could not read the keycloak image from docker-compose.yml}"
: "${KC_ROTATE_TEST_POSTGRES_IMAGE:?could not read the postgres image from docker-compose.yml}"

SCRATCH="$(mktemp -d)"
ENV_FILE="$SCRATCH/.env"

PASSED=0
FAILED=0
pass() { PASSED=$((PASSED + 1)); echo "  PASS: $*"; }
failc() { FAILED=$((FAILED + 1)); echo "  FAIL: $*"; }
check() { local desc="$1"; shift; if "$@"; then pass "$desc"; else failc "$desc"; fi; }
section() { echo; echo "== $*"; }

dc() { docker compose -p "$PROJECT" -f "$COMPOSE_FILE" "$@"; }

teardown() {
  local rc=$?
  shred -u "$ENV_FILE" 2>/dev/null || rm -f "$ENV_FILE"
  rm -rf "$SCRATCH"
  if [ "$KEEP" = "true" ]; then
    echo "Keeping stack ${PROJECT} (KC_ROTATE_TEST_KEEP=true); remove it with: docker compose -p ${PROJECT} -f ${COMPOSE_FILE} down -v"
  else
    dc down -v --remove-orphans >/dev/null 2>&1 || true
  fi
  exit "$rc"
}
trap teardown EXIT

kc_container="${PROJECT}-keycloak-1"

# write_env <admin_password> [migrate_from] — (re)writes a fresh, chmod-600
# .env with the given KEYCLOAK_ADMIN_PASSWORD and, if given, a
# KEYCLOAK_ADMIN_PASSWORD_MIGRATE_FROM line. No MIGRATE_FROM arg means no
# line at all (the "nothing to migrate" shape), not an empty one.
write_env() {
  local admin_pw="$1" migrate_from="${2:-}"
  {
    printf 'COMPOSE_PROJECT_NAME=%s\n' "$PROJECT"
    printf 'KEYCLOAK_ADMIN=admin\n'
    printf 'KEYCLOAK_ADMIN_PASSWORD=%s\n' "$admin_pw"
    if [ -n "$migrate_from" ]; then
      printf 'KEYCLOAK_ADMIN_PASSWORD_MIGRATE_FROM=%s\n' "$migrate_from"
    fi
    printf 'KEYCLOAK_PORT=8080\n'
  } > "$ENV_FILE"
  chmod 600 "$ENV_FILE"
}

has_line() { grep -q -E "^$1=" "$ENV_FILE" 2>/dev/null; }

# rotate [extra args...] -> runs rotate-kc-admin.sh against $ENV_FILE;
# returns its exit status (never aborts the test script on a nonzero one).
rotate() {
  local rc=0
  "$SCRIPT_DIR/rotate-kc-admin.sh" \
    --project-dir "$SCRATCH" --env-file "$ENV_FILE" \
    --kc-container "$kc_container" --relative-path '' --timeout 90 \
    "$@" || rc=$?
  return "$rc"
}

section "boot: throwaway Postgres + Keycloak (bootstrap admin = the OLD password)"
dc up -d
deadline=$((SECONDS + 180))
until dc ps keycloak --format '{{.Health}}' 2>/dev/null | grep -q healthy; do
  [ "$SECONDS" -lt "$deadline" ] || { echo "FAIL: keycloak never became healthy" >&2; dc logs keycloak | tail -60; exit 1; }
  sleep 3
done
echo "keycloak is healthy"

section "1. real rotation: OLD password -> NEW password, via KEYCLOAK_ADMIN_PASSWORD_MIGRATE_FROM"
write_env "$NEW_PASSWORD" "$OLD_PASSWORD"
check "rotate-kc-admin.sh exits 0" rotate
if has_line KEYCLOAK_ADMIN_PASSWORD_MIGRATE_FROM; then
  failc "KEYCLOAK_ADMIN_PASSWORD_MIGRATE_FROM should have been removed from .env"
else
  pass "KEYCLOAK_ADMIN_PASSWORD_MIGRATE_FROM removed from .env"
fi
check "KEYCLOAK_ADMIN_PASSWORD line is still present (untouched)" has_line KEYCLOAK_ADMIN_PASSWORD

section "2. idempotency: re-run with the same (now-current) .env is a no-op"
before_mtime="$(stat -c %Y "$ENV_FILE")"
start="$(date +%s)"
check "second rotate-kc-admin.sh run exits 0" rotate
elapsed=$(( $(date +%s) - start ))
check "no-op run finished quickly (<20s, no retry/rotation loop)" bash -c "[ $elapsed -lt 20 ]"
after_mtime="$(stat -c %Y "$ENV_FILE")"
check ".env was not rewritten on the no-op run" bash -c "[ $before_mtime -eq $after_mtime ]"

section "3. from-scratch shape: NEW password only, no MIGRATE_FROM line at all, is also a no-op"
write_env "$NEW_PASSWORD"
check "no-MIGRATE_FROM rotate-kc-admin.sh run exits 0 (verifies the current password, changes nothing)" rotate
check "still no MIGRATE_FROM line" bash -c '! grep -q -E "^KEYCLOAK_ADMIN_PASSWORD_MIGRATE_FROM=" "'"$ENV_FILE"'"'

section "4. broken shape: a NEW password that doesn't work and nothing to roll forward from"
write_env "$WRONG_PASSWORD"
check "rotate-kc-admin.sh exits non-zero (refuses to let rbac-init run against an unrotated admin)" bash -c '! "'"$SCRIPT_DIR"'/rotate-kc-admin.sh" --project-dir "'"$SCRATCH"'" --env-file "'"$ENV_FILE"'" --kc-container "'"$kc_container"'" --relative-path "" --timeout 15'

section "5. shellcheck + bash -n on the scripts this test covers"
if command -v shellcheck >/dev/null 2>&1; then
  check "bash -n rotate-kc-admin.sh" bash -n "$SCRIPT_DIR/rotate-kc-admin.sh"
  check "shellcheck -x rotate-kc-admin.sh (warning+)" bash -c "shellcheck -x --severity=warning '$SCRIPT_DIR/rotate-kc-admin.sh'"
  check "bash -n test-kc-rotate.sh" bash -n "$SCRIPT_DIR/test-kc-rotate.sh"
  check "shellcheck -x test-kc-rotate.sh (warning+)" bash -c "shellcheck -x --severity=warning '$SCRIPT_DIR/test-kc-rotate.sh'"
else
  echo "  (shellcheck not on PATH here — skipped; CI's compose-config.yml workflow runs it separately)"
fi

echo
echo "== test-kc-rotate: ${PASSED} passed, ${FAILED} failed =="
[ "$FAILED" -eq 0 ]
