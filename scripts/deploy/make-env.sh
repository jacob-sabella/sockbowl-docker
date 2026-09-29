#!/usr/bin/env bash
#
# make-env.sh — WP-D3 (plans/m7-deploy.md §4.4 "Bundle sync": "`.env` is
# created ON the VPS by scripts/deploy/make-env.sh ... It reads
# .env.prod.example and fills each secret NAME from
# /home/ubuntu/sockbowl-docker/.env.alpha or the old override by name, or
# generates it with `openssl rand`. Values are never echoed, and the file is
# chmod 600").
#
# Runs directly on the target host (no ssh inside this script — sync-bundle.sh
# already copied the repo there; the operator or a wrapping runbook step ssh's
# in and runs this file locally).
#
# For each SECRET_KEYS entry whose value in --example is a CHANGE_ME*
# placeholder:
#   1. If --old-env defines that key with a non-empty, non-placeholder value,
#      carry it over verbatim (so redeploys keep the SAME Postgres/Neo4j/
#      Redis/game-backend/OpenAI credentials the old stack already used,
#      rather than orphaning its data) — EXCEPT KEYCLOAK_ADMIN_PASSWORD (see
#      WP KC-ROT below), which is always freshly generated.
#   2. Otherwise generate one with `openssl rand -hex 32` — except
#      OPENAI_API_KEY, which cannot be generated: if it's missing from
#      --old-env this script leaves the CHANGE_ME placeholder in place and
#      prints a loud, one-line warning (never a fabricated value) naming the
#      key, so the operator fills it by hand before `up.sh`.
# Every other line of --example (identity, image tags, memory limits, AI
# model names, ...) is copied through unchanged — only the known secret keys
# are ever substituted.
#
# WP KC-ROT (owner decision 2026-09-29, fixes blocker V1-B01): old prod's
# KEYCLOAK_ADMIN_PASSWORD is a well-known default, and scripts/check-secrets.sh
# correctly refuses it — carrying it verbatim into the live credential (as
# every other secret above does) would mean rbac-init, and everything that
# depends_on it, never starts against migrated data. So this script instead:
#   - ALWAYS generates a fresh KEYCLOAK_ADMIN_PASSWORD (never carries the old
#     value into it, even when --old-env has a real one);
#   - carries --old-env's actual current value, when there is one, into the
#     separate KEYCLOAK_ADMIN_PASSWORD_MIGRATE_FROM one-shot variable
#     instead (left empty on a from-scratch install — nothing to migrate).
#     scripts/check-secrets.sh does not police this name; it is not a live
#     credential, only a one-time bridge scripts/deploy/rotate-kc-admin.sh
#     uses, right after the Keycloak DB restore and KC boot and before
#     rbac-init, to log in exactly once with the OLD password, set the
#     master admin's password to the NEW one, verify the switch, and then
#     delete this line from .env.
#
# NEVER prints a secret value: dry-run messages name the key and say only
# "generated" or "carried over from <file>", never the value itself, and a
# real run writes straight to --out with no intermediate echo.
#
# Usage:
#   scripts/deploy/make-env.sh [--dry-run]
#     [--example FILE] [--old-env FILE] [--out FILE]
#
# Defaults: --example=.env.prod.example (repo root), --old-env=
# /home/ubuntu/sockbowl-docker/.env.alpha, --out=.env (repo root). A missing
# --old-env is not an error (a from-scratch deploy has none) — every secret
# is then freshly generated (OPENAI_API_KEY excepted, per above).
#
# Exit: 0 on success (even when OPENAI_API_KEY is left as a placeholder — that
# is a loud warning, not a failure, since the stack can still boot and be
# filled in later); 1 on a usage error (e.g. --example not found) or if --out
# already exists without --force (this script never silently overwrites a
# live secrets file).
set -euo pipefail
shopt -s inherit_errexit

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_SCRIPT_NAME="make-env"
# shellcheck source=scripts/deploy/lib.sh
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
example="$REPO_ROOT/.env.prod.example"
old_env="/home/ubuntu/sockbowl-docker/.env.alpha"
out="$REPO_ROOT/.env"
force=false

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --example) example="$2"; shift 2 ;;
    --old-env) old_env="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    --force) force=true; shift ;;
    -h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) ddie "unknown argument: $1" ;;
  esac
done

[ -f "$example" ] || ddie "--example not found: $example"
deploy_guard_no_legacy_project "$(dirname -- "$out")" "${COMPOSE_PROJECT_NAME:-}"
if [ -f "$out" ] && [ "$force" != "true" ] && [ "$DRY_RUN" != "true" ]; then
  ddie "$out already exists; pass --force to overwrite it (never done automatically — it may hold live secrets)"
fi

# Keys make-env.sh is allowed to fill (a subset of .env.prod.example's
# "Secrets" section, plus OPENAI_API_KEY). Any other CHANGE_ME_* placeholder
# in --example is left untouched and will trip scripts/check-secrets.sh at
# boot, on purpose — this script only knows how to safely source or generate
# THESE.
SECRET_KEYS=(POSTGRES_PASSWORD NEO4J_PASSWORD SOCKBOWL_REDIS_PASSWORD
  KEYCLOAK_ADMIN_PASSWORD KEYCLOAK_USER_PASSWORD SOCKBOWL_GAME_BACKEND_SECRET
  OPENAI_API_KEY)

is_placeholder() {
  case "$1" in
    CHANGE_ME*|"") return 0 ;;
    *) return 1 ;;
  esac
}

# old_env_value <key> -> prints the value if --old-env defines it with a
# real (non-placeholder) value, empty otherwise. Never logged by the caller.
old_env_value() {
  local key="$1" line val
  [ -f "$old_env" ] || return 0
  line="$(grep -E "^${key}=" "$old_env" 2>/dev/null | tail -n1 || true)"
  [ -n "$line" ] || return 0
  val="${line#*=}"
  is_placeholder "$val" && return 0
  printf '%s' "$val"
}

dlog "== make-env: $example -> $out (secrets from $old_env, or freshly generated) =="

declare -A resolved=()
declare -A source_of=()
for key in "${SECRET_KEYS[@]}"; do
  example_line="$(grep -E "^${key}=" "$example" 2>/dev/null | tail -n1 || true)"
  [ -n "$example_line" ] || continue
  example_val="${example_line#*=}"
  is_placeholder "$example_val" || continue

  if [ "$key" = "KEYCLOAK_ADMIN_PASSWORD" ]; then
    # WP KC-ROT: never carry old prod's value into the live credential —
    # see the header comment and the MIGRATE_FROM resolution below.
    resolved["$key"]="$(openssl rand -hex 32)"
    source_of["$key"]="freshly generated (openssl rand -hex 32) — never carried over from $old_env, per WP KC-ROT"
    continue
  fi

  carried="$(old_env_value "$key")"
  if [ -n "$carried" ]; then
    resolved["$key"]="$carried"
    source_of["$key"]="carried over from $old_env"
  elif [ "$key" = "OPENAI_API_KEY" ]; then
    source_of["$key"]="LEFT AS PLACEHOLDER (cannot be generated; not found in $old_env)"
  else
    resolved["$key"]="$(openssl rand -hex 32)"
    source_of["$key"]="freshly generated (openssl rand -hex 32)"
  fi
done

# WP KC-ROT: resolved independently of the loop above — it reads a
# DIFFERENT source key (--old-env's KEYCLOAK_ADMIN_PASSWORD) into a
# DIFFERENT destination key in --out (KEYCLOAK_ADMIN_PASSWORD_MIGRATE_FROM).
# Only touched when --example actually declares the line (so an --example
# from before this WP, with no such line, is left byte-for-byte alone).
migrate_from_key="KEYCLOAK_ADMIN_PASSWORD_MIGRATE_FROM"
migrate_from_example_line="$(grep -E "^${migrate_from_key}=" "$example" 2>/dev/null | tail -n1 || true)"
if [ -n "$migrate_from_example_line" ]; then
  old_admin_password="$(old_env_value KEYCLOAK_ADMIN_PASSWORD)"
  if [ -n "$old_admin_password" ]; then
    resolved["$migrate_from_key"]="$old_admin_password"
    source_of["$migrate_from_key"]="carried over from $old_env's KEYCLOAK_ADMIN_PASSWORD (one-shot; scripts/deploy/rotate-kc-admin.sh consumes it once, then deletes this line)"
  else
    source_of["$migrate_from_key"]="left empty (no real KEYCLOAK_ADMIN_PASSWORD found in $old_env — nothing to migrate, e.g. a from-scratch install)"
  fi
fi

for key in "${SECRET_KEYS[@]}" "$migrate_from_key"; do
  [ -n "${source_of[$key]:-}" ] || continue
  dlog "  $key: ${source_of[$key]}"
done

if [ "$DRY_RUN" = "true" ]; then
  dlog "[dry-run] would write $out (mode 600) with the above secrets substituted and every other line of $example copied through unchanged"
  exit 0
fi

tmp_out="$(mktemp)"
trap 'rm -f "$tmp_out"' EXIT
cp "$example" "$tmp_out"
for key in "${!resolved[@]}"; do
  val="${resolved[$key]}"
  # Escape sed/regex-special characters in the (random, unknown-content)
  # value so it is inserted literally, never interpreted.
  escaped="$(printf '%s' "$val" | sed -e 's/[\/&]/\\&/g')"
  sed -i "s/^${key}=.*/${key}=${escaped}/" "$tmp_out"
done
chmod 600 "$tmp_out"
mv "$tmp_out" "$out"
trap - EXIT
chmod 600 "$out"

dlog "== make-env: wrote $out (chmod 600). Next: scripts/deploy/ship-images.sh, then 'docker compose --env-file $out ... config -q' =="
if [ -n "${source_of[OPENAI_API_KEY]:-}" ] && [ -z "${resolved[OPENAI_API_KEY]:-}" ]; then
  dwarn "OPENAI_API_KEY is still a CHANGE_ME placeholder in $out — fill it in by hand before starting sockbowl-questions (AI generation will fail until then; everything else boots fine)"
fi
