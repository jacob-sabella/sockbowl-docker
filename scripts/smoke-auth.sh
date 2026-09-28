#!/usr/bin/env bash
#
# smoke-auth.sh — full-stack auth smoke test.
#
# Runs the REST/GraphQL/STOMP authorization matrix for real, against an
# already-running full stack with AUTH_ENABLED=true (the e2e/dev overlay:
# docker-compose.yml + docker-compose.dev.yml, per README.md "Authentication
# modes" and docs/auth.md). It does not bring the stack up or down itself —
# that's the caller's job (see scripts/clean-clone-test.sh and
# scripts/test-compose-posture.sh for the compose lifecycle pattern).
#
# What it checks:
#   - game & questions REST: anonymous, wrong role, wrong owner, banned, and
#     service-token-as-user cases, using real Keycloak tokens minted via the
#     sockbowl-e2e password grant and a sockbowl-game-backend
#     client-credentials token.
#   - questions GraphQL: an UNAUTHORIZED and a FORBIDDEN mutation
#     classification, an anonymous getPacketById on a DRAFT (null), and a
#     PUBLISHED packet's answers redacted for an anonymous reader.
#   - game STOMP: delegated to scripts/stomp-probe.mjs (forged SEND, cross-game
#     SUBSCRIBE, bad secret, banned CONNECT, and every other STOMP
#     authorization row), plus the service-token proof (SetMatchPacket succeeding
#     only because the game fetched the packet from questions with its own
#     service token).
#
# Usage:
#   SOCKBOWL_GAME_BACKEND_SECRET=<the running stack's value> \
#   NEO4J_PASSWORD=<the running stack's value> scripts/smoke-auth.sh
#
# Env (all match .env.example / docker-compose.yml so the defaults work
# against the standard e2e overlay unchanged):
#   APP_HOST, APP_PROTOCOL, WS_PROTOCOL, KEYCLOAK_PORT, SOCKBOWL_GAME_PORT,
#   SOCKBOWL_QUESTIONS_PORT, DEMO_PASSWORD, SOCKBOWL_GAME_BACKEND_SECRET
#     (required: the stack's rbac-init rotates the sockbowl-game-backend
#     secret to this value on every load-rbac.sh run, so there is no safe
#     built-in default here), KEYCLOAK_ISSUER_URI (a minted
#     token's `iss` must equal this exactly, or every service's issuer
#     validation fails; defaults to the same computed URL docker-compose.yml's
#     KEYCLOAK_ISSUER_URI defaults to), NEO4J_HTTP_PORT, NEO4J_USER,
#     NEO4J_PASSWORD (required, no safe default, same reason as the backend
#     secret above: needed to seed a throwaway BankTossup/BankBonus fixture
#     over Neo4j's HTTP query endpoint, since docker-compose.yml wires no
#     qbreader-dump loader and a fresh stack's bank is otherwise empty).
#
# Exit: 0 if every row passed. Prints "PASS:"/"FAIL:"/"SKIP:" lines (this
# repo's convention; see scripts/test-rbac-reconcile.sh) plus a final table
# suitable for pasting into
# docs/superpowers/plans/2026-07-05-rbac-verification.md.
set -euo pipefail
shopt -s inherit_errexit

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# shellcheck source=lib/kafka-consumer-stability.sh
source "$ROOT/scripts/lib/kafka-consumer-stability.sh"

APP_HOST="${APP_HOST:-localhost}"
APP_PROTOCOL="${APP_PROTOCOL:-http}"
WS_PROTOCOL="${WS_PROTOCOL:-ws}"
KEYCLOAK_PORT="${KEYCLOAK_PORT:-8080}"
SOCKBOWL_GAME_PORT="${SOCKBOWL_GAME_PORT:-7000}"
SOCKBOWL_QUESTIONS_PORT="${SOCKBOWL_QUESTIONS_PORT:-7009}"
NEO4J_HTTP_PORT="${NEO4J_HTTP_PORT:-7474}"
NEO4J_USER="${NEO4J_USER:-neo4j}"
: "${NEO4J_PASSWORD:?Set NEO4J_PASSWORD to the running stacks value (needed to seed a BankTossup/BankBonus fixture: docker-compose.yml wires no qbreader-dump loader, so a freshly created stack has an empty bank and import-random has nothing to sample)}"
DEMO_PASSWORD="${DEMO_PASSWORD:-demo123}"
: "${SOCKBOWL_GAME_BACKEND_SECRET:?Set SOCKBOWL_GAME_BACKEND_SECRET to the running stacks value (rbac-init rotates it on every load-rbac.sh run; there is no safe default)}"

REALM="sockbowl"
KC_URL="${APP_PROTOCOL}://${APP_HOST}:${KEYCLOAK_PORT}"
KEYCLOAK_ISSUER_URI="${KEYCLOAK_ISSUER_URI:-${KC_URL}/realms/${REALM}}"
GAME_URL="${APP_PROTOCOL}://${APP_HOST}:${SOCKBOWL_GAME_PORT}"
QUESTIONS_URL="${APP_PROTOCOL}://${APP_HOST}:${SOCKBOWL_QUESTIONS_PORT}"
NEO4J_URL="${APP_PROTOCOL}://${APP_HOST}:${NEO4J_HTTP_PORT}"

# Game requires every GameSettings field verbatim (CreateGameRequest is bound
# via its all-args constructor, so Jackson passes JSON `null` for any omitted
# primitive, e.g. `bonusesEnabled`, and null-into-boolean is a 400 — confirmed
# live; a real client, e.g. sockbowl-ng, always sends the full object).
GAME_BODY_CLASSIC='{"gameSettings":{"gameMode":"QUIZ_BOWL_CLASSIC","bonusesEnabled":false}}'
GAME_BODY_SINGLE='{"gameSettings":{"gameMode":"SINGLE_PLAYER","bonusesEnabled":false}}'

# BankTossup/BankBonus nodes come from a separate qbreader-dump loader that
# this compose stack does not run (scripts/init-neo4j.sh only imports the
# Packet/Tossup/Bonus fixture from base.graphml); a fresh stack's bank is
# empty, so import-random has nothing to sample. Seed the same minimal
# fixture shape sockbowl-questions' own EphemeralPacketFlowIT uses, over
# Neo4j's HTTP query endpoint (no cypher-shell/container-name dependency),
# and remove it again in cleanup().
BANK_TAG="smoke-$$"
seed_bank_fixture() {
  local stmt
  stmt="UNWIND range(1,5) AS i CREATE (:BankTossup {remoteId: '${BANK_TAG}-t'+i, question: 'Tossup '+i+'?', answer: 'Answer '+i, category: 'Science', subcategory: 'Science', difficulty: 5, year: 2020, standard: true}) CREATE (b:BankBonus {remoteId: '${BANK_TAG}-b'+i, preamble: 'Bonus preamble '+i, category: 'Science', subcategory: 'Science', difficulty: 5, year: 2020, standard: true}) CREATE (b)-[:HAS_PART {order:0}]->(:BankBonusPart {question:'Part1?',answer:'PartA1'}) CREATE (b)-[:HAS_PART {order:1}]->(:BankBonusPart {question:'Part2?',answer:'PartA2'}) CREATE (b)-[:HAS_PART {order:2}]->(:BankBonusPart {question:'Part3?',answer:'PartA3'})"
  curl -sS -u "${NEO4J_USER}:${NEO4J_PASSWORD}" -X POST "$NEO4J_URL/db/neo4j/tx/commit" \
    -H 'Content-Type: application/json' \
    -d "$(jq -n --arg s "$stmt" '{statements:[{statement:$s}]}')" >/dev/null
}
cleanup_bank_fixture() {
  local stmt
  stmt="MATCH (n) WHERE (n:BankTossup OR n:BankBonus) AND n.remoteId STARTS WITH '${BANK_TAG}-' OPTIONAL MATCH (n)-[:HAS_PART]->(bp:BankBonusPart) DETACH DELETE n, bp"
  curl -sS -u "${NEO4J_USER}:${NEO4J_PASSWORD}" -X POST "$NEO4J_URL/db/neo4j/tx/commit" \
    -H 'Content-Type: application/json' \
    -d "$(jq -n --arg s "$stmt" '{statements:[{statement:$s}]}')" >/dev/null || true
}
trap cleanup_bank_fixture EXIT
seed_bank_fixture
WS_URL="${WS_PROTOCOL}://${APP_HOST}:${SOCKBOWL_GAME_PORT}/sockbowl-game"

PASSED=0
FAILED=0
SKIPPED=0
declare -a RESULT_LINES=()

pass() { PASSED=$((PASSED + 1)); RESULT_LINES+=("PASS: $*"); echo "PASS: $*"; }
failc() { FAILED=$((FAILED + 1)); RESULT_LINES+=("FAIL: $*"); echo "FAIL: $*" >&2; }
skip() { SKIPPED=$((SKIPPED + 1)); RESULT_LINES+=("SKIP: $*"); echo "SKIP: $*"; }

# expect_status <desc> <expected-http-status> <actual-http-status>
expect_status() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then pass "$desc ($actual)"; else failc "$desc: expected $expected, got $actual"; fi
}

# expect_eq <desc> <expected> <actual>
expect_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then pass "$desc"; else failc "$desc: expected '$expected', got '$actual'"; fi
}

# req <method> <url> [bearer] [json-body] — sets $CODE and $BODY.
req() {
  local method="$1" url="$2" bearer="${3:-}" data="${4:-}"
  local -a args=(-sS -X "$method" "$url" -H 'Content-Type: application/json')
  [ -n "$bearer" ] && args+=(-H "Authorization: Bearer $bearer")
  [ -n "$data" ] && args+=(--data "$data")
  local out
  out="$(curl "${args[@]}" -w $'\n%{http_code}' 2>&1)" || true
  CODE="$(tail -n1 <<<"$out")"
  BODY="$(sed '$d' <<<"$out")"
}

# gql <bearer-or-empty> <query> — POSTs to /graphql; sets $BODY (GraphQL
# errors travel in the 200 response body, not the HTTP status).
gql() {
  local bearer="$1" query="$2" payload
  payload="$(jq -n --arg q "$query" '{query:$q}')"
  req POST "$QUESTIONS_URL/graphql" "$bearer" "$payload"
}

# token_for <username> -> prints an access token (password grant, sockbowl-e2e).
token_for() {
  curl -sS -X POST "$KC_URL/realms/$REALM/protocol/openid-connect/token" \
    -d grant_type=password -d client_id=sockbowl-e2e \
    -d "username=$1" -d "password=$DEMO_PASSWORD" | jq -r '.access_token // empty'
}

# service_token -> prints an access token (client_credentials, sockbowl-game-backend).
service_token() {
  curl -sS -X POST "$KC_URL/realms/$REALM/protocol/openid-connect/token" \
    -d grant_type=client_credentials -d client_id=sockbowl-game-backend \
    -d "client_secret=$SOCKBOWL_GAME_BACKEND_SECRET" | jq -r '.access_token // empty'
}

# jwt_claim <token> <jq-filter> -> decodes the JWT payload (no signature
# check: this is a smoke test reading claims from a token it just minted
# itself, not verifying anyone else's).
jwt_claim() {
  local token="$1" filter="$2" payload mod
  payload="$(cut -d. -f2 <<<"$token" | tr '_-' '/+')"
  mod=$((${#payload} % 4))
  if [ "$mod" -eq 2 ]; then payload+="=="; elif [ "$mod" -eq 3 ]; then payload+="="; fi
  base64 -d <<<"$payload" 2>/dev/null | jq -r "$filter"
}

# wait_for_game_kafka_ready — FIX-D1 (M2-LIVE-01).
#
# game can report /actuator/health healthy before its Kafka consumer group
# ("game-consumers") has a stable partition assignment; a STOMP SEND that
# lands in that window is silently dropped (the default
# auto.offset.reset=latest skips anything produced before the first
# assignment), with no error frame — which flakes the STOMP matrix below on a
# freshly started stack. Call this once, right before that matrix, after the
# REST/GraphQL rows and the STOMP fixture seats are set up (so it overlaps
# with, rather than adds to, that setup time).
#
# Preferred: FIX-G2 (game, running in parallel with this WP) adds a
# Kafka-listener readiness HealthIndicator exposed as a
# `/actuator/health/readiness` group. If the game image under test has it,
# poll that directly. Older images (or a run before FIX-G2 lands) don't have
# this endpoint at all (404) — this must not treat that as a failure, so it
# falls back to asking Kafka itself, via `kafka-consumer-groups.sh
# --describe`, whether the group has settled on a stable single member
# across two samples a few seconds apart (kafka_consumer_group_members, from
# scripts/lib/kafka-consumer-stability.sh). If neither is available (no
# readiness group and no reachable Kafka container), this only SKIPs the
# wait rather than failing the whole smoke run over an environment quirk;
# the STOMP matrix below can still flake in that case, same as before this
# fix.
GAME_KAFKA_CONSUMER_GROUP="${GAME_KAFKA_CONSUMER_GROUP:-game-consumers}"
GAME_READINESS_TIMEOUT_SECONDS="${GAME_READINESS_TIMEOUT_SECONDS:-90}"
GAME_READINESS_POLL_INTERVAL_SECONDS="${GAME_READINESS_POLL_INTERVAL_SECONDS:-5}"

wait_for_game_kafka_ready() {
  echo "== waiting for game's Kafka consumer group ('$GAME_KAFKA_CONSUMER_GROUP') to be ready (M2-LIVE-01) =="
  local deadline=$((SECONDS + GAME_READINESS_TIMEOUT_SECONDS))
  local readiness_url="$GAME_URL/actuator/health/readiness"

  req GET "$readiness_url" ""
  if [ "$CODE" = "200" ] || [ "$CODE" = "503" ]; then
    echo "game exposes $readiness_url (FIX-G2's readiness group); polling it for status=UP"
    while [ "$SECONDS" -lt "$deadline" ]; do
      req GET "$readiness_url" ""
      if [ "$CODE" = "200" ]; then
        local status
        status="$(jq -r '.status // empty' <<<"$BODY" 2>/dev/null || true)"
        if [ "$status" = "UP" ]; then
          pass "game readiness ($readiness_url) is UP"
          return 0
        fi
      fi
      sleep "$GAME_READINESS_POLL_INTERVAL_SECONDS"
    done
    failc "game readiness ($readiness_url) did not reach status=UP within ${GAME_READINESS_TIMEOUT_SECONDS}s"
    return 0
  fi

  echo "game has no $readiness_url (got HTTP $CODE; FIX-G2's readiness group isn't in this image); falling back to polling Kafka's consumer-group state directly"
  local kafka_cid
  kafka_cid="$(docker ps --filter 'label=com.docker.compose.service=kafka' --format '{{.ID}}' 2>/dev/null | head -n1 || true)"
  if [ -z "$kafka_cid" ]; then
    skip "game Kafka consumer-group readiness wait (no readiness group, and no kafka container found via 'docker ps --filter label=com.docker.compose.service=kafka'); proceeding straight to the STOMP matrix, which may still hit M2-LIVE-01 on a very fresh stack"
    return 0
  fi

  local prev="" cur="" stable_polls=0 member_count
  while [ "$SECONDS" -lt "$deadline" ]; do
    local describe
    describe="$(docker exec "$kafka_cid" /opt/kafka/bin/kafka-consumer-groups.sh \
      --bootstrap-server localhost:9092 --describe --group "$GAME_KAFKA_CONSUMER_GROUP" 2>/dev/null || true)"
    cur="$(kafka_consumer_group_members "$describe")"
    member_count="$(kafka_consumer_group_member_count "$describe")"
    if [ "$member_count" -eq 1 ] && [ -n "$prev" ] && [ "$cur" = "$prev" ]; then
      stable_polls=$((stable_polls + 1))
      if [ "$stable_polls" -ge 2 ]; then
        pass "game's Kafka consumer group '$GAME_KAFKA_CONSUMER_GROUP' has a stable single member ($cur)"
        return 0
      fi
    else
      stable_polls=0
    fi
    prev="$cur"
    sleep "$GAME_READINESS_POLL_INTERVAL_SECONDS"
  done
  failc "game's Kafka consumer group '$GAME_KAFKA_CONSUMER_GROUP' never reached a stable single member within ${GAME_READINESS_TIMEOUT_SECONDS}s (last seen: '${cur}')"
  return 0
}

echo "== smoke-auth: minting tokens (sockbowl-e2e password grant + sockbowl-game-backend client credentials) =="
TOKEN_PLAYER="$(token_for player2)"
TOKEN_AUTHOR="$(token_for testuser)"
TOKEN_MODERATOR="$(token_for moderator)"
TOKEN_ADMIN="$(token_for player1)"
TOKEN_BAN_TARGET="$(token_for player3)"
TOKEN_SERVICE="$(service_token)"
for pair in "player2:$TOKEN_PLAYER" "testuser:$TOKEN_AUTHOR" "moderator:$TOKEN_MODERATOR" "player1:$TOKEN_ADMIN" \
  "player3:$TOKEN_BAN_TARGET" "sockbowl-game-backend:$TOKEN_SERVICE"; do
  name="${pair%%:*}"
  tok="${pair#*:}"
  if [ -z "$tok" ] || [ "$tok" = "null" ]; then
    echo "FATAL: could not mint a token for $name (is the e2e overlay up, with SOCKBOWL_E2E=true and CREATE_DEMO_ACCOUNTS=true?)" >&2
    exit 2
  fi
done
AUD_CLAIM="$(jwt_claim "$TOKEN_PLAYER" '.aud')"
if echo "$AUD_CLAIM" | grep -q "sockbowl-api"; then
  pass "minted tokens carry aud=sockbowl-api (sockbowl-api-audience mapper is wired end to end)"
else
  failc "minted token's aud claim is '$AUD_CLAIM', expected it to contain sockbowl-api"
fi
skip "a token from a client without the audience mapper -> 401 is proved by questions' AudienceIT/JwtAudienceValidationTest (in-JVM Keycloak fixture with a dedicated no-audience client); the real realm has no such client to mint one from without provisioning it just for this check"

# Plan risk #5: a KC_HOSTNAME / KEYCLOAK_ISSUER_URI mismatch fails issuer
# validation everywhere, silently, on every protected endpoint.
ISS_CLAIM="$(jwt_claim "$TOKEN_PLAYER" '.iss')"
expect_eq "minted token iss matches KEYCLOAK_ISSUER_URI (plan risk #5)" "$KEYCLOAK_ISSUER_URI" "$ISS_CLAIM"

echo
echo "== REST matrix: game (plan section 4.1) =="

# --- create-new-game-session ---
req POST "$GAME_URL/api/v1/session/create-new-game-session" "" "$GAME_BODY_CLASSIC"
expect_status "create-new-game-session: guest is allowed (D1)" 200 "$CODE"
req POST "$GAME_URL/api/v1/session/create-new-game-session" "not-a-jwt" "$GAME_BODY_CLASSIC"
expect_status "create-new-game-session: invalid bearer -> 401" 401 "$CODE"
req POST "$GAME_URL/api/v1/session/create-new-game-session" "$TOKEN_SERVICE" "$GAME_BODY_CLASSIC"
expect_status "create-new-game-session: service token can't host -> 403" 403 "$CODE"

# --- join-game-session-by-code ---
req POST "$GAME_URL/api/v1/session/join-game-session-by-code" "" '{"joinCode":"ZZZZZZ","name":"Nobody"}'
expect_status "join-game-session-by-code: unknown code -> 404" 404 "$CODE"

# --- join-game-session-authenticated ---
req POST "$GAME_URL/api/v1/session/join-game-session-authenticated" "" '{"joinCode":"ZZZZZZ"}'
expect_status "join-game-session-authenticated: no bearer -> 401" 401 "$CODE"
req POST "$GAME_URL/api/v1/session/join-game-session-authenticated" "$TOKEN_SERVICE" '{"joinCode":"ZZZZZZ"}'
expect_status "join-game-session-authenticated: service token can't join -> 403" 403 "$CODE"

# --- /api/v1/user/** ---
req GET "$GAME_URL/api/v1/user/profile" ""
expect_status "GET /api/v1/user/profile: anonymous -> 401" 401 "$CODE"
req GET "$GAME_URL/api/v1/user/profile" "$TOKEN_SERVICE"
expect_status "GET /api/v1/user/profile: service token -> 403" 403 "$CODE"
req GET "$GAME_URL/api/v1/user/profile" "$TOKEN_PLAYER"
expect_status "GET /api/v1/user/profile: a signed-in player -> 200" 200 "$CODE"

# --- /api/v1/auth/me and /status ---
req GET "$GAME_URL/api/v1/auth/me" ""
expect_status "GET /api/v1/auth/me: anonymous -> 401" 401 "$CODE"
req GET "$GAME_URL/api/v1/auth/me" "$TOKEN_PLAYER"
expect_status "GET /api/v1/auth/me: a signed-in player -> 200" 200 "$CODE"
req GET "$GAME_URL/api/v1/auth/status" ""
expect_status "GET /api/v1/auth/status: public -> 200" 200 "$CODE"

# --- /api/v1/admin/bans ---
req GET "$GAME_URL/api/v1/admin/bans" ""
expect_status "GET /api/v1/admin/bans: anonymous -> 401" 401 "$CODE"
req GET "$GAME_URL/api/v1/admin/bans" "$TOKEN_PLAYER"
expect_status "GET /api/v1/admin/bans: player -> 403" 403 "$CODE"
req GET "$GAME_URL/api/v1/admin/bans" "$TOKEN_MODERATOR"
expect_status "GET /api/v1/admin/bans: moderator -> 200" 200 "$CODE"
req POST "$GAME_URL/api/v1/admin/bans" "$TOKEN_PLAYER" '{"bannedKeycloakId":"00000000-0000-0000-0000-000000000099","reason":"smoke-403-check"}'
expect_status "POST /api/v1/admin/bans: player -> 403" 403 "$CODE"
req DELETE "$GAME_URL/api/v1/admin/bans/00000000-0000-0000-0000-000000000000" "$TOKEN_PLAYER"
expect_status "DELETE /api/v1/admin/bans/{id}: player -> 403" 403 "$CODE"

# --- /api/v1/admin/** boundary (admin:access), and the deny-by-default catch-all ---
req GET "$GAME_URL/api/v1/admin/probe" "$TOKEN_MODERATOR"
expect_status "GET /api/v1/admin/probe: moderator lacks admin:access -> 403" 403 "$CODE"
req GET "$GAME_URL/api/v1/admin/probe" "$TOKEN_ADMIN"
expect_status "GET /api/v1/admin/probe: admin passes the admin:access gate (404: no such controller) -> 404" 404 "$CODE"
req GET "$GAME_URL/api/v1/totally-unmapped-path" ""
expect_status "deny-by-default: an unmapped path, anonymous -> 401 (never a redirect)" 401 "$CODE"
req GET "$GAME_URL/api/v1/totally-unmapped-path" "$TOKEN_PLAYER"
expect_status "deny-by-default: an unmapped path, authenticated -> 403 (never a redirect)" 403 "$CODE"

# --- removed routes (AUTH-08) ---
# TestController is gone, but /api/v1/test matches no specific matcher below,
# so it falls into anyRequest().denyAll() — the security filter chain rejects
# it (401 anonymous) before Spring MVC ever looks for a handler; it's the same
# deny-by-default bucket as any other unmapped path, not a distinct 404 case
# (confirmed live: an unmapped path never reaches a 404 dispatch anonymously).
req GET "$GAME_URL/api/v1/test" ""
expect_status "removed route /api/v1/test -> 401, deny-by-default (TestController deleted)" 401 "$CODE"
req GET "$GAME_URL/login" ""
expect_status "removed server-side login flow /login -> 401, never a redirect" 401 "$CODE"

echo
echo "== REST matrix: questions (plan section 4.1) =="

req GET "$QUESTIONS_URL/api/qbreader/category-counts" ""
expect_status "GET /api/qbreader/category-counts: public -> 200" 200 "$CODE"
req GET "$QUESTIONS_URL/api/qbreader/taxonomy-counts" ""
expect_status "GET /api/qbreader/taxonomy-counts: public -> 200" 200 "$CODE"
req GET "$QUESTIONS_URL/api/qbreader/stats" ""
expect_status "GET /api/qbreader/stats: public -> 200" 200 "$CODE"
req GET "$QUESTIONS_URL/api/qbreader/dimensions" ""
expect_status "GET /api/qbreader/dimensions: public -> 200" 200 "$CODE"
req POST "$QUESTIONS_URL/api/qbreader/count" "" '{}'
expect_status "POST /api/qbreader/count: public -> 200" 200 "$CODE"

req POST "$QUESTIONS_URL/api/qbreader/import-random" "" '{"tossupCount":3,"bonusCount":3}'
expect_status "POST /api/qbreader/import-random: anonymous -> 200, an EPHEMERAL packet (D15)" 200 "$CODE"
req POST "$QUESTIONS_URL/api/qbreader/import-random" "not-a-jwt" '{"tossupCount":3,"bonusCount":3}'
expect_status "POST /api/qbreader/import-random: invalid bearer -> 401" 401 "$CODE"
req POST "$QUESTIONS_URL/api/qbreader/import-random" "$TOKEN_PLAYER" '{"tossupCount":3,"bonusCount":3}'
expect_status "POST /api/qbreader/import-random: player -> 200, an EPHEMERAL packet (D15)" 200 "$CODE"
req POST "$QUESTIONS_URL/api/qbreader/import-random" "$TOKEN_AUTHOR" '{"tossupCount":3,"bonusCount":3}'
expect_status "POST /api/qbreader/import-random: author -> 200, an owned DRAFT packet" 200 "$CODE"

req GET "$QUESTIONS_URL/api/packets/generate?topic=Science" ""
expect_status "GET /api/packets/generate: anonymous -> 401" 401 "$CODE"
req GET "$QUESTIONS_URL/api/packets/generate?topic=Science" "$TOKEN_PLAYER"
expect_status "GET /api/packets/generate: player -> 403" 403 "$CODE"

req GET "$GAME_URL/actuator/health" ""
expect_status "GET game /actuator/health: public -> 200" 200 "$CODE"
req GET "$QUESTIONS_URL/actuator/health" ""
expect_status "GET questions /actuator/health: public -> 200" 200 "$CODE"

echo
echo "== GraphQL matrix (plan section 4.1: classification, draft/answer redaction) =="

SUFFIX="smoke-$$-$(date +%s)"
gql "$TOKEN_AUTHOR" "mutation { createPacket(input: {name: \"${SUFFIX}-draft\"}) { id } }"
DRAFT_ID="$(jq -r '.data.createPacket.id // empty' <<<"$BODY")"
if [ -z "$DRAFT_ID" ]; then
  echo "FATAL: could not create the draft packet fixture as testuser: $BODY" >&2
  exit 2
fi
gql "$TOKEN_AUTHOR" "mutation { addTossupToPacket(packetId: \"${DRAFT_ID}\", input: {question: \"Draft Q?\", answer: \"DraftSecretAnswer\"}) { id } }"

gql "$TOKEN_AUTHOR" "mutation { createPacket(input: {name: \"${SUFFIX}-published\"}) { id } }"
PUBLISHED_ID="$(jq -r '.data.createPacket.id // empty' <<<"$BODY")"
if [ -z "$PUBLISHED_ID" ]; then
  echo "FATAL: could not create the published packet fixture as testuser: $BODY" >&2
  exit 2
fi
gql "$TOKEN_AUTHOR" "mutation { addTossupToPacket(packetId: \"${PUBLISHED_ID}\", input: {question: \"Pub Q?\", answer: \"PublishedSecretAnswer\"}) { id } }"
gql "$TOKEN_AUTHOR" "mutation { setPacketVisibility(id: \"${PUBLISHED_ID}\", visibility: PUBLISHED) { id visibility } }"
VIS="$(jq -r '.data.setPacketVisibility.visibility // empty' <<<"$BODY")"
expect_eq "setPacketVisibility: PUBLISHED took effect" "PUBLISHED" "$VIS"

gql "" "mutation { createPacket(input: {name: \"${SUFFIX}-should-not-exist\"}) { id } }"
CLASS="$(jq -r '.errors[0].extensions.classification // empty' <<<"$BODY")"
expect_eq "GraphQL mutation classification: anonymous createPacket -> UNAUTHORIZED" "UNAUTHORIZED" "$CLASS"

gql "$TOKEN_PLAYER" "mutation { createPacket(input: {name: \"${SUFFIX}-should-not-exist-2\"}) { id } }"
CLASS="$(jq -r '.errors[0].extensions.classification // empty' <<<"$BODY")"
expect_eq "GraphQL mutation classification: player createPacket (no packet:create) -> FORBIDDEN" "FORBIDDEN" "$CLASS"

gql "" "{ getPacketById(id: \"${DRAFT_ID}\") { id } }"
GOT="$(jq -r '.data.getPacketById // "null"' <<<"$BODY")"
expect_eq "anonymous getPacketById(<draft>) -> null (no existence oracle)" "null" "$GOT"

gql "" "{ getPacketById(id: \"${PUBLISHED_ID}\") { id answersRedacted tossups { tossup { answer } } } }"
REDACTED="$(jq -r '.data.getPacketById.answersRedacted' <<<"$BODY")"
ANSWER="$(jq -r '.data.getPacketById.tossups[0].tossup.answer // "null"' <<<"$BODY")"
expect_eq "anonymous reading a PUBLISHED packet: answersRedacted=true" "true" "$REDACTED"
expect_eq "anonymous reading a PUBLISHED packet: tossup answer is null" "null" "$ANSWER"

echo
echo "== Seats for the STOMP probe (game REST) =="

# A guest game + a guest-joined seat.
req POST "$GAME_URL/api/v1/session/create-new-game-session" "" "$GAME_BODY_CLASSIC"
GUEST_GAME_ID="$(jq -r '.id' <<<"$BODY")"
GUEST_JOIN_CODE="$(jq -r '.joinCode' <<<"$BODY")"
req POST "$GAME_URL/api/v1/session/join-game-session-by-code" "" "$(jq -n --arg c "$GUEST_JOIN_CODE" '{joinCode:$c,name:"SmokeGuest"}')"
GUEST_PLAYER_ID="$(jq -r '.playerSessionId' <<<"$BODY")"
GUEST_SECRET="$(jq -r '.playerSecret' <<<"$BODY")"

# A second, unrelated guest game (the cross-game SUBSCRIBE target).
req POST "$GAME_URL/api/v1/session/create-new-game-session" "" "$GAME_BODY_CLASSIC"
OTHER_GAME_ID="$(jq -r '.id' <<<"$BODY")"

# testuser's own proctorless (SINGLE_PLAYER) game: game owner == testuser, so
# WP-G4's SetMatchPacket check allows testuser to set it, and the DRAFT packet
# above is testuser's own — no need to publish it first.
req POST "$GAME_URL/api/v1/session/create-new-game-session" "$TOKEN_AUTHOR" "$GAME_BODY_SINGLE"
AUTH_GAME_ID="$(jq -r '.id' <<<"$BODY")"
AUTH_JOIN_CODE="$(jq -r '.joinCode' <<<"$BODY")"
req POST "$GAME_URL/api/v1/session/join-game-session-authenticated" "$TOKEN_AUTHOR" "$(jq -n --arg c "$AUTH_JOIN_CODE" '{joinCode:$c}')"
AUTH_PLAYER_ID="$(jq -r '.playerSessionId' <<<"$BODY")"

# player3's own proctorless game, joined *before* the ban below (STOMP CONNECT
# re-checks the ban fresh, regardless of when the seat was created).
req POST "$GAME_URL/api/v1/session/create-new-game-session" "$TOKEN_BAN_TARGET" "$GAME_BODY_SINGLE"
BAN_GAME_ID="$(jq -r '.id' <<<"$BODY")"
BAN_JOIN_CODE="$(jq -r '.joinCode' <<<"$BODY")"
req POST "$GAME_URL/api/v1/session/join-game-session-authenticated" "$TOKEN_BAN_TARGET" "$(jq -n --arg c "$BAN_JOIN_CODE" '{joinCode:$c}')"
BAN_PLAYER_ID="$(jq -r '.playerSessionId' <<<"$BODY")"

for pair in "guest game:$GUEST_GAME_ID" "guest seat:$GUEST_PLAYER_ID" "other game:$OTHER_GAME_ID" \
  "author game:$AUTH_GAME_ID" "author seat:$AUTH_PLAYER_ID" "ban-target game:$BAN_GAME_ID" "ban-target seat:$BAN_PLAYER_ID"; do
  name="${pair%%:*}"; val="${pair#*:}"
  if [ -z "$val" ] || [ "$val" = "null" ]; then
    echo "FATAL: setting up the $name failed (see the REST calls above)" >&2
    exit 2
  fi
done

echo
echo "== Banning player3 (moderator), then the banned-user REST rows (plan section 2.6) =="

EXPIRES_AT="$(date -u -d '+10 minutes' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v+10M +%Y-%m-%dT%H:%M:%SZ)"
BAN_TARGET_SUB="$(jwt_claim "$TOKEN_BAN_TARGET" '.sub')"
req POST "$GAME_URL/api/v1/admin/bans" "$TOKEN_MODERATOR" \
  "$(jq -n --arg id "$BAN_TARGET_SUB" --arg exp "$EXPIRES_AT" '{bannedKeycloakId:$id,reason:"WP-D3 smoke-auth.sh",expiresAt:$exp}')"
expect_status "POST /api/v1/admin/bans: moderator bans player3 -> 201" 201 "$CODE"
BAN_ID="$(jq -r '.id // empty' <<<"$BODY")"

req POST "$GAME_URL/api/v1/session/create-new-game-session" "$TOKEN_BAN_TARGET" "$GAME_BODY_SINGLE"
expect_status "create-new-game-session: a banned user -> 403" 403 "$CODE"
req POST "$GAME_URL/api/v1/session/join-game-session-by-code" "$TOKEN_BAN_TARGET" '{"joinCode":"AAAAAA"}'
expect_status "join-game-session-by-code: a banned user -> 403 (checked before the join code)" 403 "$CODE"
req POST "$GAME_URL/api/v1/session/join-game-session-authenticated" "$TOKEN_BAN_TARGET" '{"joinCode":"AAAAAA"}'
expect_status "join-game-session-authenticated: a banned user -> 403" 403 "$CODE"

echo
wait_for_game_kafka_ready

echo
echo "== STOMP matrix (game): delegating to scripts/stomp-probe.mjs =="

STOMP_CONFIG="$(mktemp)"
trap 'rm -f "$STOMP_CONFIG"; cleanup_bank_fixture' EXIT
jq -n \
  --arg wsUrl "$WS_URL" \
  --arg guestGame "$GUEST_GAME_ID" --arg guestPlayer "$GUEST_PLAYER_ID" --arg guestSecret "$GUEST_SECRET" \
  --arg fakeGame "00000000-0000-0000-0000-000000000000" \
  --arg authGame "$AUTH_GAME_ID" --arg authPlayer "$AUTH_PLAYER_ID" --arg authToken "$TOKEN_AUTHOR" \
  --arg otherGame "$OTHER_GAME_ID" \
  --arg mismatchToken "$TOKEN_MODERATOR" \
  --arg serviceToken "$TOKEN_SERVICE" \
  --arg banGame "$BAN_GAME_ID" --arg banPlayer "$BAN_PLAYER_ID" --arg banToken "$TOKEN_BAN_TARGET" \
  --arg packetId "$DRAFT_ID" \
  '{
    wsUrl: $wsUrl,
    guest: {gameSessionId:$guestGame, playerSessionId:$guestPlayer, playerSecret:$guestSecret},
    fakeGameSessionId: $fakeGame,
    authSeat: {gameSessionId:$authGame, playerSessionId:$authPlayer, token:$authToken},
    otherGameSessionId: $otherGame,
    mismatchToken: $mismatchToken,
    serviceToken: $serviceToken,
    bannedSeat: {gameSessionId:$banGame, playerSessionId:$banPlayer, token:$banToken},
    packetId: $packetId
  }' >"$STOMP_CONFIG"

set +e
STOMP_OUTPUT="$(node "$ROOT/scripts/stomp-probe.mjs" "$STOMP_CONFIG" 2>&1)"
STOMP_EXIT=$?
set -e
echo "$STOMP_OUTPUT"
STOMP_PASS_COUNT="$(grep -c '^PASS:' <<<"$STOMP_OUTPUT" || true)"
STOMP_FAIL_COUNT="$(grep -c '^FAIL:' <<<"$STOMP_OUTPUT" || true)"
PASSED=$((PASSED + STOMP_PASS_COUNT))
FAILED=$((FAILED + STOMP_FAIL_COUNT))
if [ "$STOMP_EXIT" -ne 0 ] && [ "$STOMP_FAIL_COUNT" -eq 0 ]; then
  failc "stomp-probe.mjs exited $STOMP_EXIT without printing a FAIL line (crash?) — see its output above"
fi

echo
echo "== cleanup =="
if [ -n "$BAN_ID" ] && [ "$BAN_ID" != "null" ]; then
  req DELETE "$GAME_URL/api/v1/admin/bans/$BAN_ID" "$TOKEN_MODERATOR"
  if [ "$CODE" = "204" ]; then pass "cleanup: removed the smoke-test ban on player3"; else
    echo "note: could not remove the smoke-test ban ($CODE); it expires on its own at $EXPIRES_AT" >&2
  fi
fi

echo
echo "== smoke-auth: RESULTS =="
printf '%s\n' "${RESULT_LINES[@]}"
echo
echo "$PASSED passed, $FAILED failed, $SKIPPED skipped"
if [ "$FAILED" -eq 0 ]; then
  echo "== smoke-auth: ALL CHECKS PASSED =="
  exit 0
else
  echo "== smoke-auth: FAILURES ABOVE ==" >&2
  exit 1
fi
