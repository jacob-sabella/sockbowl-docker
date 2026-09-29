#!/usr/bin/env bash
#
# ship-images.sh — WP-D3 (plans/m7-deploy.md §4.4 "Image tag strategy": build
# locally, then docker save and ssh docker load — GHCR push is forbidden by
# the Remote guardrail; O11 revisits this once that's lifted).
#
# Runs on the OPERATOR's machine. For each image reference given:
#   docker save <ref> | zstd -T0 -6 | ssh <vps> 'zstd -dc | docker load'
# then compares `docker image inspect --format {{.Id}}` locally and on the
# VPS, and writes the result to --manifest (default audit/m7/images.json).
#
# Tags must already be the immutable `sockbowl-{game,questions,ng}:m7-<sha>`
# form (§4.4) — this script does not build or tag anything itself (that's
# `./gradlew bootBuildImage` / `npm run buildprod && docker build`, per repo).
# It refuses any reference ending in `:latest` or `:main`, and any bare
# `ghcr.io/...` reference (never pushes; §4.4/O11 — this ships by
# save+ssh+load only, and a ghcr.io tag here would be a sign the wrong image
# was built).
#
# Usage:
#   scripts/deploy/ship-images.sh [--dry-run] [--manifest FILE]
#     --image REF [--image REF ...]
#
# Exit: 0 if every shipped image's local and remote Id match; 1 on a usage
# error, a forbidden tag, or an Id mismatch (never trust a partial ssh pipe).
set -euo pipefail
shopt -s inherit_errexit

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_SCRIPT_NAME="ship-images"
# shellcheck source=scripts/deploy/lib.sh
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
manifest="$REPO_ROOT/audit/m7/images.json"
images=()

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --manifest) manifest="$2"; shift 2 ;;
    --image) images+=("$2"); shift 2 ;;
    -h|--help) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) ddie "unknown argument: $1" ;;
  esac
done
[ "${#images[@]}" -gt 0 ] || ddie "at least one --image REF is required"

for ref in "${images[@]}"; do
  case "$ref" in
    *:latest|*:main) ddie "refusing to ship '$ref': mutable tags (:latest/:main) are never used in prod (§4.4)" ;;
    ghcr.io/*) ddie "refusing to ship '$ref': this script never pushes to or pulls from a registry (Remote guardrail, §4.4) — build and tag a local sockbowl-*:m7-<sha> image first" ;;
  esac
done

dlog "== ship-images: ${#images[@]} image(s) -> ${VPS_USER}@${VPS_HOST} =="

results=()
overall_ok=true
for ref in "${images[@]}"; do
  dlog "-- $ref --"
  local_id=""
  if docker image inspect --format '{{.Id}}' "$ref" >/dev/null 2>&1; then
    local_id="$(docker image inspect --format '{{.Id}}' "$ref")"
  else
    ddie "image '$ref' not found locally — build it first (see the per-repo build commands, §4.4)"
  fi

  if [ "$DRY_RUN" = "true" ]; then
    dlog "[dry-run] would run: docker save '$ref' | zstd -T0 -6 | ssh -i $SSH_KEY ${VPS_USER}@${VPS_HOST} 'zstd -dc | docker load'"
    dlog "[dry-run] would then compare local Id ($local_id) against the VPS's 'docker image inspect --format {{.Id}} $ref'"
    results+=("{\"image\":\"$ref\",\"localId\":\"$local_id\",\"remoteId\":null,\"match\":null,\"dryRun\":true}")
    continue
  fi

  docker save "$ref" | zstd -T0 -6 \
    | ssh -i "$SSH_KEY" -o BatchMode=yes "${VPS_USER}@${VPS_HOST}" 'zstd -dc | docker load'

  remote_id="$(ssh -i "$SSH_KEY" -o BatchMode=yes "${VPS_USER}@${VPS_HOST}" \
    "docker image inspect --format '{{.Id}}' '$ref'")"

  if [ "$local_id" = "$remote_id" ]; then
    dlog "PASS: local and remote image Id match ($local_id)"
    results+=("{\"image\":\"$ref\",\"localId\":\"$local_id\",\"remoteId\":\"$remote_id\",\"match\":true}")
  else
    dwarn "FAIL: image Id mismatch for $ref (local=$local_id remote=$remote_id)"
    results+=("{\"image\":\"$ref\",\"localId\":\"$local_id\",\"remoteId\":\"$remote_id\",\"match\":false}")
    overall_ok=false
  fi
done

if [ "$DRY_RUN" != "true" ]; then
  run mkdir -p "$(dirname -- "$manifest")"
  {
    printf '{\n  "timestamp": "%s",\n  "images": [\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    for i in "${!results[@]}"; do
      printf '    %s' "${results[$i]}"
      if [ "$i" -lt $((${#results[@]} - 1)) ]; then printf ','; fi
      printf '\n'
    done
    printf '  ]\n}\n'
  } > "$manifest"
  dlog "wrote manifest: $manifest"
fi

dlog "== ship-images: done =="
[ "$overall_ok" = "true" ]
