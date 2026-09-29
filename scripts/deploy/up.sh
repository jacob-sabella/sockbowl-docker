#!/usr/bin/env bash
#
# up.sh — WP-D3 (plans/m7-deploy.md §4.5, §5 L2/L3). A thin, guarded wrapper
# around `docker compose` for the prod overlay: it never invents a command of
# its own, it just supplies the right `-p`/`--env-file`/`-f` flags (so every
# call site — L2's `pull`/`config -q`/`ps`, L3's `up -d`, this WP's local
# rehearsal, a routine app redeploy) uses the exact same project identity and
# guard, and forwards everything after `--` to `docker compose` verbatim.
#
# Usage:
#   scripts/deploy/up.sh [--dry-run] [--project-dir DIR] [--env-file FILE]
#     [--extra-file FILE ...] -- <docker compose args...>
#
# Examples:
#   up.sh --project-dir /home/ubuntu/sockbowl-prod -- config -q
#   up.sh --project-dir /home/ubuntu/sockbowl-prod -- pull kafka postgres redis neo4j
#   up.sh --project-dir /home/ubuntu/sockbowl-prod -- up -d --profile full
#   up.sh --project-dir /home/ubuntu/sockbowl-prod -- ps
#
# Defaults: --project-dir=$REMOTE_DIR, --env-file=<project-dir>/.env. The
# compose file list is always `-f <project-dir>/docker-compose.yml -f
# <project-dir>/docker-compose.prod.yml`, plus any --extra-file (e.g. a local
# rehearsal's throwaway Caddy overlay) in the order given.
#
# Guards (§4.5): refuses when the project dir's basename is "sockbowl-docker",
# when --env-file sets COMPOSE_PROJECT_NAME=sockbowl-docker, and — best-effort,
# since compose only reports SERVICE names, not container names, before
# `up` — when any service name in the rendered config matches mage-*/aa-*/
# watchtower (a config authoring mistake, since this overlay's own services
# never do).
#
# Exit: whatever `docker compose` exits (propagated via `run`, which is a
# straight exec-and-check in non-dry-run mode).
set -euo pipefail
shopt -s inherit_errexit

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_SCRIPT_NAME="up"
# shellcheck source=scripts/deploy/lib.sh
source "$SCRIPT_DIR/lib.sh"

project_dir="$REMOTE_DIR"
env_file=""
extra_files=()
compose_args=()

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --project-dir) project_dir="$2"; shift 2 ;;
    --env-file) env_file="$2"; shift 2 ;;
    --extra-file) extra_files+=("$2"); shift 2 ;;
    --) shift; compose_args=("$@"); break ;;
    -h|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) ddie "unknown argument: $1 (compose args go after --)" ;;
  esac
done
[ -n "$env_file" ] || env_file="$project_dir/.env"
[ "${#compose_args[@]}" -gt 0 ] || ddie "no docker compose arguments given (pass them after --)"

project_name=""
if [ -f "$env_file" ]; then
  project_name="$(grep -E '^COMPOSE_PROJECT_NAME=' "$env_file" | tail -n1 | cut -d= -f2- || true)"
fi
deploy_guard_no_legacy_project "$project_dir" "${project_name:-}"

base_compose="$project_dir/docker-compose.yml"
prod_compose="$project_dir/docker-compose.prod.yml"
[ -f "$base_compose" ] || ddie "not found: $base_compose (did sync-bundle.sh run?)"
[ -f "$prod_compose" ] || ddie "not found: $prod_compose (did sync-bundle.sh run?)"

cmd=(docker compose --env-file "$env_file" -f "$base_compose" -f "$prod_compose")
for f in "${extra_files[@]}"; do
  cmd+=(-f "$f")
done
cmd+=("${compose_args[@]}")

# Best-effort service-name guard: only meaningful once services can actually
# be listed (i.e. always, `docker compose config` needs no running daemon
# call beyond parsing), so it's cheap enough to run before every invocation.
if services="$(docker compose --env-file "$env_file" -f "$base_compose" -f "$prod_compose" config --services 2>/dev/null)"; then
  while IFS= read -r svc; do
    [ -n "$svc" ] || continue
    deploy_guard_container_name "$svc"
  done <<<"$services"
fi

dlog "== up: $(printf '%q ' "${cmd[@]}") =="
run "${cmd[@]}"
