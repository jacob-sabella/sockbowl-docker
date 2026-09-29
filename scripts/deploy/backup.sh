#!/usr/bin/env bash
#
# backup.sh — WP-D3 (plans/m7-deploy.md §4.5, §5 L1.3, O14). Three modes,
# selected by --mode:
#
#   dump   (runs ON the target host, e.g. the VPS or this WP's local
#           rehearsal stack): pg_dump -Fc every --database, plus
#           `pg_dumpall --globals-only`, plus an online Neo4j export via
#           APOC (`apoc.export.cypher.all`, since Neo4j Community has no
#           online backup — §4.5/§5 L1). Writes everything under
#           --backup-root/<ts>/, chmod 700, and prints the sha256 of every
#           file it wrote (never a secret value — dump *contents* are not
#           printed, only their checksums and paths). This is also what
#           O14's nightly cron entry runs, unmodified, once the new stack is
#           live.
#   offline-neo4j (runs ON the target host; DISRUPTIVE — stops the neo4j
#           container): the §5 L3.2 authoritative dump path
#           (`neo4j-admin database dump`), used only at the real cutover
#           (migrate-data.sh calls this mode), never by the O14 nightly cron.
#   pull   (runs on the OPERATOR's machine): rsyncs a --mode dump output dir
#           down from the host over ssh (O7, "off-host copy"), then compares
#           sha256 sums on both ends.
#
# Every dump is a `pg_dump -Fc`/APOC export/`neo4j-admin dump` file: none of
# them are ever printed to stdout, echoed, or committed. `--mode dump`'s
# output directory is chmod 700 and named only by timestamp.
#
# Usage:
#   scripts/deploy/backup.sh --mode dump [--dry-run]
#     [--backup-root DIR] [--project NAME]
#     [--pg-container NAME] [--pg-user NAME] [--databases db1,db2,...]
#     [--neo4j-container NAME] [--neo4j-user NAME] [--neo4j-password PASS]
#   scripts/deploy/backup.sh --mode offline-neo4j [--dry-run]
#     --neo4j-container NAME --neo4j-volume NAME --neo4j-image REF
#     --backup-dir DIR
#   scripts/deploy/backup.sh --mode pull [--dry-run]
#     --remote-dir DIR --local-dir DIR
#
# Defaults: --backup-root=/home/ubuntu/sockbowl-backups, --project=sockbowl-prod,
# --pg-container=${project}-postgres-1 (Compose v2's default container name),
# --databases=keycloak,sockbowl,sockbowl_users (§5 L1.3; add sockbowl_legacy
# after O9's restore exists), --neo4j-container=${project}-neo4j-1.
#
# Exit: 0 on success (dump mode: 0 even if a database is skipped because
# --dry-run — real failures from pg_dump/cypher-shell/rsync propagate via
# set -e). 1 on a usage error or a real dump/rsync/checksum failure.
set -euo pipefail
shopt -s inherit_errexit

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_SCRIPT_NAME="backup"
# shellcheck source=scripts/deploy/lib.sh
source "$SCRIPT_DIR/lib.sh"

mode=""
backup_root="/home/ubuntu/sockbowl-backups"
project="sockbowl-prod"
pg_container=""
pg_user="${POSTGRES_USER:-postgres}"
databases="keycloak,sockbowl,sockbowl_users"
neo4j_container=""
neo4j_user="${NEO4J_USER:-neo4j}"
neo4j_password="${NEO4J_PASSWORD:-}"
neo4j_volume=""
neo4j_image=""
backup_dir=""
remote_dir=""
local_dir=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --mode) mode="$2"; shift 2 ;;
    --backup-root) backup_root="$2"; shift 2 ;;
    --project) project="$2"; shift 2 ;;
    --pg-container) pg_container="$2"; shift 2 ;;
    --pg-user) pg_user="$2"; shift 2 ;;
    --databases) databases="$2"; shift 2 ;;
    --neo4j-container) neo4j_container="$2"; shift 2 ;;
    --neo4j-user) neo4j_user="$2"; shift 2 ;;
    --neo4j-password) neo4j_password="$2"; shift 2 ;;
    --neo4j-volume) neo4j_volume="$2"; shift 2 ;;
    --neo4j-image) neo4j_image="$2"; shift 2 ;;
    --backup-dir) backup_dir="$2"; shift 2 ;;
    --remote-dir) remote_dir="$2"; shift 2 ;;
    --local-dir) local_dir="$2"; shift 2 ;;
    -h|--help) sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) ddie "unknown argument: $1" ;;
  esac
done
[ -n "$pg_container" ] || pg_container="${project}-postgres-1"
[ -n "$neo4j_container" ] || neo4j_container="${project}-neo4j-1"

case "$mode" in
  dump)
    deploy_guard_no_legacy_project "$backup_root" "$project"
    ts="$(date -u +%Y%m%d-%H%M%S)"
    dest="$backup_root/$ts"
    dlog "== backup dump: project=$project dest=$dest =="
    run mkdir -p "$dest"
    run chmod 700 "$dest"

    IFS=',' read -r -a dbs <<<"$databases"
    for db in "${dbs[@]}"; do
      [ -n "$db" ] || continue
      out="$dest/${db}.dump"
      dlog "pg_dump -Fc $db -> $out"
      if [ "$DRY_RUN" = "true" ]; then
        run docker exec "$pg_container" pg_dump -Fc -U "$pg_user" "$db"
      else
        docker exec "$pg_container" pg_dump -Fc -U "$pg_user" "$db" > "$out"
      fi
    done

    globals_out="$dest/globals.sql"
    dlog "pg_dumpall --globals-only -> $globals_out"
    if [ "$DRY_RUN" = "true" ]; then
      run docker exec "$pg_container" pg_dumpall --globals-only -U "$pg_user"
    else
      docker exec "$pg_container" pg_dumpall --globals-only -U "$pg_user" > "$globals_out"
    fi

    if [ -n "$neo4j_password" ]; then
      neo4j_out="$dest/neo4j-apoc-export.cypher"
      dlog "Neo4j online export (apoc.export.cypher.all) -> $neo4j_out (Community edition has no online backup; §4.5)"
      cypher='CALL apoc.export.cypher.all(null, {format:"cypher-shell", stream:true}) YIELD cypherStatements RETURN cypherStatements'
      if [ "$DRY_RUN" = "true" ]; then
        run docker exec -i "$neo4j_container" cypher-shell -u "$neo4j_user" -p '***' --format plain "$cypher"
      else
        docker exec -i "$neo4j_container" cypher-shell -u "$neo4j_user" -p "$neo4j_password" --format plain "$cypher" > "$neo4j_out"
      fi
    else
      dwarn "no --neo4j-password given; skipping the Neo4j export (pass one, or use --mode offline-neo4j for the L3 authoritative dump)"
    fi

    if [ "$DRY_RUN" != "true" ]; then
      run chmod 600 "$dest"/*.dump "$dest"/*.sql 2>/dev/null || true
      dlog "checksums:"
      (cd "$dest" && sha256sum -- * 2>/dev/null | tee "$dest/sha256sums.txt") || true
    fi
    dlog "== backup dump: done ($dest) =="
    ;;

  offline-neo4j)
    [ -n "$neo4j_volume" ] || ddie "--neo4j-volume is required for --mode offline-neo4j"
    [ -n "$neo4j_image" ] || ddie "--neo4j-image is required (§5 L3.2: the OLD binary's exact image id — never :latest)"
    [ -n "$backup_dir" ] || ddie "--backup-dir is required"
    deploy_guard_container_name "$neo4j_container"
    dlog "== backup offline-neo4j: DISRUPTIVE, stops $neo4j_container =="
    run docker stop "$neo4j_container"
    run mkdir -p "$backup_dir"
    run docker run --rm -v "${neo4j_volume}:/data" -v "${backup_dir}:/backups" "$neo4j_image" \
      neo4j-admin database dump neo4j --to-path=/backups
    dlog "the caller (migrate-data.sh) is responsible for restarting/replacing $neo4j_container afterwards; this mode never does so itself"
    ;;

  pull)
    [ -n "$remote_dir" ] || ddie "--remote-dir is required for --mode pull"
    [ -n "$local_dir" ] || ddie "--local-dir is required for --mode pull"
    dlog "== backup pull: ${VPS_USER}@${VPS_HOST}:${remote_dir} -> ${local_dir} (O7) =="
    run mkdir -p "$local_dir"
    run chmod 700 "$local_dir"
    run rsync -az -e "ssh -i $SSH_KEY -o BatchMode=yes" \
      "${VPS_USER}@${VPS_HOST}:${remote_dir%/}/" "$local_dir/"
    if [ "$DRY_RUN" != "true" ]; then
      remote_sums="$(ssh -i "$SSH_KEY" -o BatchMode=yes "${VPS_USER}@${VPS_HOST}" \
        "cd '$remote_dir' && sha256sum -- * 2>/dev/null" || true)"
      local_sums="$(cd "$local_dir" && sha256sum -- * 2>/dev/null || true)"
      if [ "$remote_sums" = "$local_sums" ]; then
        dlog "PASS: local and remote sha256 sums match"
      else
        ddie "sha256 mismatch between remote and pulled copy — re-run --mode pull (never trust a partial rsync)"
      fi
    fi
    dlog "== backup pull: done =="
    ;;

  *)
    ddie "--mode must be one of: dump, offline-neo4j, pull (got '${mode:-<empty>}')"
    ;;
esac
