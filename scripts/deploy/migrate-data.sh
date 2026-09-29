#!/usr/bin/env bash
#
# migrate-data.sh — WP-D3 (plans/m7-deploy.md §4.5, §5 L3 steps 1-6; step 7's
# checks are scripts/deploy/verify.sh, called at the end). This is the
# DISRUPTIVE step: it stops the OLD stack (project sockbowl-docker only —
# never mage-*/aa-*) and boots the new one on migrated data. WP-D3 authors
# and dry-runs this script; running it for real against the live VPS is
# WP-L3's job (opus-supervised), not this one's, and this WP never executes
# it outside --dry-run (no VPS contact, per the loop's guardrails).
#
# Orchestrates, in order (each substep is also individually re-runnable by
# hand from its own script if migrate-data.sh has to be resumed partway):
#   1. Stop the old stack: `docker compose -p sockbowl-docker --env-file
#      <old-env-file> stop` in <old-project-dir>. Refuses to touch any other
#      project's containers (the guard only ever targets "sockbowl-docker").
#   2. Offline Neo4j dump with the OLD binary: scripts/deploy/backup.sh
#      --mode offline-neo4j.
#   3. Neo4j load into a NEW volume with the NEW binary
#      (`docker volume create` with the compose-adoption labels, then
#      `neo4j-admin database load --overwrite-destination=true`).
#   4. Postgres 13 -> 18: `up.sh -- up -d postgres` (new/empty), then
#      `pg_restore --no-owner --role=$POSTGRES_USER -d keycloak` and
#      `createdb sockbowl_legacy && pg_restore -d sockbowl_legacy` (O9).
#   5. Keycloak: `up.sh -- up -d keycloak-realm-init keycloak`, wait for
#      /auth/health/ready, then `rotate-kc-admin.sh` (WP KC-ROT: rotates the
#      migrated master admin password away from old prod's well-known
#      default — see its own header), then `up.sh -- up rbac-init` (the
#      exact-set reconcile, WP-D1).
#   6. Everything else: `up.sh -- up -d --profile full`.
#   7. Verification: scripts/deploy/verify.sh --mode counts (against
#      --baseline, tolerance 0) — the internal curl checks are
#      `verify.sh --mode curl` run separately once the stack is up (this
#      script does not call it, since that needs a resolvable host/edge
#      network the caller already has open).
#
# Usage:
#   scripts/deploy/migrate-data.sh [--dry-run]
#     --old-project-dir DIR [--old-env-file FILE]
#     --new-project-dir DIR --new-project NAME
#     --neo4j-old-image REF --neo4j-new-image REF
#     --neo4j-old-volume NAME --neo4j-new-volume NAME
#     --neo4j-backup-dir DIR
#     --keycloak-dump FILE --sockbowl-dump FILE
#     --pg-container NAME --pg-user NAME
#     --baseline FILE
#
# Exit: 0 on success (or, under --dry-run, once every step has been printed).
# 1 on a usage error, a guard refusal, or any substep's real failure
# (set -e propagates it — this script does not attempt automatic rollback;
# see scripts/deploy/rollback.sh --step l3).
set -euo pipefail
shopt -s inherit_errexit

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_SCRIPT_NAME="migrate-data"
# shellcheck source=scripts/deploy/lib.sh
source "$SCRIPT_DIR/lib.sh"

old_project_dir=""
old_env_file=".env.alpha"
new_project_dir=""
new_project="sockbowl-prod"
neo4j_old_image=""
neo4j_new_image="neo4j:2026.09"
neo4j_old_volume=""
neo4j_new_volume=""
neo4j_backup_dir=""
keycloak_dump=""
sockbowl_dump=""
pg_container=""
pg_user="${POSTGRES_USER:-postgres}"
baseline_file=""
kc_ready_timeout=180

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --old-project-dir) old_project_dir="$2"; shift 2 ;;
    --old-env-file) old_env_file="$2"; shift 2 ;;
    --new-project-dir) new_project_dir="$2"; shift 2 ;;
    --new-project) new_project="$2"; shift 2 ;;
    --neo4j-old-image) neo4j_old_image="$2"; shift 2 ;;
    --neo4j-new-image) neo4j_new_image="$2"; shift 2 ;;
    --neo4j-old-volume) neo4j_old_volume="$2"; shift 2 ;;
    --neo4j-new-volume) neo4j_new_volume="$2"; shift 2 ;;
    --neo4j-backup-dir) neo4j_backup_dir="$2"; shift 2 ;;
    --keycloak-dump) keycloak_dump="$2"; shift 2 ;;
    --sockbowl-dump) sockbowl_dump="$2"; shift 2 ;;
    --pg-container) pg_container="$2"; shift 2 ;;
    --pg-user) pg_user="$2"; shift 2 ;;
    --baseline) baseline_file="$2"; shift 2 ;;
    -h|--help) sed -n '2,42p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) ddie "unknown argument: $1" ;;
  esac
done
for req in old_project_dir new_project_dir neo4j_old_image neo4j_old_volume neo4j_new_volume neo4j_backup_dir keycloak_dump sockbowl_dump; do
  [ -n "${!req}" ] || ddie "--${req//_/-} is required"
done
[ -n "$pg_container" ] || pg_container="${new_project}-postgres-1"

deploy_guard_no_legacy_project "$new_project_dir" "$new_project"
if [ "$(basename -- "$old_project_dir")" != "sockbowl-docker" ]; then
  dwarn "--old-project-dir '$old_project_dir' doesn't look like 'sockbowl-docker' — double-check before stopping it"
fi

dry_run_flag=()
if [ "$DRY_RUN" = "true" ]; then dry_run_flag=(--dry-run); fi
up_() { "$SCRIPT_DIR/up.sh" "${dry_run_flag[@]}" --project-dir "$new_project_dir" -- "$@"; }

dlog "== migrate-data: L3 (DISRUPTIVE) =="

dlog "-- step 1: stop the OLD stack (project sockbowl-docker only) --"
run docker compose -p sockbowl-docker --env-file "$old_env_file" \
  -f "$old_project_dir/docker-compose.yml" stop
run_remote_note "verify mage-*/aa-* are still Up (docker ps | grep -E '^mage-|^aa-') — this script does not stop or restart them, so any change there means something else acted, not this step"

dlog "-- step 2: offline Neo4j dump (OLD binary $neo4j_old_image) --"
old_neo4j_container="$(basename -- "$old_project_dir")-neo4j-1"
"$SCRIPT_DIR/backup.sh" "${dry_run_flag[@]}" \
  --mode offline-neo4j \
  --neo4j-container "$old_neo4j_container" \
  --neo4j-volume "$neo4j_old_volume" \
  --neo4j-image "$neo4j_old_image" \
  --backup-dir "$neo4j_backup_dir"

dlog "-- step 3: Neo4j load (NEW binary $neo4j_new_image) into $neo4j_new_volume --"
run docker volume create \
  --label "com.docker.compose.project=${new_project}" \
  --label "com.docker.compose.volume=neo4j_data" \
  "$neo4j_new_volume"
run docker run --rm -v "${neo4j_new_volume}:/data" -v "${neo4j_backup_dir}:/backups" "$neo4j_new_image" \
  neo4j-admin database load neo4j --from-path=/backups --overwrite-destination=true

dlog "-- step 4: Postgres 13 -> 18 (logical restore) --"
up_ up -d postgres
run_with_stdin "$keycloak_dump" docker exec -i "$pg_container" pg_restore --no-owner --role="$pg_user" -d keycloak
run docker exec "$pg_container" createdb -U "$pg_user" sockbowl_legacy
run_with_stdin "$sockbowl_dump" docker exec -i "$pg_container" pg_restore -d sockbowl_legacy
run_remote_note "O9: copy sockbowl_legacy.user_used_question into sockbowl_users only if \\d output matches column-for-column — done by hand, never assumed here"

dlog "-- step 5: Keycloak 23 -> 26.7.4 --"
up_ up -d keycloak-realm-init keycloak
kc_container="${new_project}-keycloak-1"
if [ "$DRY_RUN" = "true" ]; then
  dlog "[dry-run] would poll keycloak's /auth/health/ready (via docker exec, :9000) for up to ${kc_ready_timeout}s"
else
  deadline=$((SECONDS + kc_ready_timeout))
  until docker exec "$kc_container" sh -c \
    "exec 3<>/dev/tcp/localhost/9000 && printf 'GET /auth/health/ready HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n' >&3 && grep -q '\"status\": \"UP\"' <&3" \
    >/dev/null 2>&1; do
    [ "$SECONDS" -lt "$deadline" ] || ddie "keycloak did not reach /auth/health/ready within ${kc_ready_timeout}s"
    sleep 5
  done
  dlog "keycloak is ready"
fi

dlog "-- step 5b: rotate the migrated master admin password (WP KC-ROT, before rbac-init) --"
"$SCRIPT_DIR/rotate-kc-admin.sh" "${dry_run_flag[@]}" \
  --project-dir "$new_project_dir" --env-file "$new_project_dir/.env" \
  --kc-container "$kc_container"

up_ up rbac-init

dlog "-- step 6: bring up the rest (full profile) --"
up_ up -d --profile full

dlog "-- step 7: verification (see also: scripts/deploy/verify.sh --mode curl, run once the edge network is reachable) --"
if [ -n "$baseline_file" ]; then
  "$SCRIPT_DIR/verify.sh" "${dry_run_flag[@]}" --mode counts \
    --project "$new_project" --pg-container "$pg_container" --pg-user "$pg_user" \
    --baseline "$baseline_file"
else
  dwarn "no --baseline given; skipping the automated counts comparison (run scripts/deploy/verify.sh --mode counts by hand)"
fi

dlog "== migrate-data: done =="
