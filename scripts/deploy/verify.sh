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
# --mode counts (§5 L3.7, §7 gate 6, tolerance 0): builds a full counts JSON
#   — Postgres (sockbowl_legacy's bans/user_game_history/user_stats/users/
#   user_used_question, plus keycloak_db_size), Keycloak (realm/user/
#   service-account/credential/identity-provider/federated-identity counts,
#   loginTheme, sslRequired) and Neo4j (every label count, every
#   relationship-type count, the full constraint name list and the index
#   count) — via `docker exec`, never an exposed port (H18/§7). Which
#   section(s) to query is controlled by --sections (default: all three), so
#   the same script can also produce a Neo4j-only counts file from a scratch
#   container that has no Postgres/Keycloak at all (§7 gate 6's
#   independently-loaded source-dump comparison).
#
#   With --write-baseline FILE, writes the JSON there (this is what L1/
#   L3-preflight, and a source-dump rehearsal load, use to record a target).
#
#   With --baseline FILE, compares the live counts against that JSON at
#   TOLERANCE 0, section by section, with ONLY the following documented,
#   named exceptions (everything else, including every label/relationship
#   count, must match exactly or the check fails):
#     - Keycloak sockbowlRealmUserCount / sockbowlRealmCredentialCount may
#       be higher than the baseline by exactly --allow-realm-user-delta /
#       --allow-realm-credential-delta (default 0 each; pass
#       --verify-overlay-seeded as shorthand for "5 and 5", matching the 5
#       demo users keycloak/rbac-model.json defines and
#       scripts/deploy/verify.compose.yml seeds — never present against a
#       real, non-rehearsal stack).
#     - Keycloak sslRequired: baseline "NONE" -> current "external" is
#       always allowed (D1: the migrated realm's stale NONE setting is
#       intentionally fixed by this deploy's own realm-settings.json, not a
#       migration defect). Any other sslRequired change fails.
#     - Neo4j constraints: a name may appear in current but not in baseline
#       only if it was passed via --allow-added-constraint (repeatable) —
#       e.g. category_namekey/difficulty_namekey, added by the questions
#       startup migrations (D4). A constraint present in baseline but
#       missing from current always fails (that would be data loss).
#     - Neo4j indexCount: allowed to be higher than baseline by exactly the
#       number of --allow-added-constraint names given (each constraint
#       backs exactly one index) — no other indexCount delta is allowed.
#   Every Neo4j label and relationship-type count must match at tolerance 0
#   with NO exception in any case — those are the actual migrated data, and
#   this mode exists specifically to catch data loss in them.
#
# Usage:
#   scripts/deploy/verify.sh --mode curl --host HOST [--ip IP]
#     [--cacert FILE] [--realm sockbowl] [--public-url URL] [--timeout N]
#   scripts/deploy/verify.sh --mode counts --project NAME
#     [--sections postgres,keycloak,neo4j] [--sockbowl-db sockbowl_legacy]
#     [--pg-container NAME] [--pg-user NAME] [--realm sockbowl]
#     [--neo4j-container NAME] [--neo4j-user NAME] [--neo4j-password PASS]
#     [--verify-overlay-seeded] [--allow-realm-user-delta N]
#     [--allow-realm-credential-delta N]
#     [--allow-added-constraint NAME ...]
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
sections="postgres,keycloak,neo4j"
sockbowl_db="sockbowl_legacy"
allow_realm_user_delta=0
allow_realm_credential_delta=0
allow_added_constraints=()

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
    --sockbowl-db) sockbowl_db="$2"; shift 2 ;;
    --neo4j-container) neo4j_container="$2"; shift 2 ;;
    --neo4j-user) neo4j_user="$2"; shift 2 ;;
    --neo4j-password) neo4j_password="$2"; shift 2 ;;
    --write-baseline) write_baseline="$2"; shift 2 ;;
    --baseline) baseline_file="$2"; shift 2 ;;
    --sections) sections="$2"; shift 2 ;;
    --verify-overlay-seeded) allow_realm_user_delta=5; allow_realm_credential_delta=5; shift ;;
    --allow-realm-user-delta) allow_realm_user_delta="$2"; shift 2 ;;
    --allow-realm-credential-delta) allow_realm_credential_delta="$2"; shift 2 ;;
    --allow-added-constraint) allow_added_constraints+=("$2"); shift 2 ;;
    -h|--help) sed -n '2,87p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
      dlog "[dry-run] would run against project=$project, sections=$sections:"
      want_section_dry() { case ",$sections," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }
      if want_section_dry postgres; then
        dlog "[dry-run]   docker exec $pg_container psql -U $pg_user -d keycloak -tAc 'SELECT pg_size_pretty(pg_database_size(...));'"
        dlog "[dry-run]   docker exec $pg_container psql -U $pg_user -d $sockbowl_db -tAc 'SELECT count(*) FROM {bans,user_game_history,user_stats,users,user_used_question};'"
      fi
      if want_section_dry keycloak; then
        dlog "[dry-run]   docker exec $pg_container psql -U $pg_user -d keycloak -tAc 'SELECT count(*) FROM realm;' (+ user/service-account/credential/identity-provider/federated-identity/loginTheme/sslRequired, scoped to realm=$realm)"
      fi
      if want_section_dry neo4j; then
        dlog "[dry-run]   docker exec $neo4j_container cypher-shell -u $neo4j_user -p *** 'CALL db.labels() ... / db.relationshipTypes() ... / SHOW CONSTRAINTS / SHOW INDEXES'"
      fi
      if [ -n "$write_baseline" ]; then
        dlog "[dry-run]   would write baseline to $write_baseline"
      elif [ -n "$baseline_file" ]; then
        dlog "[dry-run]   would compare the above against baseline $baseline_file (tolerance 0, allowlist: realm-user-delta=$allow_realm_user_delta realm-credential-delta=$allow_realm_credential_delta allow-added-constraints=${allow_added_constraints[*]:-<none>})"
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
    IFS=',' read -r -a section_list <<<"$sections"
    want_section() {
      local s
      for s in "${section_list[@]}"; do [ "$s" = "$1" ] && return 0; done
      return 1
    }
    dlog "== verify counts: project=$project sections=$sections =="

    pg_count() {
      local db="$1" sql="$2"
      docker exec "$pg_container" psql -U "$pg_user" -d "$db" -tAc "$sql" 2>/dev/null | tr -d '[:space:]'
    }
    # neo4j_query <cypher> — plain-format cypher-shell output (header row
    # included), via `docker exec`, never an exposed port.
    neo4j_query() {
      docker exec "$neo4j_container" cypher-shell -u "$neo4j_user" -p "$neo4j_password" --format plain "$1" 2>/dev/null
    }
    # neo4j_kv_json <cypher> — runs a two-column "name, count" cypher query,
    # strips the header row, and turns it into a {"name": count, ...} JSON
    # object. Splits on the LAST comma (awk's `sub(/,[^,]*$/,...)` trick, the
    # same rsplit-from-the-right approach L1's own baseline script uses in
    # Python), so it stays correct even if a label/relationship-type name
    # ever contained a comma; none of ours do today.
    neo4j_kv_json() {
      neo4j_query "$1" | tail -n +2 \
        | awk -F',' 'NF>=2{v=$NF; gsub(/[ "]/,"",v); k=$0; sub(/,[^,]*$/,"",k); gsub(/[ "]/,"",k); if(k!="") printf "%s\t%s\n",k,v}' \
        | jq -R -s 'split("\n") | map(select(length>0) | split("\t")) | map({(.[0]): (.[1]|tonumber)}) | add // {}'
    }
    # neo4j_list_json <cypher> — a single-column query -> a sorted JSON
    # array of strings (used for the constraint name list).
    neo4j_list_json() {
      neo4j_query "$1" | tail -n +2 | sed 's/^"//; s/"$//' \
        | jq -R -s 'split("\n") | map(select(length>0)) | sort'
    }

    postgres_json='null'
    if want_section postgres; then
      [ -n "$pg_container" ] || ddie "--pg-container is required for section 'postgres'"
      kc_size="$(pg_count keycloak "SELECT pg_size_pretty(pg_database_size('keycloak'));")"
      sb_bans="$(pg_count "$sockbowl_db" "SELECT count(*) FROM bans;")"
      sb_ugh="$(pg_count "$sockbowl_db" "SELECT count(*) FROM user_game_history;")"
      sb_ustats="$(pg_count "$sockbowl_db" "SELECT count(*) FROM user_stats;")"
      sb_users="$(pg_count "$sockbowl_db" "SELECT count(*) FROM users;")"
      sb_uuq="$(pg_count "$sockbowl_db" "SELECT count(*) FROM user_used_question;")"
      postgres_json="$(jq -n \
        --arg kc_size "${kc_size:-n/a}" --arg bans "${sb_bans:-n/a}" --arg ugh "${sb_ugh:-n/a}" \
        --arg ustats "${sb_ustats:-n/a}" --arg users "${sb_users:-n/a}" --arg uuq "${sb_uuq:-n/a}" \
        '{keycloak_db_size: $kc_size, sockbowl: {bans: $bans, user_game_history: $ugh, user_stats: $ustats, users: $users, user_used_question: $uuq}}')"
    fi

    keycloak_json='null'
    if want_section keycloak; then
      [ -n "$pg_container" ] || ddie "--pg-container is required for section 'keycloak'"
      realm_count="$(pg_count keycloak "SELECT count(*) FROM realm;")"
      kc_users="$(pg_count keycloak "SELECT count(*) FROM user_entity ue JOIN realm r ON ue.realm_id=r.id WHERE r.name='${realm}';")"
      kc_svc="$(pg_count keycloak "SELECT count(*) FROM user_entity ue JOIN realm r ON ue.realm_id=r.id WHERE r.name='${realm}' AND ue.service_account_client_link IS NOT NULL;")"
      kc_creds="$(pg_count keycloak "SELECT count(*) FROM credential c JOIN user_entity ue ON c.user_id=ue.id JOIN realm r ON ue.realm_id=r.id WHERE r.name='${realm}';")"
      kc_idp="$(pg_count keycloak "SELECT count(*) FROM identity_provider idp JOIN realm r ON idp.realm_id=r.id WHERE r.name='${realm}' AND idp.enabled=true;")"
      kc_fedid="$(pg_count keycloak "SELECT count(*) FROM federated_identity fi JOIN user_entity ue ON fi.user_id=ue.id JOIN realm r ON ue.realm_id=r.id WHERE r.name='${realm}';")"
      kc_theme="$(pg_count keycloak "SELECT value FROM realm_attribute WHERE realm_id=(SELECT id FROM realm WHERE name='${realm}') AND name='loginTheme';")"
      # KC 26 moved login_theme to a first-class column on realm; fall back
      # to it when the KC23-era realm_attribute row is empty (V1(b) found
      # this — see audit/m7/v1-local.md).
      [ -n "$kc_theme" ] || kc_theme="$(pg_count keycloak "SELECT login_theme FROM realm WHERE name='${realm}';")"
      kc_ssl="$(pg_count keycloak "SELECT ssl_required FROM realm WHERE name='${realm}';")"
      keycloak_json="$(jq -n \
        --arg realmCount "${realm_count:-n/a}" --arg users "${kc_users:-n/a}" --arg svc "${kc_svc:-n/a}" \
        --arg creds "${kc_creds:-n/a}" --arg idp "${kc_idp:-n/a}" --arg fedid "${kc_fedid:-n/a}" \
        --arg theme "${kc_theme:-n/a}" --arg ssl "${kc_ssl:-n/a}" \
        '{realmCount: $realmCount, sockbowlRealmUserCount: $users, sockbowlRealmServiceAccountUserCount: $svc,
          sockbowlRealmCredentialCount: $creds, sockbowlRealmEnabledIdentityProviderCount: $idp,
          sockbowlRealmFederatedIdentityCount: $fedid, loginTheme: $theme, sslRequired: $ssl}')"
    fi

    neo4j_json='null'
    if want_section neo4j; then
      [ -n "$neo4j_password" ] || ddie "--neo4j-password is required for section 'neo4j'"
      labels_json="$(neo4j_kv_json 'CALL db.labels() YIELD label CALL apoc.cypher.run("MATCH (n:`"+label+"`) RETURN count(n) AS c", {}) YIELD value RETURN label, value.c ORDER BY label')"
      rels_json="$(neo4j_kv_json 'CALL db.relationshipTypes() YIELD relationshipType CALL apoc.cypher.run("MATCH ()-[r:`"+relationshipType+"`]->() RETURN count(r) AS c", {}) YIELD value RETURN relationshipType, value.c ORDER BY relationshipType')"
      constraints_json="$(neo4j_list_json 'SHOW CONSTRAINTS YIELD name RETURN name ORDER BY name')"
      idx_count="$(neo4j_query 'SHOW INDEXES YIELD name RETURN count(*) AS c' | tail -n +2 | tr -d '[:space:]"')"
      [ -n "$labels_json" ] || labels_json='{}'
      [ -n "$rels_json" ] || rels_json='{}'
      [ -n "$constraints_json" ] || constraints_json='[]'
      neo4j_json="$(jq -n \
        --argjson labels "$labels_json" --argjson relationships "$rels_json" \
        --argjson constraints "$constraints_json" --arg indexCount "${idx_count:-n/a}" \
        '{labels: $labels, relationships: $relationships, constraints: $constraints, indexCount: $indexCount}')"
    fi

    counts_json="$(jq -n \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --argjson postgres "$postgres_json" --argjson keycloak "$keycloak_json" --argjson neo4j "$neo4j_json" \
      '{timestamp: $ts} + (if $postgres != null then {postgres: $postgres} else {} end)
        + (if $keycloak != null then {keycloak: $keycloak} else {} end)
        + (if $neo4j != null then {neo4j: $neo4j} else {} end)')"

    if [ -n "$write_baseline" ]; then
      run mkdir -p "$(dirname -- "$write_baseline")"
      printf '%s\n' "$counts_json" | jq -S '.' > "$write_baseline"
      dlog "wrote baseline: $write_baseline"
      cat "$write_baseline"
      exit 0
    fi

    if [ -n "$baseline_file" ]; then
      [ -f "$baseline_file" ] || ddie "--baseline not found: $baseline_file"
      dlog "current:"; printf '%s\n' "$counts_json" | jq -S '.'
      dlog "baseline:"; jq -S '.' "$baseline_file"
      allow_constraints_json="$(printf '%s\n' "${allow_added_constraints[@]}" | jq -R 'select(length>0)' | jq -s '.')"
      sections_json="$(printf '%s\n' "${section_list[@]}" | jq -R . | jq -s '.')"
      mismatches="$(jq -n -r \
        --argjson current "$counts_json" \
        --argjson baseline "$(jq -S '.' "$baseline_file")" \
        --argjson sections "$sections_json" \
        --argjson userDelta "$allow_realm_user_delta" \
        --argjson credDelta "$allow_realm_credential_delta" \
        --argjson allowConstraints "$allow_constraints_json" \
        -f "$SCRIPT_DIR/verify-counts-compare.jq")"
      if [ -z "$mismatches" ]; then
        pass "current counts match the baseline at tolerance 0 (sections: $sections; allowlist: realm-user-delta=$allow_realm_user_delta realm-credential-delta=$allow_realm_credential_delta allow-added-constraints=${allow_added_constraints[*]:-<none>})"
      else
        while IFS= read -r line; do failc "$line"; done <<<"$mismatches"
      fi
    else
      dlog "no --baseline given; printed current counts only (pass --write-baseline to record one)"
      printf '%s\n' "$counts_json" | jq -S '.'
    fi

    dlog "$PASSED passed, $FAILED failed"
    [ "$FAILED" -eq 0 ]
    ;;

  *)
    ddie "--mode must be 'curl' or 'counts' (got '${mode:-<empty>}')"
    ;;
esac
