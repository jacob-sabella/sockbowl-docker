#!/usr/bin/env bash
#
# load-rbac.sh — idempotently provision the sockbowl RBAC model into Keycloak.
#
# Reads keycloak/rbac-model.json (permission roles + composite roles +
# default role + service client) and upserts it into a running Keycloak
# realm via the Admin REST API. Safe to re-run: every create is guarded
# against "already exists" (HTTP 409) and every composite/role-mapping
# update is naturally idempotent on Keycloak's side.
#
# Env vars (all optional except the admin password / service secret):
#   KEYCLOAK_URL                 default: http://localhost:8080
#   KEYCLOAK_REALM                default: sockbowl
#   KEYCLOAK_ADMIN                 admin username (master realm)
#   KEYCLOAK_ADMIN_PASSWORD        admin password (master realm)
#   RBAC_MODEL                    default: ./keycloak/rbac-model.json
#   SOCKBOWL_GAME_BACKEND_SECRET   client secret for the service client
#
set -euo pipefail

KEYCLOAK_URL="${KEYCLOAK_URL:-http://localhost:8080}"
KEYCLOAK_REALM="${KEYCLOAK_REALM:-sockbowl}"
KEYCLOAK_ADMIN="${KEYCLOAK_ADMIN:-}"
KEYCLOAK_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:-}"
RBAC_MODEL="${RBAC_MODEL:-./keycloak/rbac-model.json}"
SOCKBOWL_GAME_BACKEND_SECRET="${SOCKBOWL_GAME_BACKEND_SECRET:-}"

REALM_API="${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}"

log() {
  echo "[load-rbac] $*"
}

fail() {
  echo "[load-rbac] ERROR: $*" >&2
  exit 1
}

require_deps() {
  command -v curl >/dev/null 2>&1 || fail "curl is required"
  command -v jq >/dev/null 2>&1 || fail "jq is required"
}

# GET/POST/DELETE wrappers that return the HTTP status code on stdout via -w,
# writing the response body to a temp file so callers can inspect it.
RESP_BODY_FILE="$(mktemp)"
cleanup() { rm -f "$RESP_BODY_FILE"; }
trap cleanup EXIT

http_request() {
  # http_request METHOD URL [DATA]
  local method="$1" url="$2" data="${3:-}"
  local -a curl_args=(-sS -o "$RESP_BODY_FILE" -w '%{http_code}' -X "$method" "$url" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    -H "Content-Type: application/json")
  if [ -n "$data" ]; then
    curl_args+=(-d "$data")
  fi
  curl "${curl_args[@]}"
}

get_admin_token() {
  log "Authenticating to master realm as ${KEYCLOAK_ADMIN}..."
  [ -n "$KEYCLOAK_ADMIN" ] || fail "KEYCLOAK_ADMIN is not set"
  [ -n "$KEYCLOAK_ADMIN_PASSWORD" ] || fail "KEYCLOAK_ADMIN_PASSWORD is not set"

  local token_json
  token_json="$(curl -sf -X POST "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=password" \
    -d "client_id=admin-cli" \
    -d "username=${KEYCLOAK_ADMIN}" \
    -d "password=${KEYCLOAK_ADMIN_PASSWORD}")" || fail "failed to obtain admin token from ${KEYCLOAK_URL}"

  ADMIN_TOKEN="$(echo "$token_json" | jq -r '.access_token')"
  [ -n "$ADMIN_TOKEN" ] && [ "$ADMIN_TOKEN" != "null" ] || fail "admin token response did not contain access_token"
  log "Authenticated."
}

# Create a realm role by name. Tolerates HTTP 409 (already exists).
create_role() {
  local name="$1"
  local status
  status="$(http_request POST "${REALM_API}/roles" "$(jq -n --arg name "$name" '{name: $name}')")"
  case "$status" in
    201) log "role created: ${name}" ;;
    409) log "role already exists: ${name}" ;;
    *) fail "unexpected status ${status} creating role '${name}': $(cat "$RESP_BODY_FILE")" ;;
  esac
}

# Fetch a realm role representation by name.
get_role() {
  local name="$1"
  local status
  status="$(http_request GET "${REALM_API}/roles/$(url_encode "$name")")"
  [ "$status" = "200" ] || fail "failed to fetch role '${name}' (status ${status}): $(cat "$RESP_BODY_FILE")"
  cat "$RESP_BODY_FILE"
}

url_encode() {
  jq -rn --arg s "$1" '$s|@uri'
}

# Attach child roles as composites of a parent realm role. Idempotent.
set_composites() {
  local parent="$1"; shift
  local children=("$@")
  local children_json="[]"
  local child
  for child in "${children[@]}"; do
    children_json="$(echo "$children_json" | jq --argjson r "$(get_role "$child")" '. + [$r]')"
  done

  local status
  status="$(http_request POST "${REALM_API}/roles/$(url_encode "$parent")/composites" "$children_json")"
  case "$status" in
    204|200) log "composite set: ${parent} -> [${children[*]}]" ;;
    *) fail "unexpected status ${status} setting composites for '${parent}': $(cat "$RESP_BODY_FILE")" ;;
  esac
}

# Set the realm's default role (default-roles-$REALM composite) to include
# the given role name.
set_default_role() {
  local default_role_name="$1"
  local default_roles_role
  default_roles_role="$(get_role "default-roles-${KEYCLOAK_REALM}")"
  local default_roles_id
  default_roles_id="$(echo "$default_roles_role" | jq -r '.id')"
  [ -n "$default_roles_id" ] && [ "$default_roles_id" != "null" ] || fail "could not resolve id of default-roles-${KEYCLOAK_REALM}"

  local child_role
  child_role="$(get_role "$default_role_name")"

  local status
  status="$(http_request POST "${REALM_API}/roles-by-id/${default_roles_id}/composites" "[$child_role]")"
  case "$status" in
    204|200) log "default role set: default-roles-${KEYCLOAK_REALM} -> ${default_role_name}" ;;
    *) fail "unexpected status ${status} setting default role: $(cat "$RESP_BODY_FILE")" ;;
  esac
}

# Ensure the service client exists (creating it with a service account if
# absent), then assign it the given realm roles via its service-account user.
ensure_service_client() {
  local client_id="$1"; shift
  local roles=("$@")

  local status
  status="$(http_request GET "${REALM_API}/clients?clientId=$(url_encode "$client_id")")"
  [ "$status" = "200" ] || fail "failed to look up client '${client_id}' (status ${status}): $(cat "$RESP_BODY_FILE")"

  local existing_id
  existing_id="$(jq -r '.[0].id // empty' "$RESP_BODY_FILE")"

  local client_uuid
  if [ -n "$existing_id" ]; then
    log "service client already exists: ${client_id}"
    client_uuid="$existing_id"
  else
    [ -n "$SOCKBOWL_GAME_BACKEND_SECRET" ] || fail "SOCKBOWL_GAME_BACKEND_SECRET is not set; required to create '${client_id}'"
    local payload
    payload="$(jq -n --arg cid "$client_id" --arg secret "$SOCKBOWL_GAME_BACKEND_SECRET" '{
      clientId: $cid,
      serviceAccountsEnabled: true,
      standardFlowEnabled: false,
      publicClient: false,
      secret: $secret
    }')"
    status="$(http_request POST "${REALM_API}/clients" "$payload")"
    case "$status" in
      201) log "service client created: ${client_id}" ;;
      409) log "service client already exists (race): ${client_id}" ;;
      *) fail "unexpected status ${status} creating client '${client_id}': $(cat "$RESP_BODY_FILE")" ;;
    esac

    status="$(http_request GET "${REALM_API}/clients?clientId=$(url_encode "$client_id")")"
    [ "$status" = "200" ] || fail "failed to re-look-up client '${client_id}' after creation"
    client_uuid="$(jq -r '.[0].id // empty' "$RESP_BODY_FILE")"
    [ -n "$client_uuid" ] || fail "could not resolve id of client '${client_id}' after creation"
  fi

  status="$(http_request GET "${REALM_API}/clients/${client_uuid}/service-account-user")"
  [ "$status" = "200" ] || fail "failed to fetch service-account user for '${client_id}' (status ${status}): $(cat "$RESP_BODY_FILE")"
  local sa_user_id
  sa_user_id="$(jq -r '.id' "$RESP_BODY_FILE")"
  [ -n "$sa_user_id" ] && [ "$sa_user_id" != "null" ] || fail "service-account user id missing for '${client_id}'"

  local role
  for role in "${roles[@]}"; do
    local role_json
    role_json="$(get_role "$role")"
    status="$(http_request POST "${REALM_API}/users/${sa_user_id}/role-mappings/realm" "[$role_json]")"
    case "$status" in
      204|200) log "role assigned to service account: ${client_id} -> ${role}" ;;
      409) log "role already assigned to service account: ${client_id} -> ${role}" ;;
      *) fail "unexpected status ${status} assigning role '${role}' to '${client_id}' service account: $(cat "$RESP_BODY_FILE")" ;;
    esac
  done
}

# Look up a user by exact username. Prints the user's id on stdout, or
# nothing if the user does not exist (e.g. CREATE_DEMO_ACCOUNTS=false).
find_user_id_by_username() {
  local username="$1"
  local status
  status="$(http_request GET "${REALM_API}/users?username=$(url_encode "$username")&exact=true")"
  [ "$status" = "200" ] || fail "failed to look up user '${username}' (status ${status}): $(cat "$RESP_BODY_FILE")"
  jq -r '.[0].id // empty' "$RESP_BODY_FILE"
}

# Assign a single realm role to a user by id. Tolerates HTTP 409 (already assigned).
assign_realm_role_to_user() {
  local user_id="$1" role_name="$2"
  local role_json
  role_json="$(get_role "$role_name")"
  local status
  status="$(http_request POST "${REALM_API}/users/${user_id}/role-mappings/realm" "[$role_json]")"
  case "$status" in
    204|200) log "role assigned to user: ${role_name}" ;;
    409) log "role already assigned to user: ${role_name}" ;;
    *) fail "unexpected status ${status} assigning role '${role_name}' to user id '${user_id}': $(cat "$RESP_BODY_FILE")" ;;
  esac
}

# Assign each demoUserRoles entry (username -> composite role name) from the
# RBAC model. Skips gracefully (no error) when the demo user doesn't exist,
# e.g. because CREATE_DEMO_ACCOUNTS=false. Idempotent.
assign_demo_user_roles() {
  local has_demo_roles
  has_demo_roles="$(jq -r 'has("demoUserRoles")' "$RBAC_MODEL")"
  [ "$has_demo_roles" = "true" ] || { log "No demoUserRoles in RBAC model; skipping."; return 0; }

  local username role_name user_id
  while IFS=$'\t' read -r username role_name; do
    [ -n "$username" ] || continue
    user_id="$(find_user_id_by_username "$username")"
    if [ -z "$user_id" ]; then
      log "demo user not found, skipping role assignment: ${username} -> ${role_name} (demo accounts likely disabled)"
      continue
    fi
    assign_realm_role_to_user "$user_id" "$role_name"
    log "demo user role assignment complete: ${username} -> ${role_name}"
  done < <(jq -r '.demoUserRoles | to_entries[] | [.key, .value] | @tsv' "$RBAC_MODEL")
}

main() {
  require_deps
  [ -f "$RBAC_MODEL" ] || fail "RBAC model file not found: ${RBAC_MODEL}"

  log "Loading RBAC model from ${RBAC_MODEL} into realm '${KEYCLOAK_REALM}' at ${KEYCLOAK_URL}"

  get_admin_token

  log "Creating permission roles..."
  local perm_role
  while IFS= read -r perm_role; do
    create_role "$perm_role"
  done < <(jq -r '.permissionRoles[]' "$RBAC_MODEL")

  log "Creating composite roles..."
  local composite_name
  while IFS= read -r composite_name; do
    create_role "$composite_name"
  done < <(jq -r '.compositeRoles | keys[]' "$RBAC_MODEL")

  log "Wiring composite role membership..."
  while IFS= read -r composite_name; do
    local children=()
    local child
    while IFS= read -r child; do
      children+=("$child")
    done < <(jq -r --arg k "$composite_name" '.compositeRoles[$k][]' "$RBAC_MODEL")
    set_composites "$composite_name" "${children[@]}"
  done < <(jq -r '.compositeRoles | keys[]' "$RBAC_MODEL")

  log "Setting realm default role..."
  local default_role
  default_role="$(jq -r '.defaultRole' "$RBAC_MODEL")"
  set_default_role "$default_role"

  log "Ensuring service client..."
  local service_client_id
  service_client_id="$(jq -r '.serviceClient.clientId' "$RBAC_MODEL")"
  local service_roles=()
  local sr
  while IFS= read -r sr; do
    service_roles+=("$sr")
  done < <(jq -r '.serviceClient.roles[]' "$RBAC_MODEL")
  ensure_service_client "$service_client_id" "${service_roles[@]}"

  log "Assigning demo user roles..."
  assign_demo_user_roles

  log "RBAC load complete"
}

main "$@"
