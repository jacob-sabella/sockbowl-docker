#!/usr/bin/env bash
#
# verify-rbac.sh: diff a live Keycloak realm against keycloak/rbac-model.json
# and exit non-zero on any drift. Read-only.
#
# Checks: realm settings, permission roles (missing and stray), composite
# membership, the default role, every model client (presence, flags,
# attributes, protocol mappers, backend secret, service-account roles) and the
# demo-user state. It is written independently of load-rbac.sh on purpose, so
# a bug in the loader's comparison logic does not hide itself.
#
# Takes the same env vars as load-rbac.sh (KEYCLOAK_URL, KEYCLOAK_REALM,
# KEYCLOAK_ADMIN, KEYCLOAK_ADMIN_PASSWORD, RBAC_MODEL, SOCKBOWL_E2E,
# CREATE_DEMO_ACCOUNTS, SOCKBOWL_GAME_BACKEND_SECRET, template vars). The
# backend secret is compared only when SOCKBOWL_GAME_BACKEND_SECRET is set.
#
# Requires bash, curl and jq.
#
set -euo pipefail
shopt -s inherit_errexit

KEYCLOAK_URL="${KEYCLOAK_URL:-http://localhost:8080}"
KEYCLOAK_REALM="${KEYCLOAK_REALM:-sockbowl}"
KEYCLOAK_ADMIN="${KEYCLOAK_ADMIN:-}"
KEYCLOAK_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:-}"
RBAC_MODEL="${RBAC_MODEL:-./keycloak/rbac-model.json}"
SOCKBOWL_E2E="${SOCKBOWL_E2E:-false}"
CREATE_DEMO_ACCOUNTS="${CREATE_DEMO_ACCOUNTS:-false}"
export APP_PROTOCOL="${APP_PROTOCOL:-http}"
export APP_HOST="${APP_HOST:-localhost}"
export SOCKBOWL_GAME_PORT="${SOCKBOWL_GAME_PORT:-7000}"
export KC_ACCESS_TOKEN_LIFESPAN="${KC_ACCESS_TOKEN_LIFESPAN:-300}"
export SOCKBOWL_PUBLIC_URL="${SOCKBOWL_PUBLIC_URL:-${APP_PROTOCOL}://${APP_HOST}}"
SOCKBOWL_EXTRA_REDIRECT_ORIGINS="${SOCKBOWL_EXTRA_REDIRECT_ORIGINS:-}"
TEMPLATE_VARS='["SOCKBOWL_PUBLIC_URL","APP_PROTOCOL","APP_HOST","SOCKBOWL_GAME_PORT","SOCKBOWL_AUTH_AUDIENCE","KC_ACCESS_TOKEN_LIFESPAN"]'

API="${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}"
DRIFT=0
TOKEN_FILE="$(mktemp)"
trap 'rm -f "$TOKEN_FILE"' EXIT

fail() { echo "[verify-rbac] ERROR: $*" >&2; exit 2; }
drift() { DRIFT=$((DRIFT + 1)); echo "[verify-rbac] DRIFT: $*"; }
ok() { echo "[verify-rbac] ok: $*"; }
enc() { jq -rn --arg s "$1" '$s|@uri'; }

token() {
  local at tok
  read -r at tok <"$TOKEN_FILE" 2>/dev/null || true
  if [ -z "${tok:-}" ] || [ $(( $(date +%s) - ${at:-0} )) -ge 45 ]; then
    tok="$(curl -sf -X POST "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
      --data-urlencode grant_type=password --data-urlencode client_id=admin-cli \
      --data-urlencode "username=${KEYCLOAK_ADMIN}" --data-urlencode "password=${KEYCLOAK_ADMIN_PASSWORD}" \
      | jq -r '.access_token // empty')" || fail "cannot obtain an admin token from ${KEYCLOAK_URL}"
    [ -n "$tok" ] || fail "admin token response had no access_token"
    printf '%s %s' "$(date +%s)" "$tok" >"$TOKEN_FILE"
  fi
  echo "$tok"
}

# get URL -> body on 200; prints nothing and returns 1 on 404; fails otherwise.
get() {
  local out status body
  out="$(curl -sS -w $'\n%{http_code}' -H "Authorization: Bearer $(token)" "$1")"
  status="${out##*$'\n'}"
  body="${out%$'\n'*}"
  case "$status" in
    200) echo "$body" ;;
    404) return 1 ;;
    *) fail "GET $1 returned ${status}: ${body:0:300}" ;;
  esac
}

render() {
  jq --argjson vars "$TEMPLATE_VARS" 'walk(if type == "string"
    then reduce $vars[] as $v (.; split("${" + $v + "}") | join($ENV[$v] // "")) else . end)' "$1"
}

# The expected redirect set of a client: the template's own entries plus, for
# a client that has redirect URIs at all, "<origin>/*" (redirect and
# post-logout) and "<origin>" (web origin) for each space-separated origin in
# SOCKBOWL_EXTRA_REDIRECT_ORIGINS. Printed as {"redirectUris":[..],
# "webOrigins":[..],"postLogout":[..]|null}, every list sorted and unique.
# shellcheck disable=SC2016 # jq program, not shell
expected_uri_sets() {
  local -a extras=()
  read -r -a extras <<<"$SOCKBOWL_EXTRA_REDIRECT_ORIGINS" || true
  jq -c --argjson extra "$(jq -cn '$ARGS.positional' --args "${extras[@]}")" '
    ((.redirectUris // []) | length > 0) as $spa
    | (if $spa then $extra else [] end) as $x
    | {redirectUris: ((.redirectUris // []) + ($x | map(. + "/*")) | unique),
       webOrigins: ((.webOrigins // []) + $x | unique),
       postLogout: (((.attributes // {})["post.logout.redirect.uris"]) as $p
                    | if $p == null then null
                      else (if $p == "" then [] else ($p | split("##")) end) + ($x | map(. + "/*")) | unique end)}'
}

# The live client's redirect sets, in the same shape.
# shellcheck disable=SC2016 # jq program, not shell
live_uri_sets() {
  jq -c '{redirectUris: ((.redirectUris // []) | unique), webOrigins: ((.webOrigins // []) | unique),
          postLogout: (((.attributes // {})["post.logout.redirect.uris"] // "") | if . == "" then [] else split("##") end | unique)}'
}

# First argument: JSON of the expected sorted name list; second: actual.
same_set() { [ "$(jq -c 'sort' <<<"$1")" = "$(jq -c 'sort' <<<"$2")" ]; }

# shellcheck disable=SC2016 # jq program, not shell
JQ_CONTAINS='def contained($cur):
  if type == "object" then (($cur|type) == "object") and (to_entries | all(.key as $k | .value | contained($cur[$k])))
  elif type == "array" then (($cur|type) == "array") and ((map(tojson)|sort) == ($cur|map(tojson)|sort))
  else . == $cur end;
  def mismatches($cur): [to_entries[] | select(.key as $k | .value | contained($cur[$k]) | not) | .key];'

check_realm() {
  local rel settings current bad
  rel="$(jq -r '.realmSettings // empty' "$RBAC_MODEL")"
  [ -n "$rel" ] || return 0
  settings="$(render "${RBAC_DIR}/${rel}")"
  current="$(get "$API")" || fail "realm ${KEYCLOAK_REALM} not found"
  bad="$(jq -c --argjson cur "$current" "${JQ_CONTAINS}"'mismatches($cur)' <<<"$settings")"
  if [ "$bad" = "[]" ]; then ok "realm settings"; else drift "realm settings differ: ${bad}"; fi
}

check_roles() {
  local all perms name
  all="$(get "${API}/roles?first=0&max=10000&briefRepresentation=true" | jq -c '[.[].name]')"
  perms="$(jq -c '.permissionRoles' "$RBAC_MODEL")"
  local missing stray
  missing="$(jq -c --argjson all "$all" '. - $all' <<<"$perms")"
  stray="$(jq -c --argjson p "$perms" '[.[] | select(test("^[a-z]+:[a-z-]+$"))] - $p' <<<"$all")"
  if [ "$missing" = "[]" ]; then ok "permission roles present"; else drift "missing permission roles: ${missing}"; fi
  if [ "$stray" = "[]" ]; then ok "no stray permission roles"; else drift "stray permission roles: ${stray}"; fi

  while IFS= read -r name; do
    local want have
    want="$(jq -c --arg k "$name" '.compositeRoles[$k] | unique' "$RBAC_MODEL")"
    if ! have="$(get "${API}/roles/$(enc "$name")/composites/realm" | jq -c '[.[].name] | unique')"; then
      drift "composite role missing: ${name}"; continue
    fi
    if same_set "$want" "$have"; then ok "composite ${name}"; else drift "composite ${name}: want ${want} have ${have}"; fi
  done < <(jq -r '.compositeRoles | keys[]' "$RBAC_MODEL")

  local drid want have
  drid="$(get "${API}/roles/$(enc "default-roles-${KEYCLOAK_REALM}")" | jq -r '.id')"
  want="$(jq -c '[.defaultRole, "offline_access", "uma_authorization"] | unique' "$RBAC_MODEL")"
  have="$(get "${API}/roles-by-id/${drid}/composites/realm" | jq -c '[.[].name] | unique')"
  if same_set "$want" "$have"; then ok "default role"; else drift "default-roles-${KEYCLOAK_REALM}: want ${want} have ${have}"; fi
}

client_uuid() {
  get "${API}/clients?clientId=$(enc "$1")" | jq -r --arg c "$1" '[.[] | select(.clientId == $c)][0].id // empty'
}

# Client template path. "file" entries are relative to the model directory
# unless RBAC_CLIENTS_DIR is set, in which case the file's basename is looked
# up there (for containers that mount keycloak/clients elsewhere).
client_file() {
  if [ -n "${RBAC_CLIENTS_DIR:-}" ]; then echo "${RBAC_CLIENTS_DIR}/$(basename "$1")"; else echo "${RBAC_DIR}/$1"; fi
}

check_client() {
  local entry="$1" cid file when secret_env uuid desired current bad
  cid="$(jq -r '.clientId' <<<"$entry")"
  file="$(client_file "$(jq -r '.file' <<<"$entry")")"
  when="$(jq -r '.enabledWhen // empty' <<<"$entry")"
  secret_env="$(jq -r '.secretEnv // empty' <<<"$entry")"
  uuid="$(client_uuid "$cid")"

  if [ -n "$when" ] && [ "${!when:-false}" != "true" ]; then
    if [ -n "$uuid" ]; then drift "client ${cid} exists but ${when} is not true"; else ok "client ${cid} absent"; fi
    return 0
  fi
  [ -n "$uuid" ] || { drift "client ${cid} missing"; return 0; }

  desired="$(render "$file")"
  current="$(get "${API}/clients/${uuid}")"
  bad="$(jq -c --argjson cur "$current" "${JQ_CONTAINS}"'del(.protocolMappers, .redirectUris, .webOrigins)
    | if .attributes then .attributes |= del(.["post.logout.redirect.uris"]) else . end | mismatches($cur)' <<<"$desired")"
  if [ "$bad" = "[]" ]; then ok "client ${cid} settings"; else drift "client ${cid} settings differ: ${bad}"; fi

  # Redirect URIs, web origins and post-logout URIs: exact sets, so a stale
  # extra entry (e.g. an old host's URI) is drift.
  local want_uris have_uris field
  want_uris="$(expected_uri_sets <<<"$desired")"
  have_uris="$(live_uri_sets <<<"$current")"
  for field in redirectUris webOrigins postLogout; do
    local w h
    w="$(jq -c --arg f "$field" '.[$f]' <<<"$want_uris")"
    [ "$w" != "null" ] || continue
    h="$(jq -c --arg f "$field" '.[$f]' <<<"$have_uris")"
    if [ "$w" = "$h" ]; then ok "client ${cid} ${field}"; else drift "client ${cid} ${field}: want ${w} have ${h}"; fi
  done

  local mappers want_names have_names name
  mappers="$(get "${API}/clients/${uuid}/protocol-mappers/models")"
  want_names="$(jq -c '[.protocolMappers[]?.name] | unique' <<<"$desired")"
  have_names="$(jq -c '[.[].name] | unique' <<<"$mappers")"
  same_set "$want_names" "$have_names" || drift "client ${cid} mappers: want ${want_names} have ${have_names}"
  while IFS= read -r name; do
    local w h
    w="$(jq -c --arg n "$name" '.protocolMappers[] | select(.name == $n)' <<<"$desired")"
    h="$(jq -c --arg n "$name" '[.[] | select(.name == $n)][0] // null' <<<"$mappers")"
    if [ "$h" != "null" ] && ! jq -e --argjson cur "$h" "${JQ_CONTAINS}"'contained($cur)' <<<"$w" >/dev/null; then
      drift "client ${cid} mapper ${name} differs"
    fi
  done < <(jq -r '.protocolMappers[]?.name' <<<"$desired")

  if [ -n "$secret_env" ] && [ -n "${!secret_env:-}" ]; then
    local s
    s="$(get "${API}/clients/${uuid}/client-secret" | jq -r '.value // empty')"
    if [ "$s" = "${!secret_env}" ]; then ok "client ${cid} secret"; else drift "client ${cid} secret does not match ${secret_env}"; fi
  fi

  if [ "$(jq -r '.serviceClient.clientId // empty' "$RBAC_MODEL")" = "$cid" ]; then
    local sa want have
    sa="$(get "${API}/clients/${uuid}/service-account-user" | jq -r '.id')"
    want="$(jq -c '.serviceClient.roles | unique' "$RBAC_MODEL")"
    have="$(get "${API}/users/${sa}/role-mappings/realm" | jq -c '[.[].name] | unique')"
    if same_set "$want" "$have"; then ok "service account ${cid} roles"; else drift "service account ${cid} roles: want ${want} have ${have}"; fi
  fi
}

check_demo_users() {
  local tiers du username tier user
  tiers="$(jq -c '.compositeRoles | keys' "$RBAC_MODEL")"
  while IFS= read -r du; do
    username="$(jq -r '.username' <<<"$du")"
    tier="$(jq -r '.tier' <<<"$du")"
    user="$(get "${API}/users?username=$(enc "$username")&exact=true" | jq -c --arg u "$username" '[.[] | select(.username == $u)][0] // empty')"
    if [ "$CREATE_DEMO_ACCOUNTS" = "true" ]; then
      [ -n "$user" ] || { drift "demo user ${username} missing"; continue; }
      [ "$(jq -r '.enabled' <<<"$user")" = "true" ] || drift "demo user ${username} is disabled"
      local have
      have="$(get "${API}/users/$(jq -r '.id' <<<"$user")/role-mappings/realm" | jq -c --argjson t "$tiers" '[.[].name | select(. as $n | $t | index($n))]')"
      if same_set "[\"${tier}\"]" "$have"; then ok "demo user ${username} (${tier})"; else drift "demo user ${username} tier roles: want [${tier}] have ${have}"; fi
    else
      if [ -n "$user" ] && [ "$(jq -r '.enabled' <<<"$user")" = "true" ]; then
        drift "demo user ${username} is enabled but CREATE_DEMO_ACCOUNTS is not true"
      else
        ok "demo user ${username} absent or disabled"
      fi
    fi
  done < <(jq -c '.demoUsers // [] | .[]' "$RBAC_MODEL")
}

main() {
  { command -v curl && command -v jq; } >/dev/null || fail "curl and jq are required"
  [ -f "$RBAC_MODEL" ] || fail "RBAC model not found: ${RBAC_MODEL}"
  RBAC_DIR="$(cd "$(dirname "$RBAC_MODEL")" && pwd)"
  if [ -z "${RBAC_CLIENTS_DIR:-}" ] && [ ! -d "${RBAC_DIR}/clients" ] && [ -d /keycloak-clients ]; then
    RBAC_CLIENTS_DIR=/keycloak-clients
  fi
  export SOCKBOWL_AUTH_AUDIENCE="${SOCKBOWL_AUTH_AUDIENCE:-$(jq -r '.audience // "sockbowl-api"' "$RBAC_MODEL")}"

  check_realm
  check_roles
  local entry
  while IFS= read -r entry; do check_client "$entry"; done < <(jq -c '.clients[]' "$RBAC_MODEL")
  check_demo_users

  if [ "$DRIFT" -ne 0 ]; then
    echo "[verify-rbac] FAILED: ${DRIFT} drift(s) between realm '${KEYCLOAK_REALM}' and ${RBAC_MODEL}"
    exit 1
  fi
  echo "[verify-rbac] OK: realm '${KEYCLOAK_REALM}' matches ${RBAC_MODEL}"
}

main "$@"
