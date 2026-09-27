#!/usr/bin/env bash
#
# load-rbac.sh: reconcile the sockbowl realm in a running Keycloak with
# keycloak/rbac-model.json.
#
# This script *reconciles*: it adds what is missing and also removes what the
# model no longer contains, so revoking a permission, rotating the backend
# secret or dropping a dev-only client takes effect on an existing realm.
# Running it twice in a row applies nothing the second time.
#
# Steps
#   1. Realm settings  PUT the keys in keycloak/realm-settings.json that differ.
#   2. Roles           create missing permission and composite roles, make each
#                      composite contain exactly the model's children, and
#                      delete permission-shaped roles (^[a-z]+:[a-z-]+$) that
#                      are not in the model (RBAC_PRUNE=true, the default).
#   3. Default role    default-roles-<realm> holds exactly the model's
#                      defaultRole plus the Keycloak built-ins offline_access
#                      and uma_authorization (client-level composites untouched).
#   4. Clients         create or update every client in the model's "clients"
#                      list from its template, reconcile protocol mappers by
#                      name, set the backend secret from SOCKBOWL_GAME_BACKEND_SECRET
#                      (rotation), and make the service account hold exactly
#                      serviceClient.roles. A client with "enabledWhen": "VAR"
#                      exists only while VAR=true and is deleted otherwise.
#   5. Demo users      CREATE_DEMO_ACCOUNTS=true: create missing demoUsers with
#                      DEMO_PASSWORD, enable them and reconcile their tier role.
#                      Otherwise disable any existing demo user (never deleted).
#   6. Every applied change prints one "CHANGE:" line; the run ends with
#      "RBAC load complete: N change(s) applied". Any unexpected HTTP status
#      exits non-zero.
#
# Templates (client files and realm settings) may reference
#   ${APP_PROTOCOL} ${APP_HOST} ${SOCKBOWL_GAME_PORT}
#   ${SOCKBOWL_AUTH_AUDIENCE} ${KC_ACCESS_TOKEN_LIFESPAN}
# They are substituted inside JSON string values with jq, so a value can never
# break the JSON. A leftover ${...} is an error.
#
# File layout: "file" entries and "realmSettings" in the model are relative to
# the model's directory. In the repo that is keycloak/; in the rbac-init
# container, mount the model, clients/ and realm-settings.json side by side
# (for example ./keycloak:/keycloak:ro with RBAC_MODEL=/keycloak/rbac-model.json).
#
# Env vars
#   KEYCLOAK_URL                  default http://localhost:8080
#   KEYCLOAK_REALM                default sockbowl
#   KEYCLOAK_ADMIN                master-realm admin username (required)
#   KEYCLOAK_ADMIN_PASSWORD       master-realm admin password (required)
#   RBAC_MODEL                    default ./keycloak/rbac-model.json
#   RBAC_PRUNE                    default true
#   RBAC_CLIENTS_DIR              directory holding the client templates (default:
#                                 <model dir>/clients, else /keycloak-clients if present)
#   SOCKBOWL_GAME_BACKEND_SECRET  backend client secret (required)
#   SOCKBOWL_E2E                  default false (true creates sockbowl-e2e)
#   CREATE_DEMO_ACCOUNTS          default false
#   DEMO_PASSWORD                 required when CREATE_DEMO_ACCOUNTS=true
#   SOCKBOWL_AUTH_AUDIENCE        default: the model's "audience" (sockbowl-api)
#   KC_ACCESS_TOKEN_LIFESPAN      default 300 (seconds, sockbowl-game and sockbowl-e2e)
#   APP_PROTOCOL / APP_HOST / SOCKBOWL_GAME_PORT   default http / localhost / 7000
#   ALLOW_INSECURE_DEFAULTS       default false (see check-secrets.sh)
#   CHECK_SECRETS_SH              default: check-secrets.sh next to this script
#
# Requires bash, curl and jq only.
#
set -euo pipefail
shopt -s inherit_errexit

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

KEYCLOAK_URL="${KEYCLOAK_URL:-http://localhost:8080}"
KEYCLOAK_REALM="${KEYCLOAK_REALM:-sockbowl}"
KEYCLOAK_ADMIN="${KEYCLOAK_ADMIN:-}"
KEYCLOAK_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:-}"
RBAC_MODEL="${RBAC_MODEL:-./keycloak/rbac-model.json}"
RBAC_PRUNE="${RBAC_PRUNE:-true}"
SOCKBOWL_GAME_BACKEND_SECRET="${SOCKBOWL_GAME_BACKEND_SECRET:-}"
SOCKBOWL_E2E="${SOCKBOWL_E2E:-false}"
CREATE_DEMO_ACCOUNTS="${CREATE_DEMO_ACCOUNTS:-false}"
DEMO_PASSWORD="${DEMO_PASSWORD:-}"
CHECK_SECRETS_SH="${CHECK_SECRETS_SH:-${SCRIPT_DIR}/check-secrets.sh}"

export APP_PROTOCOL="${APP_PROTOCOL:-http}"
export APP_HOST="${APP_HOST:-localhost}"
export SOCKBOWL_GAME_PORT="${SOCKBOWL_GAME_PORT:-7000}"
export KC_ACCESS_TOKEN_LIFESPAN="${KC_ACCESS_TOKEN_LIFESPAN:-300}"

TEMPLATE_VARS='["APP_PROTOCOL","APP_HOST","SOCKBOWL_GAME_PORT","SOCKBOWL_AUTH_AUDIENCE","KC_ACCESS_TOKEN_LIFESPAN"]'
BUILTIN_DEFAULT_ROLES='["offline_access","uma_authorization"]'
PERMISSION_ROLE_RE='^[a-z]+:[a-z-]+$'

REALM_API="${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}"
CHANGES=0

log() { echo "[load-rbac] $*"; }
fail() { echo "[load-rbac] ERROR: $*" >&2; exit 1; }
change() { CHANGES=$((CHANGES + 1)); echo "[load-rbac] CHANGE: $*"; }

require_deps() {
  command -v curl >/dev/null 2>&1 || fail "curl is required"
  command -v jq >/dev/null 2>&1 || fail "jq is required"
}

# Response bodies and the admin token live in files so that helpers called
# inside $(...) subshells share them (a refreshed token must survive the
# subshell that refreshed it).
RESP_BODY_FILE="$(mktemp)"
TOKEN_FILE="$(mktemp)"
cleanup() { rm -f "$RESP_BODY_FILE" "$TOKEN_FILE"; }
trap cleanup EXIT

url_encode() { jq -rn --arg s "$1" '$s|@uri'; }

get_admin_token() {
  [ -n "$KEYCLOAK_ADMIN" ] || fail "KEYCLOAK_ADMIN is not set"
  [ -n "$KEYCLOAK_ADMIN_PASSWORD" ] || fail "KEYCLOAK_ADMIN_PASSWORD is not set"
  local token_json
  token_json="$(curl -sf -X POST "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "grant_type=password" \
    --data-urlencode "client_id=admin-cli" \
    --data-urlencode "username=${KEYCLOAK_ADMIN}" \
    --data-urlencode "password=${KEYCLOAK_ADMIN_PASSWORD}")" || fail "failed to obtain admin token from ${KEYCLOAK_URL}"
  local token
  token="$(echo "$token_json" | jq -r '.access_token')"
  [ -n "$token" ] && [ "$token" != "null" ] || fail "admin token response did not contain access_token"
  printf '%s %s' "$(date +%s)" "$token" >"$TOKEN_FILE"
}

# http_request METHOD URL [DATA] -> prints the HTTP status; body in $RESP_BODY_FILE.
# Re-authenticates when the admin token is older than 45s (admin-cli tokens
# live 60s by default).
http_request() {
  local method="$1" url="$2" data="${3:-}"
  local issued_at token
  read -r issued_at token <"$TOKEN_FILE" || true
  if [ -z "${token:-}" ] || [ $(( $(date +%s) - ${issued_at:-0} )) -ge 45 ]; then
    get_admin_token
    read -r issued_at token <"$TOKEN_FILE"
  fi
  local -a curl_args=(-sS -o "$RESP_BODY_FILE" -w '%{http_code}' -X "$method" "$url"
    -H "Authorization: Bearer ${token}" -H "Content-Type: application/json")
  if [ -n "$data" ]; then curl_args+=(--data-binary "$data"); fi
  curl "${curl_args[@]}"
}

# api METHOD URL [DATA] EXPECTED... : fails unless the status is one of EXPECTED.
api() {
  local method="$1" url="$2" data="$3"; shift 3
  local status ok
  status="$(http_request "$method" "$url" "$data")"
  for ok in "$@"; do [ "$status" = "$ok" ] && return 0; done
  fail "unexpected status ${status} for ${method} ${url}: $(head -c 500 "$RESP_BODY_FILE")"
}

api_get() { api GET "$1" "" 200; cat "$RESP_BODY_FILE"; }

# render_template FILE: substitute TEMPLATE_VARS inside JSON strings.
render_template() {
  local file="$1" rendered
  [ -f "$file" ] || fail "template not found: ${file}"
  rendered="$(jq --argjson vars "$TEMPLATE_VARS" '
    walk(if type == "string"
         then reduce $vars[] as $v (.; split("${" + $v + "}") | join($ENV[$v] // ""))
         else . end)' "$file")" || fail "invalid JSON in ${file}"
  # shellcheck disable=SC2016 # literal ${ on purpose
  if echo "$rendered" | grep -q '\${'; then
    fail "unresolved \${...} placeholder in ${file}: $(echo "$rendered" | grep -o '\${[^}]*}' | sort -u | tr '\n' ' ')"
  fi
  echo "$rendered"
}

# jq helper: is the desired value (input) contained in $cur? Objects compare
# key by key (extra keys in $cur are fine), arrays compare as sets, scalars
# compare by value.
# shellcheck disable=SC2016 # jq program, not shell
JQ_SUBSET='def subset($cur):
  if type == "object" then
    (($cur | type) == "object") and (to_entries | all(.key as $k | .value | subset($cur[$k])))
  elif type == "array" then
    (($cur | type) == "array") and ((map(tojson) | sort) == ($cur | map(tojson) | sort))
  else . == $cur end;'

role_json() { api_get "${REALM_API}/roles/$(url_encode "$1")"; }

roles_json_array() {
  # roles_json_array NAME... -> JSON array of role representations
  local out="[]" name
  for name in "$@"; do
    out="$(jq -c --argjson r "$(role_json "$name")" '. + [$r]' <<<"$out")"
  done
  echo "$out"
}

# Client template path. "file" entries are relative to the model directory
# unless RBAC_CLIENTS_DIR is set, in which case the file's basename is looked
# up there (for containers that mount keycloak/clients elsewhere).
client_file() {
  if [ -n "${RBAC_CLIENTS_DIR:-}" ]; then echo "${RBAC_CLIENTS_DIR}/$(basename "$1")"; else echo "${RBAC_DIR}/$1"; fi
}

# ---------------------------------------------------------------- 1. realm

reconcile_realm_settings() {
  local rel file desired current diff
  rel="$(jq -r '.realmSettings // empty' "$RBAC_MODEL")"
  if [ -z "$rel" ]; then log "no realmSettings in model; skipping realm settings"; return 0; fi
  file="${RBAC_DIR}/${rel}"
  desired="$(render_template "$file")"
  current="$(api_get "${REALM_API}")"
  diff="$(jq -c --argjson cur "$current" "${JQ_SUBSET}"'
    with_entries(select(.value as $v | .key as $k | ($v | subset($cur[$k])) | not))' <<<"$desired")"
  if [ "$diff" = "{}" ]; then
    log "realm settings up to date"
  else
    api PUT "${REALM_API}" "$diff" 204 200
    change "realm settings updated: $(jq -c 'keys' <<<"$diff")"
  fi
}

# ---------------------------------------------------------------- 2. roles

existing_realm_role_names() {
  api_get "${REALM_API}/roles?first=0&max=10000&briefRepresentation=true" | jq -r '.[].name'
}

ensure_role() {
  local name="$1"
  local status
  status="$(http_request GET "${REALM_API}/roles/$(url_encode "$name")")"
  case "$status" in
    200) return 0 ;;
    404)
      api POST "${REALM_API}/roles" "$(jq -nc --arg n "$name" '{name: $n}')" 201 409
      change "role created: ${name}" ;;
    *) fail "unexpected status ${status} looking up role '${name}': $(cat "$RESP_BODY_FILE")" ;;
  esac
}

# reconcile_role_set CURRENT_URL MUTATE_URL DESIRED_JSON_ARRAY LABEL
# Makes the realm roles listed at CURRENT_URL equal DESIRED (by name), POSTing
# missing ones and DELETEing extras against MUTATE_URL.
reconcile_role_set() {
  local current_url="$1" mutate_url="$2" desired="$3" label="$4"
  local current missing extra
  current="$(api_get "$current_url" | jq -c '[.[].name]')"
  missing="$(jq -c --argjson cur "$current" '. - $cur' <<<"$desired")"
  extra="$(jq -c --argjson want "$desired" '. - $want' <<<"$current")"
  if [ "$missing" != "[]" ]; then
    local -a names=()
    mapfile -t names < <(jq -r '.[]' <<<"$missing")
    api POST "$mutate_url" "$(roles_json_array "${names[@]}")" 204 200
    change "${label}: added $(jq -c . <<<"$missing")"
  fi
  if [ "$extra" != "[]" ]; then
    local -a names=()
    mapfile -t names < <(jq -r '.[]' <<<"$extra")
    api DELETE "$mutate_url" "$(roles_json_array "${names[@]}")" 204 200
    change "${label}: removed $(jq -c . <<<"$extra")"
  fi
}

reconcile_roles() {
  local name
  while IFS= read -r name; do ensure_role "$name"; done < <(jq -r '.permissionRoles[]' "$RBAC_MODEL")
  while IFS= read -r name; do ensure_role "$name"; done < <(jq -r '.compositeRoles | keys[]' "$RBAC_MODEL")

  while IFS= read -r name; do
    local enc desired
    enc="$(url_encode "$name")"
    desired="$(jq -c --arg k "$name" '.compositeRoles[$k] | unique' "$RBAC_MODEL")"
    reconcile_role_set "${REALM_API}/roles/${enc}/composites/realm" "${REALM_API}/roles/${enc}/composites" \
      "$desired" "composite ${name}"
  done < <(jq -r '.compositeRoles | keys[]' "$RBAC_MODEL")

  if [ "$RBAC_PRUNE" = "true" ]; then
    local known existing
    known="$(jq -c '.permissionRoles' "$RBAC_MODEL")"
    existing="$(existing_realm_role_names)"
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      if [[ "$name" =~ $PERMISSION_ROLE_RE ]] && ! jq -e --arg n "$name" 'index($n) != null' <<<"$known" >/dev/null; then
        api DELETE "${REALM_API}/roles/$(url_encode "$name")" "" 204
        change "stray permission role deleted: ${name}"
      fi
    done <<<"$existing"
  fi
}

# ---------------------------------------------------------- 3. default role

reconcile_default_role() {
  local default_roles_id desired
  default_roles_id="$(role_json "default-roles-${KEYCLOAK_REALM}" | jq -r '.id')"
  [ -n "$default_roles_id" ] && [ "$default_roles_id" != "null" ] || fail "could not resolve default-roles-${KEYCLOAK_REALM}"
  desired="$(jq -c --argjson b "$BUILTIN_DEFAULT_ROLES" '[.defaultRole] + $b | unique' "$RBAC_MODEL")"
  reconcile_role_set "${REALM_API}/roles-by-id/${default_roles_id}/composites/realm" \
    "${REALM_API}/roles-by-id/${default_roles_id}/composites" "$desired" "default-roles-${KEYCLOAK_REALM}"
}

# -------------------------------------------------------------- 4. clients

find_client_uuid() {
  api_get "${REALM_API}/clients?clientId=$(url_encode "$1")" | jq -r --arg c "$1" '[.[] | select(.clientId == $c)][0].id // empty'
}

reconcile_mappers() {
  local client_id="$1" uuid="$2" desired="$3"
  local current name want have
  current="$(api_get "${REALM_API}/clients/${uuid}/protocol-mappers/models")"
  while IFS= read -r name; do
    want="$(jq -c --arg n "$name" '.[] | select(.name == $n)' <<<"$desired")"
    have="$(jq -c --arg n "$name" '[.[] | select(.name == $n)][0] // empty' <<<"$current")"
    if [ -z "$have" ]; then
      api POST "${REALM_API}/clients/${uuid}/protocol-mappers/models" "$want" 201
      change "client ${client_id}: mapper added: ${name}"
    elif ! jq -e --argjson cur "$have" "${JQ_SUBSET}"'subset($cur)' <<<"$want" >/dev/null; then
      local mid
      mid="$(jq -r '.id' <<<"$have")"
      if [ "$(jq -r '.protocolMapper' <<<"$have")" != "$(jq -r '.protocolMapper' <<<"$want")" ]; then
        # The mapper type cannot change in place: recreate it.
        api DELETE "${REALM_API}/clients/${uuid}/protocol-mappers/models/${mid}" "" 204
        api POST "${REALM_API}/clients/${uuid}/protocol-mappers/models" "$want" 201
      else
        api PUT "${REALM_API}/clients/${uuid}/protocol-mappers/models/${mid}" \
          "$(jq -c --arg id "$mid" '. + {id: $id}' <<<"$want")" 204
      fi
      change "client ${client_id}: mapper updated: ${name}"
    fi
  done < <(jq -r '.[].name' <<<"$desired")

  # Remove mappers the template does not declare.
  while IFS=$'\t' read -r mid name; do
    [ -n "$mid" ] || continue
    api DELETE "${REALM_API}/clients/${uuid}/protocol-mappers/models/${mid}" "" 204
    change "client ${client_id}: mapper removed: ${name}"
  done < <(jq -r --argjson want "$desired" '.[] | select(.name as $n | ($want | map(.name) | index($n)) == null) | [.id, .name] | @tsv' <<<"$current")
}

reconcile_client_secret() {
  local client_id="$1" uuid="$2" secret="$3"
  local current_secret
  current_secret="$(api_get "${REALM_API}/clients/${uuid}/client-secret" | jq -r '.value // empty')"
  if [ "$current_secret" != "$secret" ]; then
    local rep
    rep="$(api_get "${REALM_API}/clients/${uuid}")"
    api PUT "${REALM_API}/clients/${uuid}" "$(jq -c --arg s "$secret" '.secret = $s' <<<"$rep")" 204
    change "client ${client_id}: secret rotated"
  fi
}

reconcile_service_account_roles() {
  local client_id="$1" uuid="$2" desired="$3"
  local sa_id
  sa_id="$(api_get "${REALM_API}/clients/${uuid}/service-account-user" | jq -r '.id')"
  [ -n "$sa_id" ] && [ "$sa_id" != "null" ] || fail "service-account user missing for '${client_id}'"
  reconcile_role_set "${REALM_API}/users/${sa_id}/role-mappings/realm" "${REALM_API}/users/${sa_id}/role-mappings/realm" \
    "$desired" "service account ${client_id} roles"
}

reconcile_client() {
  local entry="$1"
  local client_id file enabled_when secret_env desired uuid
  client_id="$(jq -r '.clientId' <<<"$entry")"
  file="$(client_file "$(jq -r '.file' <<<"$entry")")"
  enabled_when="$(jq -r '.enabledWhen // empty' <<<"$entry")"
  secret_env="$(jq -r '.secretEnv // empty' <<<"$entry")"
  uuid="$(find_client_uuid "$client_id")"

  if [ -n "$enabled_when" ] && [ "${!enabled_when:-false}" != "true" ]; then
    if [ -n "$uuid" ]; then
      api DELETE "${REALM_API}/clients/${uuid}" "" 204
      change "client deleted: ${client_id} (${enabled_when} is not true)"
    else
      log "client ${client_id} absent (${enabled_when} is not true)"
    fi
    return 0
  fi

  desired="$(render_template "$file")"
  [ "$(jq -r '.clientId' <<<"$desired")" = "$client_id" ] || fail "${file} does not declare clientId ${client_id}"
  local secret=""
  if [ -n "$secret_env" ]; then
    secret="${!secret_env:-}"
    [ -n "$secret" ] || fail "${secret_env} is not set; required for client '${client_id}'"
  fi
  local mappers settings
  mappers="$(jq -c '.protocolMappers // []' <<<"$desired")"
  settings="$(jq -c 'del(.protocolMappers)' <<<"$desired")"

  if [ -z "$uuid" ]; then
    local payload="$desired"
    [ -z "$secret" ] || payload="$(jq -c --arg s "$secret" '.secret = $s' <<<"$payload")"
    api POST "${REALM_API}/clients" "$payload" 201
    change "client created: ${client_id}"
    uuid="$(find_client_uuid "$client_id")"
    [ -n "$uuid" ] || fail "client ${client_id} not found after creation"
  else
    local current
    current="$(api_get "${REALM_API}/clients/${uuid}")"
    if ! jq -e --argjson cur "$current" "${JQ_SUBSET}"'subset($cur)' <<<"$settings" >/dev/null; then
      local drift
      drift="$(jq -c --argjson cur "$current" "${JQ_SUBSET}"'[to_entries[] | select(.value as $v | .key as $k | ($v | subset($cur[$k])) | not) | .key]' <<<"$settings")"
      api PUT "${REALM_API}/clients/${uuid}" "$(jq -c --argjson d "$settings" '(. * $d) | del(.protocolMappers)' <<<"$current")" 204
      change "client updated: ${client_id} ${drift}"
    fi
  fi

  reconcile_mappers "$client_id" "$uuid" "$mappers"
  [ -z "$secret" ] || reconcile_client_secret "$client_id" "$uuid" "$secret"

  if [ "$(jq -r '.serviceClient.clientId // empty' "$RBAC_MODEL")" = "$client_id" ]; then
    reconcile_service_account_roles "$client_id" "$uuid" "$(jq -c '.serviceClient.roles | unique' "$RBAC_MODEL")"
  fi
}

reconcile_clients() {
  local entry
  while IFS= read -r entry; do
    reconcile_client "$entry"
  done < <(jq -c '.clients[]' "$RBAC_MODEL")
}

# ----------------------------------------------------------- 5. demo users

find_user() {
  api_get "${REALM_API}/users?username=$(url_encode "$1")&exact=true" | jq -c --arg u "$1" '[.[] | select(.username == $u)][0] // empty'
}

set_user_enabled() {
  local user_id="$1" enabled="$2"
  local rep
  rep="$(api_get "${REALM_API}/users/${user_id}")"
  api PUT "${REALM_API}/users/${user_id}" "$(jq -c --argjson e "$enabled" '.enabled = $e' <<<"$rep")" 204
}

reconcile_demo_users() {
  local tiers
  tiers="$(jq -c '.compositeRoles | keys' "$RBAC_MODEL")"
  local du username tier user user_id
  while IFS= read -r du; do
    username="$(jq -r '.username' <<<"$du")"
    tier="$(jq -r '.tier' <<<"$du")"
    user="$(find_user "$username")"

    if [ "$CREATE_DEMO_ACCOUNTS" != "true" ]; then
      if [ -n "$user" ] && [ "$(jq -r '.enabled' <<<"$user")" = "true" ]; then
        set_user_enabled "$(jq -r '.id' <<<"$user")" false
        change "demo user disabled: ${username} (CREATE_DEMO_ACCOUNTS is not true)"
      fi
      continue
    fi

    if [ -z "$user" ]; then
      [ -n "$DEMO_PASSWORD" ] || fail "DEMO_PASSWORD is not set; required when CREATE_DEMO_ACCOUNTS=true"
      api POST "${REALM_API}/users" "$(jq -c --arg p "$DEMO_PASSWORD" '{
          username, email, firstName, lastName, enabled: true, emailVerified: true,
          credentials: [{type: "password", value: $p, temporary: false}]}' <<<"$du")" 201
      change "demo user created: ${username}"
      user="$(find_user "$username")"
      [ -n "$user" ] || fail "demo user ${username} not found after creation"
    elif [ "$(jq -r '.enabled' <<<"$user")" != "true" ]; then
      set_user_enabled "$(jq -r '.id' <<<"$user")" true
      change "demo user enabled: ${username}"
    fi
    user_id="$(jq -r '.id' <<<"$user")"

    # Tier: exactly one direct tier (composite) role; other direct roles stay.
    local direct desired
    direct="$(api_get "${REALM_API}/users/${user_id}/role-mappings/realm" | jq -c '[.[].name]')"
    desired="$(jq -c --argjson tiers "$tiers" --arg t "$tier" '(. - $tiers) + [$t] | unique' <<<"$direct")"
    reconcile_role_set "${REALM_API}/users/${user_id}/role-mappings/realm" "${REALM_API}/users/${user_id}/role-mappings/realm" \
      "$desired" "demo user ${username} roles"
  done < <(jq -c '.demoUsers // [] | .[]' "$RBAC_MODEL")
}

# ------------------------------------------------------------------- main

main() {
  require_deps
  [ -f "$RBAC_MODEL" ] || fail "RBAC model file not found: ${RBAC_MODEL}"
  RBAC_DIR="$(cd "$(dirname "$RBAC_MODEL")" && pwd)"
  if [ -z "${RBAC_CLIENTS_DIR:-}" ] && [ ! -d "${RBAC_DIR}/clients" ] && [ -d /keycloak-clients ]; then
    RBAC_CLIENTS_DIR=/keycloak-clients
  fi
  export SOCKBOWL_AUTH_AUDIENCE="${SOCKBOWL_AUTH_AUDIENCE:-$(jq -r '.audience // "sockbowl-api"' "$RBAC_MODEL")}"

  [ -f "$CHECK_SECRETS_SH" ] || fail "check-secrets.sh not found at ${CHECK_SECRETS_SH} (mount it next to load-rbac.sh or set CHECK_SECRETS_SH)"
  # shellcheck source-path=SCRIPTDIR source=check-secrets.sh
  . "$CHECK_SECRETS_SH"
  [ -n "$SOCKBOWL_GAME_BACKEND_SECRET" ] || fail "SOCKBOWL_GAME_BACKEND_SECRET is not set"

  log "Reconciling realm '${KEYCLOAK_REALM}' at ${KEYCLOAK_URL} with ${RBAC_MODEL} (SOCKBOWL_E2E=${SOCKBOWL_E2E}, CREATE_DEMO_ACCOUNTS=${CREATE_DEMO_ACCOUNTS}, RBAC_PRUNE=${RBAC_PRUNE})"
  get_admin_token

  log "1/5 realm settings";   reconcile_realm_settings
  log "2/5 roles";            reconcile_roles
  log "3/5 default role";     reconcile_default_role
  log "4/5 clients";          reconcile_clients
  log "5/5 demo users";       reconcile_demo_users

  log "RBAC load complete: ${CHANGES} change(s) applied"
}

main "$@"
