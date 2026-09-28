#!/usr/bin/env bash
#
# wait-healthy.sh — poll a running compose stack until every app/infra
# service reports healthy and every one-shot init job has exited 0.
#
# Factored out of .github/workflows/auth-smoke.yml's inline health loop (M2)
# so scripts/clean-clone-test.sh (M6 CC1) and any future caller share one
# implementation instead of copy-pasting the loop.
#
# Usage (as a script):
#   scripts/lib/wait-healthy.sh [--timeout SECS] [--interval SECS] \
#     [--require svc1,svc2,...] -- <compose command prefix...>
#
# <compose command prefix...> is everything up to but not including the
# subcommand, e.g.:
#   scripts/lib/wait-healthy.sh -- docker compose -p myproj -f docker-compose.yml
# or, run from inside a stack slot (see scripts/clean-clone-test.sh):
#   scripts/lib/wait-healthy.sh -- "$SLOT_SH" "$N" compose -p myproj -f docker-compose.yml
#
# This only ever calls "<prefix> ps ..." and "<prefix> logs ...", which talk
# to the Docker daemon directly (not to the stack's published ports), so it
# never needs to go through `slot.sh exec` itself — see clean-clone-test.sh
# for the probes that do.
#
# Can also be sourced for the wait_healthy() function directly, e.g. from a
# test that already has its own arg parsing:
#   # shellcheck source=lib/wait-healthy.sh
#   source "$ROOT/scripts/lib/wait-healthy.sh"
#   wait_healthy 900 10 "" docker compose -p myproj -f docker-compose.yml
#
# Exit: 0 once everything below is satisfied, 1 on timeout (after dumping
# `ps` and the tail of every unhealthy/non-zero service's logs).
#
#   - HEALTHCHECKED (below) each report Health=healthy.
#   - ONESHOT_INIT (below) each report State=exited, ExitCode=0.
#   - Any extra names passed via --require are treated as additional
#     HEALTHCHECKED entries (for a caller whose stack only brings up a
#     subset, e.g. rbac-reconcile.yml's keycloak+postgres slice).
#
# Requires: jq (used to parse `compose ps --format json`, one JSON object per
# line, matching both the Compose v2 CLI and `docker compose` plugin output).

set -euo pipefail

# Services this repo's docker-compose.yml gives a healthcheck to.
WAIT_HEALTHY_DEFAULT_HEALTHCHECKED="kafka postgres keycloak redis neo4j sockbowl-game sockbowl-questions sockbowl-ng"

# One-shot jobs (restart: "no") that must exit 0. Absent-from-compose is not
# a failure (a caller's overlay subset may not define all of them); still
# pending (no container yet, or still running) keeps the wait going.
WAIT_HEALTHY_ONESHOT_INIT="keycloak-realm-init rbac-init neo4j-plugin-init neo4j-data-import"

wait_healthy() {
  local timeout="${1:?timeout seconds required}"
  local interval="${2:?interval seconds required}"
  local extra_required="${3:-}"
  shift 3
  local -a compose=("$@")
  [ "${#compose[@]}" -gt 0 ] || { echo "wait_healthy: no compose command given" >&2; return 2; }

  local healthchecked="$WAIT_HEALTHY_DEFAULT_HEALTHCHECKED"
  if [ -n "$extra_required" ]; then
    healthchecked="$healthchecked ${extra_required//,/ }"
  fi

  local deadline=$(( $(date +%s) + timeout ))
  local attempt=0
  while true; do
    attempt=$((attempt + 1))
    local json
    json="$("${compose[@]}" ps -a --format json 2>/dev/null || true)"

    local all_ok=1
    local svc health state
    echo "--- $(date -u +%FT%TZ) wait_healthy attempt $attempt ---"
    for svc in $healthchecked; do
      health="$(echo "$json" | jq -rs --arg s "$svc" 'map(select(.Service==$s)) | .[0].Health // "absent"' 2>/dev/null || echo absent)"
      echo "  healthcheck: $svc -> $health"
      [ "$health" = "healthy" ] || all_ok=0
    done
    for svc in $WAIT_HEALTHY_ONESHOT_INIT; do
      state="$(echo "$json" | jq -rs --arg s "$svc" 'map(select(.Service==$s)) | .[0] | if . == null then "absent" else (.State + ":" + (.ExitCode|tostring)) end' 2>/dev/null || echo absent)"
      echo "  init job:    $svc -> $state"
      case "$state" in
        absent) ;; # not part of this stack; not a failure
        exited:0) ;;
        *) all_ok=0 ;;
      esac
    done

    if [ "$all_ok" -eq 1 ]; then
      echo "wait_healthy: all services healthy, all init jobs exited 0"
      return 0
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "wait_healthy: TIMEOUT after ${timeout}s" >&2
      "${compose[@]}" ps -a || true
      for svc in $healthchecked $WAIT_HEALTHY_ONESHOT_INIT; do
        echo "=== logs: $svc (tail 100) ===" >&2
        "${compose[@]}" logs --tail=100 "$svc" >&2 2>&1 || true
      done
      return 1
    fi
    sleep "$interval"
  done
}

# Only parse args and run when executed directly, not when sourced.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  timeout=900
  interval=10
  require=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --timeout) timeout="$2"; shift 2 ;;
      --interval) interval="$2"; shift 2 ;;
      --require) require="$2"; shift 2 ;;
      --) shift; break ;;
      *) echo "wait-healthy.sh: unknown arg $1" >&2; exit 2 ;;
    esac
  done
  wait_healthy "$timeout" "$interval" "$require" "$@"
fi
