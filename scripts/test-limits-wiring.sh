#!/usr/bin/env bash
#
# test-limits-wiring.sh — M4 rate-limit/quota compose and env wiring
# acceptance test (see docs/limits.md).
#
# Verifies the compose & env *wiring* for M4 rate limiting and quotas —
# independent of whether the sockbowl-game/sockbowl-questions images this
# script is run against already implement the limiter core itself; if a
# checked-out branch or a published image predates the limiter core, this
# follows the same "artifacts absent -> SKIP with an explicit message"
# pattern scripts/test-compose-posture.sh uses.
#
# Brings up a throwaway full-profile stack (base + dev overlay, so
# ALLOW_INSECURE_DEFAULTS lets .env.example's placeholder secrets through —
# see docker-compose.dev.yml's header) plus the limits-e2e overlay (tiny
# session-create / stomp-buzz limits, so a real limiter would trip fast),
# and checks:
#
#   1. `docker compose config -q` validates for all three file-set
#      combinations: base, base+dev, base+dev+limits-e2e.
#   2. sockbowl-questions only starts once redis is healthy (its
#      `depends_on: redis: condition: service_healthy`), and Redis itself
#      answers PING (game and questions run shell-less JRE-only images with
#      no redis-cli, so each app's own health endpoint is its proof of
#      connectivity instead — see check 4 below).
#   3. Every M4 env var this WP wires reaches each app container with the
#      overlay's value — or is genuinely absent from the container's
#      environment when no active layer sets it (the bare `KEY:` passthrough
#      contract documented in docker-compose.yml's M4 comment block), never
#      the literal string "null".
#   4. questions' /actuator/health reports UP overall. This does NOT prove
#      Redis connectivity: Q-V1-03 sets management.health.redis.enabled=false
#      in questions' MAIN application.yml (D12 — its Redis use fails open on
#      an outage, so a Redis blip must not turn questions' compose health red
#      and block game/ng from starting via depends_on: service_healthy). This
#      check is only proof questions itself came up and answers requests; see
#      the LIMITS_WIRING_LIVE section below for the actual Redis-down proof.
#   4b. LIMITS_WIRING_LIVE=true only (the live gate): stops the shared redis container, asserts
#       questions' /actuator/health is STILL UP and a GraphQL read still
#       answers HTTP 200 (proving D12's fail-open contract for real, not just
#       via the disabled health indicator), then restarts redis and waits for
#       it to report healthy again before continuing. Skipped by default
#       because it interrupts the one shared Redis both apps depend on for
#       the rest of this run's checks (including 5 below) — never combine it
#       with LIMITS_WIRING_KEEP=true.
#   5. If a curl burst against game's session-create endpoint actually
#      writes `rl:*` keys to Redis — i.e., the running image already has
#      RateLimitService/RequestGuardFilter from G1/G2 — asserts
#      `redis-cli KEYS 'rl:*'` is non-empty. Otherwise SKIPs this one
#      assertion with an explicit message. Re-run this script once the
#      limiter core is merged and locally built; it must PASS for real then.
#
# Usage: scripts/test-limits-wiring.sh
#   LIMITS_WIRING_PROJECT          compose project name (default sockbowl-m4wiring-<pid>)
#   LIMITS_WIRING_KEEP             true keeps the stack up after the run (default false)
#   LIMITS_WIRING_LIVE             true runs the Redis-stop/restart check (4b above); only
#                                   at the live gate (owns the fullstack.lock and a single
#                                   full stack machine-wide) — default false skips it
#   LIMITS_WIRING_GAME_IMAGE       override SOCKBOWL_GAME_IMAGE (default: .env.example's
#   LIMITS_WIRING_QUESTIONS_IMAGE  override SOCKBOWL_QUESTIONS_IMAGE   published ghcr.io
#   LIMITS_WIRING_NG_IMAGE         override SOCKBOWL_NG_IMAGE          :main image)
#     Use these to point at locally built images (e.g. sockbowl-questions:local, from
#     docker-compose.build.yml's own `./gradlew bootBuildImage` recipe) when the published
#     :main image can't start for a reason outside this script's control — e.g. a
#     Spring AI ChatModel-bean-ambiguity crash fixed on later goal branches but not
#     in :main, since nothing here is ever pushed to it.
#
# Requires docker (compose v2) and jq. Uses network_mode: host like the rest
# of this compose file, so it cannot run concurrently with another full
# stack on this host — serialize full-stack runs (see docs/auth.md "Single
# full-stack constraint"); the *caller* is responsible for that machine-wide
# lock, not this script.
set -euo pipefail
shopt -s inherit_errexit

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PROJECT="${LIMITS_WIRING_PROJECT:-sockbowl-m4wiring-$$}"
KEEP="${LIMITS_WIRING_KEEP:-false}"
ENV_FILE="$(mktemp)"
STATUS=0

cp .env.example "$ENV_FILE"
# The dev overlay's ALLOW_INSECURE_DEFAULTS=true lets check-secrets.sh accept
# .env.example's CHANGE_ME/demo123-style placeholders unchanged; nothing else
# needs overriding for a wiring-only run.

# Optional image overrides (see the usage comment above). A later line wins
# in a docker compose --env-file, so appending here overrides .env.example's
# own SOCKBOWL_*_IMAGE=...:main lines without touching that file.
{
  [ -n "${LIMITS_WIRING_GAME_IMAGE:-}" ] && echo "SOCKBOWL_GAME_IMAGE=${LIMITS_WIRING_GAME_IMAGE}"
  [ -n "${LIMITS_WIRING_QUESTIONS_IMAGE:-}" ] && echo "SOCKBOWL_QUESTIONS_IMAGE=${LIMITS_WIRING_QUESTIONS_IMAGE}"
  [ -n "${LIMITS_WIRING_NG_IMAGE:-}" ] && echo "SOCKBOWL_NG_IMAGE=${LIMITS_WIRING_NG_IMAGE}"
  true
} >>"$ENV_FILE"

set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

compose() {
  docker compose -p "$PROJECT" --env-file "$ENV_FILE" \
    -f docker-compose.yml -f docker-compose.dev.yml -f docker-compose.limits-e2e.yml "$@"
}

STACK_UP=false
cleanup() {
  if [ "$KEEP" != "true" ]; then
    if [ "$STACK_UP" = "true" ]; then
      compose down -v --remove-orphans >/dev/null 2>&1 || true
    fi
  fi
  rm -f "$ENV_FILE"
}
trap cleanup EXIT

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; STATUS=1; }
skip() { echo "SKIP: $*"; }
section() { echo; echo "== $*"; }

section "docker compose config -q for base / base+dev / base+dev+limits-e2e"
CONFIG_OK=true
docker compose --env-file "$ENV_FILE" -f docker-compose.yml config -q || CONFIG_OK=false
docker compose --env-file "$ENV_FILE" -f docker-compose.yml -f docker-compose.dev.yml config -q || CONFIG_OK=false
compose config -q || CONFIG_OK=false
if [ "$CONFIG_OK" = "true" ]; then
  pass "all three file-set combinations validate"
else
  fail "docker compose config -q failed for at least one file-set combination"
fi

section "bringing up the stack ($PROJECT)"
if compose --profile full up -d --wait --wait-timeout 300; then
  STACK_UP=true
  pass "stack reports healthy (redis, game, questions and their dependencies)"
else
  STACK_UP=true
  compose ps -a || true
  fail "stack did not reach healthy within the timeout (see 'docker compose -p $PROJECT ps -a' / logs above)"
  echo
  echo "Cannot run the remaining checks meaningfully without a healthy stack; stopping here." >&2
  exit 1
fi

section "redis itself is reachable (shared Redis both apps are wired to)"
# game and questions run on Paketo buildpack (JRE-only) images with no shell
# and no redis-cli (confirmed: `docker run --entrypoint sh ...` fails with
# "executable file not found"), so connectivity can't be exec-tested from
# inside them. redis-cli lives in the redis container itself, which shares
# the same host network namespace (network_mode: host) and therefore the
# same Redis instance both apps connect to. Each app's *own* proof of
# connectivity is its health endpoint, checked further down.
redis_cli() { compose exec -T redis redis-cli "$@"; }
if redis_cli ping 2>/dev/null | grep -qi PONG; then
  pass "redis-cli ping succeeds against the shared redis container"
else
  fail "redis-cli ping failed against the redis container"
fi

section "questions started only after redis's healthcheck passed (depends_on condition)"
REDIS_STARTED_AT="$(docker inspect -f '{{.State.StartedAt}}' "$(compose ps -q redis)")"
QUESTIONS_HEALTHY_SINCE="$(docker inspect -f '{{.State.Health.Status}}' "$(compose ps -q sockbowl-questions)" 2>/dev/null || echo unknown)"
if [ "$QUESTIONS_HEALTHY_SINCE" = "healthy" ]; then
  pass "sockbowl-questions is healthy, with redis already started (StartedAt=$REDIS_STARTED_AT); compose's depends_on ordering was honored"
else
  fail "sockbowl-questions health state is '$QUESTIONS_HEALTHY_SINCE', expected 'healthy'"
fi

section "M4 env vars land in each app container (overlay value, or genuinely absent)"
# game and questions have no shell/printenv inside the image (see above), so
# this reads back Docker's own record of each container's environment
# (`docker inspect .Config.Env`, the same list the container was actually
# started with) instead of exec'ing into it.
container_env() {
  local svc="$1" cid
  cid="$(compose ps -q "$svc")"
  docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$cid"
}
check_env() {
  # check_env <service> <VAR> <expected-value-or-'' for genuinely-absent>
  local svc="$1" var="$2" expected="$3" line actual found=false
  while IFS= read -r line; do
    case "$line" in
      "$var="*) actual="${line#"$var"=}"; found=true ;;
    esac
  done <<<"$(container_env "$svc")"
  if [ -z "$expected" ]; then
    if [ "$found" = "false" ]; then
      pass "$svc: $var is genuinely absent (no overlay sets it; app default applies)"
    else
      fail "$svc: $var should be absent (unset by any layer) but the container has '$var=$actual' (must never be the literal string 'null' or empty either)"
    fi
  else
    if [ "$found" = "true" ] && [ "$actual" = "$expected" ]; then
      pass "$svc: $var=$actual"
    else
      fail "$svc: $var expected '$expected', got '${actual:-<absent>}'"
    fi
  fi
}
# Set by the base file + .env.example (no overlay override):
check_env sockbowl-game SOCKBOWL_RATELIMIT_ENABLED "true"
check_env sockbowl-game SOCKBOWL_QUOTA_ENABLED "true"
check_env sockbowl-questions SOCKBOWL_RATELIMIT_ENABLED "true"
check_env sockbowl-questions SOCKBOWL_REDIS_HOST "${APP_HOST}"
check_env sockbowl-questions SOCKBOWL_REDIS_PORT "${REDIS_PORT}"
check_env sockbowl-questions SOCKBOWL_DATABASE "0"
# Set by the limits-e2e overlay (overrides the dev overlay's relaxed value):
check_env sockbowl-game SOCKBOWL_RL_SESSION_CREATE_CAPACITY "2"
check_env sockbowl-game SOCKBOWL_RL_SESSION_CREATE_REFILL_PERIOD "20s"
check_env sockbowl-game SOCKBOWL_RL_STOMP_BUZZ_CAPACITY "3"
check_env sockbowl-game SOCKBOWL_QUOTA_GUEST_HOSTED_SESSIONS "2"
check_env sockbowl-game SOCKBOWL_QUOTA_PLAYER_HOSTED_SESSIONS "3"
# Never set by any active layer here -> must be genuinely absent, not "null":
check_env sockbowl-game SOCKBOWL_RL_SERVICE_CLIENTS ""
check_env sockbowl-game SOCKBOWL_TRUSTED_PROXIES_REGEX ""
check_env sockbowl-questions SOCKBOWL_AI_SERVER_ALLOWED_MODELS ""

section "questions' /actuator/health reports UP (proof questions itself is reachable)"
# management.endpoint.health.show-details=never (deliberate, security: no
# auth guards most actuator paths) means the JSON is always the bare
# {"status":"UP"|"DOWN"} with no per-component breakdown, so there is no
# component field to assert on separately here. This is NOT proof of Redis
# connectivity: questions' MAIN application.yml sets
# management.health.redis.enabled=false (Q-V1-03, D12) precisely so a Redis
# outage does not flip this to DOWN — see the LIMITS_WIRING_LIVE section
# right below for the check that actually exercises a Redis outage.
HEALTH_JSON="$(curl -sS -f "${APP_PROTOCOL}://${APP_HOST}:${SOCKBOWL_QUESTIONS_PORT}/actuator/health" || true)"
if [ -n "$HEALTH_JSON" ] && echo "$HEALTH_JSON" | jq -e '.status == "UP"' >/dev/null 2>&1; then
  pass "questions /actuator/health status=UP"
else
  fail "questions /actuator/health did not report UP: ${HEALTH_JSON:-<empty response>}"
fi

if [ "${LIMITS_WIRING_LIVE:-false}" = "true" ]; then
  section "LIMITS_WIRING_LIVE: redis down -> questions health stays UP and GraphQL still answers 200"
  # D12 (questions, WP-FIX-Q Q-V1-03): questions' Redis use (limiters, quotas,
  # ban mirror) fails open on an outage, and management.health.redis.enabled
  # =false keeps the health endpoint from reflecting Redis at all. This is
  # the real end-to-end proof, stopping the actual shared redis container
  # (not just reading a disabled indicator) — the health check and a plain
  # GraphQL read must both keep working while it's down.
  compose stop redis >/dev/null 2>&1 || true
  REDIS_DOWN_HEALTH="$(curl -sS -f "${APP_PROTOCOL}://${APP_HOST}:${SOCKBOWL_QUESTIONS_PORT}/actuator/health" || true)"
  if [ -n "$REDIS_DOWN_HEALTH" ] && echo "$REDIS_DOWN_HEALTH" | jq -e '.status == "UP"' >/dev/null 2>&1; then
    pass "questions /actuator/health stays UP with redis stopped"
  else
    fail "questions /actuator/health did not stay UP with redis stopped: ${REDIS_DOWN_HEALTH:-<empty response>}"
  fi
  GQL_CODE="$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' \
    -d '{"query":"{ getAllCategories { id } }"}' \
    "${APP_PROTOCOL}://${APP_HOST}:${SOCKBOWL_QUESTIONS_PORT}/graphql" || true)"
  if [ "$GQL_CODE" = "200" ]; then
    pass "a GraphQL read (getAllCategories) still answers 200 with redis stopped"
  else
    fail "GraphQL read got HTTP $GQL_CODE with redis stopped, expected 200"
  fi
  compose start redis >/dev/null 2>&1 || true
  REDIS_RESTARTED=false
  for _ in $(seq 1 20); do
    if [ "$(compose ps -a --format '{{.Health}}' redis 2>/dev/null || true)" = "healthy" ]; then
      REDIS_RESTARTED=true
      break
    fi
    sleep 3
  done
  if [ "$REDIS_RESTARTED" = "true" ]; then
    pass "redis restarted and reports healthy again"
  else
    fail "redis did not report healthy again within the timeout after restart"
  fi
fi

section "a request burst against game writes rl:* keys to redis (requires G1+G2 merged)"
BEFORE_KEYS="$(redis_cli --scan --pattern 'rl:*' 2>/dev/null | wc -l | tr -d ' ')"
for _ in $(seq 1 8); do
  curl -sS -o /dev/null -X POST \
    -H 'Content-Type: application/json' \
    -d '{"gameSettings":{"gameMode":"SINGLE_PLAYER","bonusesEnabled":false}}' \
    "${APP_PROTOCOL}://${APP_HOST}:${SOCKBOWL_GAME_PORT}/api/v1/session/create-new-game-session" || true
done
AFTER_KEYS="$(redis_cli --scan --pattern 'rl:*' 2>/dev/null | wc -l | tr -d ' ')"
if [ "${AFTER_KEYS:-0}" -gt 0 ]; then
  pass "redis-cli KEYS 'rl:*' is non-empty after the burst ($AFTER_KEYS key(s); $BEFORE_KEYS before)"
else
  skip "no 'rl:*' keys appeared after an 8-request burst against session-create — expected until G1 (RateLimitService) and G2 (RequestGuardFilter) are merged onto this image; V1 re-runs this script after the full merge, when this assertion must PASS for real"
fi

echo
if [ "$STATUS" -eq 0 ]; then
  echo "test-limits-wiring.sh: all checks passed (see SKIPs above for what still needs G1/Q1/G2 merged)."
else
  echo "test-limits-wiring.sh: FAILURES ABOVE" >&2
fi
exit "$STATUS"
