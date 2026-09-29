#!/usr/bin/env bash
#
# sync-bundle.sh — WP-D3 (plans/m7-deploy.md §4.4 "Bundle sync", §5 L2.2).
# Runs on the OPERATOR's machine. Ships exactly the committed tree of one
# git ref to the VPS, and nothing else:
#
#   git archive <ref> | ssh <vps> 'mkdir -p <dir> && tar -x -C <dir>'
#
# `git archive` reads only what's committed on <ref> — no local `.env`, no
# untracked scratch files, no `.git` — so this can never leak a local secret
# or an in-progress edit. It never deletes anything already on the VPS (no
# `--delete`, unlike rsync): a stale file from a previous ref is only ever
# overwritten if the new ref also has a file at that path.
#
# Usage:
#   scripts/deploy/sync-bundle.sh [--dry-run] [--ref REF] [--remote-dir DIR]
#
# Defaults: --ref=main, --remote-dir=$REMOTE_DIR
# (/home/ubuntu/sockbowl-prod). Refuses --remote-dir sockbowl-docker (§4.5).
#
# Exit: 0 on success; 1 on a usage error, a bad ref, or a non-zero ssh/tar
# exit (propagated via bash's pipefail).
set -euo pipefail
shopt -s inherit_errexit

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_SCRIPT_NAME="sync-bundle"
# shellcheck source=scripts/deploy/lib.sh
source "$SCRIPT_DIR/lib.sh"

ref="main"
remote_dir="$REMOTE_DIR"

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --ref) ref="$2"; shift 2 ;;
    --remote-dir) remote_dir="$2"; shift 2 ;;
    -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) ddie "unknown argument: $1" ;;
  esac
done

deploy_guard_no_legacy_project "$remote_dir" "${COMPOSE_PROJECT_NAME:-}"

REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

git rev-parse --verify --quiet "${ref}^{commit}" >/dev/null \
  || ddie "ref '$ref' does not resolve to a commit in this repo (fetch it first, or pass --ref)"

dlog "== sync-bundle: $ref -> ${VPS_USER}@${VPS_HOST}:${remote_dir} =="

remote_cmd="mkdir -p '${remote_dir}' && tar -x -C '${remote_dir}'"
if [ "$DRY_RUN" = "true" ]; then
  dlog "[dry-run] would run: git archive '$ref' | ssh -i $SSH_KEY -o BatchMode=yes ${VPS_USER}@${VPS_HOST} \"$remote_cmd\""
else
  git archive "$ref" | ssh -i "$SSH_KEY" -o BatchMode=yes "${VPS_USER}@${VPS_HOST}" "$remote_cmd"
fi

dlog "== sync-bundle: done. Next: scripts/deploy/make-env.sh on the VPS, then scripts/deploy/ship-images.sh =="
