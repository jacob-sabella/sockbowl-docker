#!/usr/bin/env bash
#
# Deploy the Sockbowl Keycloak login theme to the sockbowl.com VPS.
#
# The theme is bind-mounted into the keycloak container from the deploy dir on
# the box, and Keycloak runs `start-dev` (theme caching OFF) — so syncing the
# files is all it takes: the next page load serves the new CSS. No container
# recreate, no downtime.
#
# One-time setup already done on the box (survives reboots/redeploys, so this
# script never has to touch it again):
#   - docker-compose.override.yml mounts ./keycloak/themes/sockbowl into keycloak
#   - realm "sockbowl" has loginTheme=sockbowl (persisted in the Keycloak DB)
#
# Usage:  scripts/deploy-keycloak-theme.sh
# Env overrides: VPS_HOST, VPS_USER, SSH_KEY, REMOTE_DIR
set -euo pipefail

VPS_USER="${VPS_USER:-ubuntu}"
VPS_HOST="${VPS_HOST:-15.204.11.205}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/remote_server_key}"
REMOTE_DIR="${REMOTE_DIR:-/home/ubuntu/sockbowl-docker}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
THEME_DIR="$SCRIPT_DIR/../keycloak/themes/sockbowl"

if [[ ! -d "$THEME_DIR" ]]; then
  echo "error: theme dir not found at $THEME_DIR" >&2
  exit 1
fi

echo "Syncing Sockbowl login theme -> $VPS_USER@$VPS_HOST:$REMOTE_DIR/keycloak/themes/"
rsync -az --delete \
  -e "ssh -i $SSH_KEY" \
  "$THEME_DIR" \
  "$VPS_USER@$VPS_HOST:$REMOTE_DIR/keycloak/themes/"

echo "Done. start-dev has no theme cache, so a page reload serves the new theme."
echo "(Tell browsers to hard-reload — the CSS URL is stable, so it may be cached.)"
