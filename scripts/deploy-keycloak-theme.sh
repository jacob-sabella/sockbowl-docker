#!/usr/bin/env bash
#
# Deploy the Sockbowl Keycloak login theme to the VPS (H17, WP-D3,
# plans/m7-deploy.md §3.5/§4.5).
#
# M7 changes from the pre-M7 version of this script:
#   - New deploy dir: /home/ubuntu/sockbowl-prod, never sockbowl-docker (§4.5:
#     the legacy project dir is refused outright, same as every other
#     scripts/deploy/ script).
#   - New ssh key: ~/.ssh/homelab (D23), not ~/.ssh/remote_server_key.
#   - Keycloak now runs `start` (§3.5), not `start-dev` — themes ARE cached
#     in that mode, so a plain file sync no longer takes effect on its own.
#     This script now restarts the keycloak container after the rsync (a
#     restart, not a recreate: the bind mount and realm config are
#     untouched, so no data changes; a brief availability gap is expected).
#
# Usage:  scripts/deploy-keycloak-theme.sh [--dry-run]
# Env overrides: VPS_HOST, VPS_USER, SSH_KEY, REMOTE_DIR, KEYCLOAK_CONTAINER
# (default ${COMPOSE_PROJECT_NAME:-sockbowl-prod}-keycloak-1, Compose v2's
# default container-name shape for the "keycloak" service).
set -euo pipefail
shopt -s inherit_errexit

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_SCRIPT_NAME="deploy-keycloak-theme"
# shellcheck source=scripts/deploy/lib.sh
source "$SCRIPT_DIR/deploy/lib.sh"

KEYCLOAK_CONTAINER="${KEYCLOAK_CONTAINER:-${COMPOSE_PROJECT_NAME:-sockbowl-prod}-keycloak-1}"

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) ddie "unknown argument: $1" ;;
  esac
done

deploy_guard_no_legacy_project "$REMOTE_DIR" "${COMPOSE_PROJECT_NAME:-}"
deploy_guard_container_name "$KEYCLOAK_CONTAINER"

THEME_DIR="$SCRIPT_DIR/../keycloak/themes/sockbowl"
[ -d "$THEME_DIR" ] || ddie "theme dir not found at $THEME_DIR"

dlog "Syncing Sockbowl login theme -> ${VPS_USER}@${VPS_HOST}:${REMOTE_DIR}/keycloak/themes/"
run rsync -az --delete \
  -e "ssh -i $SSH_KEY -o BatchMode=yes" \
  "$THEME_DIR" \
  "${VPS_USER}@${VPS_HOST}:${REMOTE_DIR}/keycloak/themes/"

dlog "Restarting $KEYCLOAK_CONTAINER (§3.5: 'start' mode caches themes, unlike the old 'start-dev' — a restart is required to pick up the new files; realm config and the bind mount are untouched)"
deploy_ssh "docker restart '${KEYCLOAK_CONTAINER}'"

dlog "Done. (Tell browsers to hard-reload — the CSS URL is stable, so it may be cached client-side regardless of the server-side change.)"
