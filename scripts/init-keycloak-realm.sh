#!/bin/sh
set -e

# Install required packages
apk add --no-cache gettext

# Refuse to boot with placeholder/well-known-weak secrets unless the caller
# explicitly opted in (ALLOW_INSECURE_DEFAULTS=true; docker-compose.dev.yml
# sets this for local/e2e use). Sourced, not executed, so a failure here
# exits this script directly.
# shellcheck source-path=SCRIPTDIR source=check-secrets.sh
. "$(dirname "$0")/check-secrets.sh"

echo "Generating Keycloak realm export from template..."

# Default values if environment variables are not set
export APP_HOST="${APP_HOST:-localhost}"
export APP_PROTOCOL="${APP_PROTOCOL:-http}"
export SOCKBOWL_GAME_PORT="${SOCKBOWL_GAME_PORT:-7000}"
export SOCKBOWL_PUBLIC_URL="${SOCKBOWL_PUBLIC_URL:-${APP_PROTOCOL}://${APP_HOST}}"
export KEYCLOAK_USER_USERNAME="${KEYCLOAK_USER_USERNAME:-admin}"
export KEYCLOAK_USER_EMAIL="${KEYCLOAK_USER_EMAIL:-admin@sockbowl.com}"
export KEYCLOAK_USER_FIRSTNAME="${KEYCLOAK_USER_FIRSTNAME:-Admin}"
export KEYCLOAK_USER_LASTNAME="${KEYCLOAK_USER_LASTNAME:-User}"
export KEYCLOAK_USER_PASSWORD="${KEYCLOAK_USER_PASSWORD:-admin123}"

# Substitute environment variables in the template
# shellcheck disable=SC2016 # envsubst's variable list, not shell expansion
envsubst '${SOCKBOWL_PUBLIC_URL} ${APP_HOST} ${APP_PROTOCOL} ${SOCKBOWL_GAME_PORT} ${KEYCLOAK_USER_USERNAME} ${KEYCLOAK_USER_EMAIL} ${KEYCLOAK_USER_FIRSTNAME} ${KEYCLOAK_USER_LASTNAME} ${KEYCLOAK_USER_PASSWORD}' \
  < /tmp/realm-export.template.json \
  > /opt/keycloak/data/import/realm-export.json

# Demo users are no longer created here. scripts/load-rbac.sh (the rbac-init
# step) is now the single source of truth for them: it reconciles the
# `demoUsers` list in keycloak/rbac-model.json when CREATE_DEMO_ACCOUNTS=true
# (creating them, assigning their RBAC tier, and setting DEMO_PASSWORD), and
# disables any existing demo users otherwise. Splitting "create the user" from
# "assign its role" across two scripts was the AUTH-06 gap (the old loader
# only ever added roles and never reconciled anything else).

echo "Keycloak realm export generated successfully!"
echo "Admin user: ${KEYCLOAK_USER_USERNAME} (${KEYCLOAK_USER_EMAIL})"
echo "Public URL: ${SOCKBOWL_PUBLIC_URL} (the sockbowl-game client redirect URIs are reconciled by rbac-init / load-rbac.sh)"
