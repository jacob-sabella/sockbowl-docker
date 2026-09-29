#!/usr/bin/env bash
#
# rotate-kc-admin.sh — WP KC-ROT (owner decision 2026-09-29, fixes blocker
# V1-B01: old prod's KEYCLOAK_ADMIN_PASSWORD is a well-known default, which
# scripts/check-secrets.sh correctly refuses, so rbac-init — and everything
# that depends_on it — never started against migrated data).
#
# Runs INSIDE the new stack, after the Keycloak DB restore and the Keycloak
# boot, and BEFORE rbac-init (plans/m7-deploy.md §5 L3 step 5, between the
# `/auth/health/ready` wait and `up.sh -- up rbac-init`):
#   1. Authenticates as the master admin with the OLD password
#      (KEYCLOAK_ADMIN_PASSWORD_MIGRATE_FROM), once, over the internal
#      network (a `docker exec` into the keycloak container itself, talking
#      to its own localhost — never through the public edge).
#   2. Sets the master admin's password to the NEW value
#      (KEYCLOAK_ADMIN_PASSWORD, already in .env from make-env.sh).
#   3. Verifies the NEW password now authenticates and the OLD one is now
#      refused.
#   4. Deletes the KEYCLOAK_ADMIN_PASSWORD_MIGRATE_FROM line from --env-file
#      — it is a one-shot bridge, never a live credential, and must not
#      linger once the rotation it exists for has happened.
#
# Idempotent: if the NEW password already authenticates (a from-scratch
# install, where the bootstrap admin was created with it directly, or a
# re-run after a prior rotation already succeeded and cleaned up), this is a
# no-op — steps 1-4 above are skipped entirely and it exits 0.
#
# Secrets are NEVER passed as argv to `docker exec`/`kcadm.sh` (both are
# visible to `docker top`/`ps` on the host and inside the container).
# Instead, each password is written to a local, chmod-600, mktemp file and
# redirected to `docker exec -i`'s stdin; the exec'd shell reads one line
# from ITS stdin into a variable and passes it to kcadm.sh only via the
# KC_CLI_PASSWORD environment variable of that single command invocation
# (`VAR=val cmd`, which — like every other secret this repo's compose files
# already hand containers — appears in that process's environment, never in
# its argv/cmdline). kcadm.sh honours KC_CLI_PASSWORD for both `config
# credentials --user` (its documented use) and `set-password
# --new-password` (confirmed empirically against 26.7.4; see
# scripts/deploy/test-kc-rotate.sh). Nothing here ever echoes, logs or
# writes a secret value anywhere except that one redirected stdin.
#
# Usage:
#   scripts/deploy/rotate-kc-admin.sh [--dry-run]
#     [--project-dir DIR] [--env-file FILE] [--kc-container NAME]
#     [--relative-path PATH] [--timeout SECONDS]
#
# Defaults: --project-dir=$REMOTE_DIR, --env-file=<project-dir>/.env,
# --kc-container=<COMPOSE_PROJECT_NAME from --env-file, or "sockbowl-prod">
# -keycloak-1, --relative-path=/auth (the prod overlay's KC_HTTP_RELATIVE_PATH,
# §3.5 — pass '' for a bare-base-file rehearsal with no relative path).
#
# Reads from --env-file (grepped out by name; the file itself is never
# sourced or echoed): KEYCLOAK_ADMIN, KEYCLOAK_ADMIN_PASSWORD (the NEW
# value), KEYCLOAK_ADMIN_PASSWORD_MIGRATE_FROM (the OLD value, one-shot),
# KEYCLOAK_PORT, COMPOSE_PROJECT_NAME.
#
# Exit: 0 once the NEW password is verified to work (whether that took a
# real rotation, or was already true — including the from-scratch/
# nothing-to-migrate case, where MIGRATE_FROM is absent or empty and this
# script only verifies, never touches, the current password). 1 if neither
# password authenticates (a wrong OLD value or DB corruption — this never
# silently falls through to rbac-init in that state) or on a usage error.
set -euo pipefail
shopt -s inherit_errexit

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_SCRIPT_NAME="rotate-kc-admin"
# shellcheck source=scripts/deploy/lib.sh
source "$SCRIPT_DIR/lib.sh"

project_dir="$REMOTE_DIR"
env_file=""
kc_container=""
relative_path="/auth"
timeout=60

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --project-dir) project_dir="$2"; shift 2 ;;
    --env-file) env_file="$2"; shift 2 ;;
    --kc-container) kc_container="$2"; shift 2 ;;
    --relative-path) relative_path="$2"; shift 2 ;;
    --timeout) timeout="$2"; shift 2 ;;
    -h|--help) sed -n '2,55p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) ddie "unknown argument: $1" ;;
  esac
done
[ -n "$env_file" ] || env_file="$project_dir/.env"
[ -f "$env_file" ] || ddie "--env-file not found: $env_file"

# env_value <key> — prints the value of the last KEY=... line in
# --env-file, or nothing. Never logged directly by any caller here.
env_value() {
  local key="$1" line
  line="$(grep -E "^${key}=" "$env_file" 2>/dev/null | tail -n1 || true)"
  [ -n "$line" ] || return 0
  printf '%s' "${line#*=}"
}

project_name="$(env_value COMPOSE_PROJECT_NAME)"
deploy_guard_no_legacy_project "$project_dir" "${project_name:-}"
[ -n "$kc_container" ] || kc_container="${project_name:-sockbowl-prod}-keycloak-1"
deploy_guard_container_name "$kc_container"

admin_user="$(env_value KEYCLOAK_ADMIN)"
[ -n "$admin_user" ] || admin_user="admin"
new_password="$(env_value KEYCLOAK_ADMIN_PASSWORD)"
old_password="$(env_value KEYCLOAK_ADMIN_PASSWORD_MIGRATE_FROM)"
kc_port="$(env_value KEYCLOAK_PORT)"
[ -n "$kc_port" ] || kc_port=8080
[ -n "$new_password" ] || ddie "KEYCLOAK_ADMIN_PASSWORD is empty in $env_file"

server="http://localhost:${kc_port}${relative_path}"

# kc_login <password> — 0 if <password> authenticates the master admin
# against $server inside $kc_container, 1 otherwise. Never prints the
# password: it is written to a local chmod-600 mktemp file and redirected
# to `docker exec -i`'s stdin; the in-container shell reads one line from
# its own stdin and hands it to kcadm.sh only via that single command's
# KC_CLI_PASSWORD env (never argv). The throwaway kcadm config file lives
# only inside the container's /tmp and is removed whether login succeeded
# or not, so no session token is ever left cached.
kc_login() {
  local password="$1" pw_file rc cfg
  cfg="/tmp/rotate-kc-admin.$$.config"
  pw_file="$(mktemp)"
  chmod 600 "$pw_file"
  printf '%s\n' "$password" > "$pw_file"
  set +e
  docker exec -i "$kc_container" sh -c '
    cfg="$1"; server="$2"; user="$3"
    IFS= read -r pw
    rc=0
    KC_CLI_PASSWORD="$pw" /opt/keycloak/bin/kcadm.sh config credentials \
      --config "$cfg" --server "$server" --realm master --user "$user" \
      >/dev/null 2>&1 || rc=1
    rm -f "$cfg"
    exit "$rc"
  ' _ "$cfg" "$server" "$admin_user" < "$pw_file"
  rc=$?
  set -e
  shred -u "$pw_file" 2>/dev/null || rm -f "$pw_file"
  return "$rc"
}

# kc_set_password <old_password> <new_password> — logs in with
# <old_password> (kept only for the duration of this one docker exec) and
# sets the master admin's password to <new_password>, entirely inside the
# container. Both values reach the container the same way as kc_login
# (redirected stdin, one `read` per value, KC_CLI_PASSWORD env only) — never
# argv, never a file that outlives this single exec.
kc_set_password() {
  local old_pw="$1" new_pw="$2" pw_file rc cfg
  cfg="/tmp/rotate-kc-admin.$$.config"
  pw_file="$(mktemp)"
  chmod 600 "$pw_file"
  printf '%s\n%s\n' "$old_pw" "$new_pw" > "$pw_file"
  set +e
  docker exec -i "$kc_container" sh -c '
    cfg="$1"; server="$2"; user="$3"
    IFS= read -r old_pw
    IFS= read -r new_pw
    KC_CLI_PASSWORD="$old_pw" /opt/keycloak/bin/kcadm.sh config credentials \
      --config "$cfg" --server "$server" --realm master --user "$user" || { rm -f "$cfg"; exit 1; }
    KC_CLI_PASSWORD="$new_pw" /opt/keycloak/bin/kcadm.sh set-password \
      --config "$cfg" -r master --username "$user"
    rc=$?
    rm -f "$cfg"
    exit "$rc"
  ' _ "$cfg" "$server" "$admin_user" < "$pw_file"
  rc=$?
  set -e
  shred -u "$pw_file" 2>/dev/null || rm -f "$pw_file"
  return "$rc"
}

# remove_migrate_from — deletes the KEYCLOAK_ADMIN_PASSWORD_MIGRATE_FROM
# line from --env-file, preserving every other line and the file's mode
# (600). Same tmp-file-then-mv pattern make-env.sh uses, so a crash between
# the write and the rename never leaves a half-written .env.
remove_migrate_from() {
  local tmp
  tmp="$(mktemp)"
  grep -v -E '^KEYCLOAK_ADMIN_PASSWORD_MIGRATE_FROM=' "$env_file" > "$tmp" || true
  chmod 600 "$tmp"
  mv "$tmp" "$env_file"
  chmod 600 "$env_file"
}

# kc_login_retry <password> — kc_login, retried every 5s up to --timeout
# total. migrate-data.sh already waits for /auth/health/ready before calling
# this script, but that only proves the HTTP endpoint answers, not that the
# realm's own login flow is fully warmed up yet — this absorbs that gap
# instead of failing on a transient first attempt.
kc_login_retry() {
  local password="$1" deadline
  deadline=$((SECONDS + timeout))
  until kc_login "$password"; do
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 5
  done
  return 0
}

dlog "== rotate-kc-admin: $kc_container ($server, realm master, user $admin_user) =="

if [ "$DRY_RUN" = "true" ]; then
  dlog "[dry-run] would check whether KEYCLOAK_ADMIN_PASSWORD already authenticates (no-op if so)"
  if [ -n "$old_password" ]; then
    dlog "[dry-run] would otherwise log in once with KEYCLOAK_ADMIN_PASSWORD_MIGRATE_FROM, set the master admin's password to KEYCLOAK_ADMIN_PASSWORD, verify the new one works and the old one is refused, then delete KEYCLOAK_ADMIN_PASSWORD_MIGRATE_FROM from $env_file"
  else
    dlog "[dry-run] KEYCLOAK_ADMIN_PASSWORD_MIGRATE_FROM is empty — would only verify the current password (nothing to migrate)"
  fi
  exit 0
fi

if kc_login_retry "$new_password"; then
  dlog "KEYCLOAK_ADMIN_PASSWORD already authenticates against $kc_container — no rotation needed"
  if [ -n "$old_password" ]; then
    dlog "removing the now-redundant KEYCLOAK_ADMIN_PASSWORD_MIGRATE_FROM from $env_file"
    remove_migrate_from
  fi
  dlog "== rotate-kc-admin: no-op, done =="
  exit 0
fi

if [ -z "$old_password" ]; then
  ddie "KEYCLOAK_ADMIN_PASSWORD does not authenticate against $kc_container, and KEYCLOAK_ADMIN_PASSWORD_MIGRATE_FROM is empty — nothing to roll forward from; refusing to proceed to rbac-init in this state"
fi

dlog "KEYCLOAK_ADMIN_PASSWORD does not (yet) authenticate — attempting the one-shot rotation from KEYCLOAK_ADMIN_PASSWORD_MIGRATE_FROM"
kc_set_password "$old_password" "$new_password" \
  || ddie "rotation failed: could not authenticate with KEYCLOAK_ADMIN_PASSWORD_MIGRATE_FROM (or the password change itself failed) against $kc_container"

dlog "verifying the new password now works"
kc_login "$new_password" || ddie "rotation ran, but KEYCLOAK_ADMIN_PASSWORD still does not authenticate — refusing to proceed to rbac-init"

dlog "verifying the old password is now refused"
if kc_login "$old_password"; then
  ddie "rotation ran and the new password works, but the OLD password (KEYCLOAK_ADMIN_PASSWORD_MIGRATE_FROM) still also authenticates — refusing to remove it from $env_file until it is actually dead"
fi

dlog "rotation verified: KEYCLOAK_ADMIN_PASSWORD works, the old value is refused; removing KEYCLOAK_ADMIN_PASSWORD_MIGRATE_FROM from $env_file"
remove_migrate_from

dlog "== rotate-kc-admin: rotation complete =="
