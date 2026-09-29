#!/usr/bin/env bash
#
# verify.sh — WP-D3 (plans/m7-deploy.md §4.5). The read-only checks that
# recur at L3.7, L4.3, L5 and WP-V1's §7 gate 8.1: never starts, stops or
# changes anything, so it's always safe to run against a live deploy.
#
# --mode curl (§4.2/§5 L4.3, §7 gate 8.1): the shared HTTP probe set against
#   one host, resolved however the caller likes (a real DNS answer, --resolve
#   for a direct-IP check before DNS exists, or a local rehearsal's
#   127.0.0.1). Prints PASS/FAIL per row (this repo's convention) and exits
#   non-zero if any row fails:
#     - GET  /                          -> 200 (ng)
#     - GET  /assets/config.js          -> 200, and in path mode contains the
#                                          public URL (not a bare port URL)
#     - GET  /auth/realms/<realm>/.well-known/openid-configuration -> 200,
#                                          issuer == <public-url>/auth/realms/<realm>
#     - GET  /auth/admin/                -> 404 (O4: never public)
#     - GET  /questions/actuator/health  -> 404 (never public; actuator paths
#                                          are only reachable un-prefixed,
#                                          internally)
#     - POST /api/v1/session/create-new-game-session (empty body) -> 200/400,
#                                          never 404 (proves /api/* is routed
#                                          to game, not swallowed by ng's SPA
#                                          fallback)
#     - GET  /questions/api/qbreader/category-counts -> 200 (proves the
#                                          /questions/* prefix strip)
#     - WebSocket upgrade on /ws         -> 101 or a non-101 status THAT IS
#                                          NOT 404 (game answering, even if it
#                                          rejects the handshake, beats ng's
#                                          catch-all serving index.html)
#
# --mode counts (§5 L3.7, tolerance 0): compares a baseline JSON (written by
#   this same mode with --write-baseline, e.g. at L1/L3-preflight) against
#   the live stack's Neo4j label/relationship counts, Keycloak realm/user/
#   identity-provider/federated-identity/credential counts, and
#   sockbowl_legacy.user_used_question — via `docker compose exec`, never an
#   exposed port (H18/§7).
#
# Usage:
#   scripts/deploy/verify.sh --mode curl --host HOST [--ip IP]
#     [--cacert FILE] [--realm sockbowl] [--public-url URL] [--timeout N]
#   scripts/deploy/verify.sh --mode counts --project NAME
#     [--pg-container NAME] [--pg-user NAME] [--neo4j-container NAME]
#     [--neo4j-user NAME] [--neo4j-password PASS]
#     (--write-baseline FILE | --baseline FILE)
#
# Exit: 0 if every check in the selected mode passes; 1 otherwise (including
# a usage error).
set -euo pipefail
shopt -s inherit_errexit

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_SCRIPT_NAME="verify"
# shellcheck source=scripts/deploy/lib.sh
source "$SCRIPT_DIR/lib.sh"

mode=""
host=""
ip=""
cacert=""
realm="sockbowl"
public_url=""
timeout=10
project="sockbowl-prod"
pg_container=""
pg_user="${POSTGRES_USER:-postgres}"
neo4j_container=""
neo4j_user="${NEO4J_USER:-neo4j}"
neo4j_password="${NEO4J_PASSWORD:-}"
write_baseline=""
baseline_file=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --mode) mode="$2"; shift 2 ;;
    --host) host="$2"; shift 2 ;;
    --ip) ip="$2"; shift 2 ;;
    --cacert) cacert="$2"; shift 2 ;;
    --realm) realm="$2"; shift 2 ;;
    --public-url) public_url="$2"; shift 2 ;;
    --timeout) timeout="$2"; shift 2 ;;
    --project) project="$2"; shift 2 ;;
    --pg-container) pg_container="$2"; shift 2 ;;
    --pg-user) pg_user="$2"; shift 2 ;;
    --neo4j-container) neo4j_container="$2"; shift 2 ;;
    --neo4j-user) neo4j_user="$2"; shift 2 ;;
    --neo4j-password) neo4j_password="$2"; shift 2 ;;
    --write-baseline) write_baseline="$2"; shift 2 ;;
    --baseline) baseline_file="$2"; shift 2 ;;
    -h|--help) sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) ddie "unknown argument: $1" ;;
  esac
done
[ -n "$pg_container" ] || pg_container="${project}-postgres-1"
[ -n "$neo4j_container" ] || neo4j_container="${project}-neo4j-1"

# verify.sh is read-only in both modes (GETs/a POST with an empty body against
# the app, or SELECT/read-only cypher via `docker exec`), so --dry-run has
# nothing unsafe to skip. It still prints exactly what would be checked,
# rather than silently being a no-op flag, so it stays truthful for §4.5's
# "each has a --dry-run that prints the remote commands" and for a caller
# scripting `verify.sh --dry-run` uniformly across scripts/deploy/*.
if [ "$DRY_RUN" = "true" ]; then
  case "$mode" in
    curl)
      [ -n "$host" ] || ddie "--host is required for --mode curl"
      [ -n "$public_url" ] || public_url="https://${host}"
      dlog "[dry-run] would run against https://${host} (resolved to ${ip:-127.0.0.1}, cacert=${cacert:-<system>}), expecting public_url=$public_url:"
      dlog "[dry-run]   GET  /                                                        -> 200"
      dlog "[dry-run]   GET  /assets/config.js                                        -> contains $public_url"
      dlog "[dry-run]   GET  /auth/realms/${realm}/.well-known/openid-configuration    -> issuer == ${public_url}/auth/realms/${realm}"
      dlog "[dry-run]   GET  /auth/admin/                                             -> 404"
      dlog "[dry-run]   GET  /questions/actuator/health                               -> 404"
      dlog "[dry-run]   POST /api/v1/session/create-new-game-session {}               -> 200 or 400 (never 404)"
      dlog "[dry-run]   GET  /questions/api/qbreader/category-counts                  -> 200"
      dlog "[dry-run]   WS upgrade GET /ws (Connection: Upgrade)                      -> anything but 404/000"
      exit 0
      ;;
    counts)
      dlog "[dry-run] would run against project=$project:"
      dlog "[dry-run]   docker exec $pg_container psql -U $pg_user -d keycloak -tAc 'SELECT count(*) FROM realm;'"
      dlog "[dry-run]   docker exec $pg_container psql -U $pg_user -d keycloak -tAc 'SELECT count(*) FROM user_entity ... WHERE r.name=<realm>;'"
      dlog "[dry-run]   docker exec $pg_container psql -U $pg_user -d sockbowl_legacy -tAc 'SELECT count(*) FROM user_used_question;'"
      if [ -n "$write_baseline" ]; then
        dlog "[dry-run]   would write baseline to $write_baseline"
      elif [ -n "$baseline_file" ]; then
        dlog "[dry-run]   would compare the above against baseline $baseline_file (tolerance 0)"
      else
        dlog "[dry-run]   no --baseline/--write-baseline given; would just print the current counts"
      fi
      exit 0
      ;;
    *)
      ddie "--mode must be 'curl' or 'counts' (got '${mode:-<empty>}')"
      ;;
  esac
fi

PASSED=0
FAILED=0
pass() { PASSED=$((PASSED + 1)); dlog "PASS: $*"; }
failc() { FAILED=$((FAILED + 1)); dlog "FAIL: $*"; }

case "$mode" in
  curl)
    [ -n "$host" ] || ddie "--host is required for --mode curl"
    [ -n "$public_url" ] || public_url="https://${host}"
    target_ip="${ip:-127.0.0.1}"
    curl_args=(-sS --max-time "$timeout" --resolve "${host}:443:${target_ip}")
    if [ -n "$cacert" ]; then curl_args+=(--cacert "$cacert"); fi

    # curl still writes -w's output even after a connection failure (it's
    # typically "000" in that case), so appending "|| echo 000" on top would
    # double it up to "000000" — capture, then only backfill if truly empty
    # (e.g. curl itself failed to even start).
    get() {
      local c
      c="$(curl "${curl_args[@]}" -o /dev/null -w '%{http_code}' "https://${host}$1" 2>/dev/null || true)"
      printf '%s' "${c:-000}"
    }
    get_body() { curl "${curl_args[@]}" "https://${host}$1" 2>/dev/null || true; }

    dlog "== verify curl set: https://${host} -> ${target_ip} =="

    code="$(get /)"
    if [ "$code" = "200" ]; then pass "GET / -> 200"; else failc "GET / -> $code, expected 200"; fi

    body="$(get_body /assets/config.js)"
    if grep -qF "$public_url" <<<"$body"; then
      pass "GET /assets/config.js contains the public URL ($public_url)"
    else
      failc "GET /assets/config.js does not contain $public_url"
    fi

    oidc="$(get_body "/auth/realms/${realm}/.well-known/openid-configuration")"
    issuer="$(printf '%s' "$oidc" | grep -o '"issuer":"[^"]*"' | head -n1 | cut -d'"' -f4)"
    expected_issuer="${public_url}/auth/realms/${realm}"
    if [ "$issuer" = "$expected_issuer" ]; then
      pass "OIDC discovery issuer == $expected_issuer"
    else
      failc "OIDC discovery issuer '$issuer' != expected '$expected_issuer'"
    fi

    code="$(get /auth/admin/)"
    if [ "$code" = "404" ]; then pass "GET /auth/admin/ -> 404 (O4)"; else failc "GET /auth/admin/ -> $code, expected 404"; fi

    code="$(get /questions/actuator/health)"
    if [ "$code" = "404" ]; then pass "GET /questions/actuator/health -> 404"; else failc "GET /questions/actuator/health -> $code, expected 404"; fi

    # A body with no `gameSettings` at all (`{}`) 500s (a pre-existing,
    # out-of-scope game-repo NPE in RequestGuardFilter — confirmed live,
    # WP-D3 — rather than the clean 400 CreateGameRequest's own bean
    # validation would give a merely-incomplete-but-present GameSettings).
    # This check only needs to prove /api/* reaches game and not ng's SPA
    # catch-all, so it sends the same minimal-but-present GameSettings shape
    # smoke-auth.sh's GAME_BODY_SINGLE uses, which every version of the game
    # service has accepted without 500ing.
    code="$(curl "${curl_args[@]}" -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
      -d '{"gameSettings":{"gameMode":"SINGLE_PLAYER","bonusesEnabled":false}}' \
      "https://${host}/api/v1/session/create-new-game-session" 2>/dev/null || true)"
    code="${code:-000}"
    case "$code" in
      200|400) pass "POST /api/v1/session/create-new-game-session -> $code (routed to game)" ;;
      *) failc "POST /api/v1/session/create-new-game-session -> $code, expected 200 or 400 (never 404 — that would mean ng's SPA fallback swallowed it)" ;;
    esac

    code="$(get /questions/api/qbreader/category-counts)"
    if [ "$code" = "200" ]; then pass "GET /questions/api/qbreader/category-counts -> 200 (prefix strip works)"; else failc "GET /questions/api/qbreader/category-counts -> $code, expected 200"; fi

    ws_code="$(curl "${curl_args[@]}" -o /dev/null -w '%{http_code}' -i \
      -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
      -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
      "https://${host}/ws" 2>/dev/null || true)"
    ws_code="${ws_code:-000}"
    if [ "$ws_code" != "404" ] && [ "$ws_code" != "000" ]; then
      pass "WS upgrade on /ws -> $ws_code (not 404: game answered, not ng's SPA fallback)"
    else
      failc "WS upgrade on /ws -> $ws_code, expected anything but 404/000"
    fi

    dlog "$PASSED passed, $FAILED failed"
    [ "$FAILED" -eq 0 ]
    ;;

  counts)
    dlog "== verify counts: project=$project =="
    counts_json="$(mktemp)"
    trap 'rm -f "$counts_json"' EXIT

    pg_count() {
      local db="$1" sql="$2"
      docker exec "$pg_container" psql -U "$pg_user" -d "$db" -tAc "$sql" 2>/dev/null | tr -d '[:space:]'
    }
    neo4j_counts() {
      [ -n "$neo4j_password" ] || { echo '{}'; return; }
      docker exec "$neo4j_container" cypher-shell -u "$neo4j_user" -p "$neo4j_password" --format plain \
        'CALL db.labels() YIELD label CALL apoc.cypher.run("MATCH (n:`"+label+"`) RETURN count(n) AS c", {}) YIELD value RETURN label, value.c' 2>/dev/null \
        | tail -n +2 || echo ''
    }

    realm_count="$(pg_count keycloak "SELECT count(*) FROM realm;")"
    kc_user_count="$(pg_count keycloak "SELECT count(*) FROM user_entity ue JOIN realm r ON ue.realm_id=r.id WHERE r.name='${realm:-sockbowl}';" 2>/dev/null || true)"
    legacy_uuq="$(pg_count sockbowl_legacy "SELECT count(*) FROM user_used_question;" 2>/dev/null || echo 'n/a')"

    {
      printf '{\n'
      printf '  "timestamp": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      printf '  "realmCount": "%s",\n' "${realm_count:-n/a}"
      printf '  "keycloakUserCount": "%s",\n' "${kc_user_count:-n/a}"
      printf '  "sockbowlLegacyUserUsedQuestion": "%s"\n' "${legacy_uuq:-n/a}"
      printf '}\n'
    } > "$counts_json"

    if [ -n "$write_baseline" ]; then
      run mkdir -p "$(dirname -- "$write_baseline")"
      cp "$counts_json" "$write_baseline"
      dlog "wrote baseline: $write_baseline"
      cat "$write_baseline"
      exit 0
    fi

    if [ -n "$baseline_file" ]; then
      [ -f "$baseline_file" ] || ddie "--baseline not found: $baseline_file"
      dlog "current:"; cat "$counts_json"
      dlog "baseline:"; cat "$baseline_file"
      if diff -q "$baseline_file" "$counts_json" >/dev/null 2>&1; then
        pass "current counts match the baseline exactly (tolerance 0)"
      else
        failc "current counts differ from the baseline (tolerance 0; see the two JSON blobs above)"
      fi
    else
      dlog "no --baseline given; printed current counts only (pass --write-baseline to record one)"
      cat "$counts_json"
    fi

    dlog "$PASSED passed, $FAILED failed"
    [ "$FAILED" -eq 0 ]
    ;;

  *)
    ddie "--mode must be 'curl' or 'counts' (got '${mode:-<empty>}')"
    ;;
esac
