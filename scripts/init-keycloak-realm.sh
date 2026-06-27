#!/bin/sh
set -e

# Install required packages
apk add --no-cache gettext

echo "Generating Keycloak realm export from template..."

# Default values if environment variables are not set
export APP_HOST="${APP_HOST:-localhost}"
export APP_PROTOCOL="${APP_PROTOCOL:-http}"
export SOCKBOWL_GAME_PORT="${SOCKBOWL_GAME_PORT:-7000}"
export KEYCLOAK_USER_USERNAME="${KEYCLOAK_USER_USERNAME:-admin}"
export KEYCLOAK_USER_EMAIL="${KEYCLOAK_USER_EMAIL:-admin@sockbowl.com}"
export KEYCLOAK_USER_FIRSTNAME="${KEYCLOAK_USER_FIRSTNAME:-Admin}"
export KEYCLOAK_USER_LASTNAME="${KEYCLOAK_USER_LASTNAME:-User}"
export KEYCLOAK_USER_PASSWORD="${KEYCLOAK_USER_PASSWORD:-admin123}"
export CREATE_DEMO_ACCOUNTS="${CREATE_DEMO_ACCOUNTS:-false}"

# Substitute environment variables in the template
envsubst '${APP_HOST} ${APP_PROTOCOL} ${SOCKBOWL_GAME_PORT} ${KEYCLOAK_USER_USERNAME} ${KEYCLOAK_USER_EMAIL} ${KEYCLOAK_USER_FIRSTNAME} ${KEYCLOAK_USER_LASTNAME} ${KEYCLOAK_USER_PASSWORD}' \
  < /tmp/realm-export.template.json \
  > /opt/keycloak/data/import/realm-export.json

# Add demo accounts if CREATE_DEMO_ACCOUNTS is set to true
if [ "$CREATE_DEMO_ACCOUNTS" = "true" ]; then
  echo "Creating demo accounts..."

  # Install jq for JSON manipulation
  apk add --no-cache jq

  # Define demo users
  DEMO_USERS='[
    {
      "username": "player1",
      "enabled": true,
      "email": "player1@sockbowl.com",
      "firstName": "Player",
      "lastName": "One",
      "emailVerified": true,
      "realmRoles": ["user"],
      "credentials": [
        {
          "type": "password",
          "value": "demo123",
          "temporary": false
        }
      ]
    },
    {
      "username": "player2",
      "enabled": true,
      "email": "player2@sockbowl.com",
      "firstName": "Player",
      "lastName": "Two",
      "emailVerified": true,
      "realmRoles": ["user"],
      "credentials": [
        {
          "type": "password",
          "value": "demo123",
          "temporary": false
        }
      ]
    },
    {
      "username": "player3",
      "enabled": true,
      "email": "player3@sockbowl.com",
      "firstName": "Player",
      "lastName": "Three",
      "emailVerified": true,
      "realmRoles": ["user"],
      "credentials": [
        {
          "type": "password",
          "value": "demo123",
          "temporary": false
        }
      ]
    },
    {
      "username": "testuser",
      "enabled": true,
      "email": "testuser@sockbowl.com",
      "firstName": "Test",
      "lastName": "User",
      "emailVerified": true,
      "realmRoles": ["user"],
      "credentials": [
        {
          "type": "password",
          "value": "demo123",
          "temporary": false
        }
      ]
    },
    {
      "username": "moderator",
      "enabled": true,
      "email": "moderator@sockbowl.com",
      "firstName": "Mod",
      "lastName": "Erator",
      "emailVerified": true,
      "realmRoles": ["user", "admin"],
      "credentials": [
        {
          "type": "password",
          "value": "demo123",
          "temporary": false
        }
      ]
    }
  ]'

  # Add demo users to the realm export
  jq --argjson demo_users "$DEMO_USERS" '.users += $demo_users' \
    /opt/keycloak/data/import/realm-export.json > /tmp/realm-export-with-demo.json

  mv /tmp/realm-export-with-demo.json /opt/keycloak/data/import/realm-export.json

  echo "Demo accounts created:"
  echo "  - player1 / demo123       (user)"
  echo "  - player2 / demo123       (user)"
  echo "  - player3 / demo123       (user)"
  echo "  - testuser / demo123      (user)"
  echo "  - moderator / demo123     (user + admin -> can manage bans)"
fi

echo "Keycloak realm export generated successfully!"
echo "Admin user: ${KEYCLOAK_USER_USERNAME} (${KEYCLOAK_USER_EMAIL})"
echo "Redirect URIs configured for: ${APP_PROTOCOL}://${APP_HOST}"
