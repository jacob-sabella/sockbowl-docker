#!/usr/bin/env bash
#
# rollback.sh — WP-D3 (plans/m7-deploy.md §4.5, §5's per-step rollbacks). One
# entry point for the three non-L1 rollbacks (L1 needs none: it only ever
# adds new files under ~/sockbowl-backups). Runs directly on the VPS (no ssh
# inside), like the other on-host scripts in this directory.
#
#   --step l2: undo a staged-but-not-started bundle (§5 L2 rollback):
#     `rm -rf <project-dir>` and `docker image rm` of each --image given.
#     The old stack was never touched by L2, so nothing else to do.
#   --step l3: undo a migrated-and-booted new stack, keeping its volumes for
#     forensics, and bring the OLD stack back up exactly as it was (§5 L3
#     rollback): `docker compose -p <new-project> down` (no `-v`), then
#     `docker compose -p sockbowl-docker --env-file <old-env-file> start` in
#     <old-project-dir>, then verify the old containers are Up.
#   --step l4: delegates to caddy-apply.sh --rollback (byte-identical
#     Caddyfile restore + reload) — kept here only as the one place an
#     operator or runbook needs to remember, per §4.5's script list.
#
# Every step refuses the legacy project name/dir as its OWN target (it would
# make no sense to "roll back" onto sockbowl-docker), and every container
# action is guarded the same way as the rest of scripts/deploy/.
#
# Usage:
#   scripts/deploy/rollback.sh --step l2 [--dry-run] --project-dir DIR
#     [--image REF ...]
#   scripts/deploy/rollback.sh --step l3 [--dry-run]
#     --new-project NAME [--new-project-dir DIR]
#     --old-project-dir DIR [--old-env-file FILE]
#   scripts/deploy/rollback.sh --step l4 [--dry-run] --caddyfile PATH
#     --rollback-ts TS [--container NAME]
#
# Exit: 0 on success; 1 on a usage error or a guard refusal.
set -euo pipefail
shopt -s inherit_errexit

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_SCRIPT_NAME="rollback"
# shellcheck source=scripts/deploy/lib.sh
source "$SCRIPT_DIR/lib.sh"

step=""
project_dir=""
images=()
new_project=""
new_project_dir=""
old_project_dir=""
old_env_file=".env.alpha"
caddyfile=""
rollback_ts=""
container="aa-caddy"

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --step) step="$2"; shift 2 ;;
    --project-dir) project_dir="$2"; shift 2 ;;
    --image) images+=("$2"); shift 2 ;;
    --new-project) new_project="$2"; shift 2 ;;
    --new-project-dir) new_project_dir="$2"; shift 2 ;;
    --old-project-dir) old_project_dir="$2"; shift 2 ;;
    --old-env-file) old_env_file="$2"; shift 2 ;;
    --caddyfile) caddyfile="$2"; shift 2 ;;
    --rollback-ts) rollback_ts="$2"; shift 2 ;;
    --container) container="$2"; shift 2 ;;
    -h|--help) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) ddie "unknown argument: $1" ;;
  esac
done

case "$step" in
  l2)
    [ -n "$project_dir" ] || ddie "--project-dir is required for --step l2"
    deploy_guard_no_legacy_project "$project_dir" ""
    dlog "== rollback L2: removing staged bundle $project_dir =="
    run rm -rf "$project_dir"
    for ref in "${images[@]}"; do
      run docker image rm "$ref" || true
    done
    dlog "== rollback L2: done (the old stack was never touched) =="
    ;;

  l3)
    [ -n "$new_project" ] || ddie "--new-project is required for --step l3"
    [ -n "$old_project_dir" ] || ddie "--old-project-dir is required for --step l3"
    deploy_guard_no_legacy_project "${new_project_dir:-/nonexistent}" "$new_project"
    if [ "$(basename -- "$old_project_dir")" != "sockbowl-docker" ]; then
      dwarn "--old-project-dir '$old_project_dir' doesn't look like the legacy 'sockbowl-docker' checkout — double-check this is really the old stack before proceeding"
    fi
    dlog "== rollback L3: down (no -v) for '$new_project', then start the old stack =="
    if [ -n "$new_project_dir" ]; then
      run docker compose -p "$new_project" \
        -f "$new_project_dir/docker-compose.yml" -f "$new_project_dir/docker-compose.prod.yml" down
    else
      run docker compose -p "$new_project" down
    fi
    run docker compose -p sockbowl-docker --env-file "$old_env_file" -f "$old_project_dir/docker-compose.yml" start
    if [ "$DRY_RUN" != "true" ]; then
      up_count="$(docker compose -p sockbowl-docker -f "$old_project_dir/docker-compose.yml" ps --status running --format '{{.Name}}' | wc -l)"
      dlog "old stack containers now running: $up_count"
    fi
    dlog "== rollback L3: done. New stack's volumes were kept (no -v) for forensics, per §5 =="
    ;;

  l4)
    [ -n "$caddyfile" ] || ddie "--caddyfile is required for --step l4"
    [ -n "$rollback_ts" ] || ddie "--rollback-ts is required for --step l4"
    deploy_guard_container_name "$container" "aa-caddy"
    dlog "== rollback L4: delegating to caddy-apply.sh --rollback $rollback_ts =="
    args=(--caddyfile "$caddyfile" --container "$container" --rollback "$rollback_ts")
    if [ "$DRY_RUN" = "true" ]; then args+=(--dry-run); fi
    "$SCRIPT_DIR/caddy-apply.sh" "${args[@]}"
    ;;

  *)
    ddie "--step must be one of: l2, l3, l4 (got '${step:-<empty>}')"
    ;;
esac
