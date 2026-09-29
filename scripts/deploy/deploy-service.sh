#!/usr/bin/env bash
#
# deploy-service.sh — continuous deployment of ONE app service on the prod
# host (runs ON the VPS; called by ssh-deploy-gate.sh from each app repo's
# CI deploy job, or by hand).
#
#   1. Pull ghcr.io/jacob-sabella/sockbowl-<service>:sha-<sha> (the immutable
#      tag CI pushes next to :main) and tag it locally as
#      sockbowl-<service>:m7-<sha7>, the same pinned-tag scheme as M7.
#   2. Point SOCKBOWL_<SERVICE>_IMAGE in .env at it (the file keeps mode 600;
#      only that one line changes, and no value is ever printed except
#      image tags).
#   3. `up -d --no-deps` that one service, then wait for its Docker
#      healthcheck to report healthy.
#   4. On an unhealthy result or timeout, roll back: restore the previous tag
#      in .env, recreate the service on it, wait again, and exit 1.
#   5. Drop this service's older m7-* tags, keeping the current and previous
#      ones, so the disk doesn't fill with superseded images.
#
# Deploys are serialized with flock, so pushes to several repos at once
# queue up instead of racing on .env. Every result is appended to
# <project-dir>/deploy.log.
#
# Usage:
#   scripts/deploy/deploy-service.sh --service game|questions|ng --sha <40-hex>
#     [--project-dir DIR] [--timeout SECONDS]
#
# Exit: 0 deployed and healthy; 1 usage error, pull failure, or rolled back.
set -euo pipefail
shopt -s inherit_errexit

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_SCRIPT_NAME="deploy-service"
# shellcheck source=scripts/deploy/lib.sh
source "$SCRIPT_DIR/lib.sh"

service=""
sha=""
project_dir="$REMOTE_DIR"
timeout=300

while [ $# -gt 0 ]; do
  case "$1" in
    --service) service="$2"; shift 2 ;;
    --sha) sha="$2"; shift 2 ;;
    --project-dir) project_dir="$2"; shift 2 ;;
    --timeout) timeout="$2"; shift 2 ;;
    -h|--help) sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) ddie "unknown argument: $1" ;;
  esac
done

case "$service" in
  game|questions|ng) ;;
  *) ddie "--service must be game, questions or ng (got '$service')" ;;
esac
[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || ddie "--sha must be a full 40-character lowercase commit sha"
[[ "$timeout" =~ ^[0-9]+$ ]] || ddie "--timeout must be a number of seconds"

env_file="$project_dir/.env"
[ -f "$env_file" ] || ddie "no .env at $env_file"

compose_service="sockbowl-$service"
env_key="SOCKBOWL_${service^^}_IMAGE"
project="$(grep -E '^COMPOSE_PROJECT_NAME=' "$env_file" | tail -n1 | cut -d= -f2-)"
[ -n "$project" ] || project="sockbowl-prod"
container="${project}-${compose_service}-1"
remote_ref="ghcr.io/jacob-sabella/sockbowl-${service}:sha-${sha}"
local_tag="sockbowl-${service}:m7-${sha:0:7}"
log_file="$project_dir/deploy.log"

exec 9>"$project_dir/.deploy.lock"
dlog "waiting for the deploy lock"
flock 9

record() { printf '%s %s %s %s\n' "$(_deploy_ts)" "$service" "${sha:0:7}" "$1" >> "$log_file"; }

set_image() {
  # Rewrite (or append) the one key in place with `cat >`, so the file keeps
  # its inode, owner and mode 600.
  local tag="$1" tmp
  tmp="$(mktemp)"
  if grep -qE "^${env_key}=" "$env_file"; then
    sed -E "s|^${env_key}=.*|${env_key}=${tag}|" "$env_file" > "$tmp"
  else
    cat "$env_file" > "$tmp"
    printf '%s=%s\n' "$env_key" "$tag" >> "$tmp"
  fi
  cat "$tmp" > "$env_file"
  rm -f "$tmp"
}

recreate() {
  "$SCRIPT_DIR/up.sh" --project-dir "$project_dir" -- \
    --profile full up -d --no-deps "$compose_service"
}

wait_healthy() {
  local deadline=$((SECONDS + timeout)) status
  while :; do
    status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container" 2>/dev/null || echo missing)"
    case "$status" in
      healthy) return 0 ;;
      unhealthy|exited|dead|missing) dwarn "$container is $status"; return 1 ;;
    esac
    [ "$SECONDS" -lt "$deadline" ] || { dwarn "$container not healthy after ${timeout}s (last: $status)"; return 1; }
    sleep 5
  done
}

previous="$(grep -E "^${env_key}=" "$env_file" | tail -n1 | cut -d= -f2-)"
if [ "$previous" = "$local_tag" ] && [ "$(docker inspect -f '{{.State.Health.Status}}' "$container" 2>/dev/null)" = "healthy" ]; then
  dlog "$compose_service already runs $local_tag and is healthy; nothing to do"
  record "noop"
  exit 0
fi

dlog "pulling $remote_ref"
docker pull -q "$remote_ref" >/dev/null || { record "pull-failed"; ddie "could not pull $remote_ref"; }
docker tag "$remote_ref" "$local_tag"

dlog "deploying $compose_service: ${previous:-<unset>} -> $local_tag"
set_image "$local_tag"
recreate

if wait_healthy; then
  dlog "$compose_service is healthy on $local_tag"
  record "ok (was ${previous:-unset})"
  # Keep the current and previous tags; drop older m7-* tags of this service.
  # (`|| true`: grep exits 1 when there's nothing old to prune, which
  # pipefail would otherwise turn into a failed deploy.)
  { docker images --format '{{.Repository}}:{{.Tag}}' "sockbowl-${service}" \
    | grep -E ":m7-" | grep -vxF -e "$local_tag" -e "${previous:-__none__}" || true; } \
    | while read -r old; do docker rmi "$old" >/dev/null 2>&1 || true; done
  docker rmi "$remote_ref" >/dev/null 2>&1 || true
  exit 0
fi

if [ -z "$previous" ]; then
  record "FAILED, no previous tag to roll back to"
  ddie "$compose_service failed its healthcheck on $local_tag and there is no previous tag to roll back to"
fi
dwarn "rolling $compose_service back to $previous"
set_image "$previous"
recreate
if wait_healthy; then
  record "ROLLED BACK to $previous"
  ddie "$local_tag failed its healthcheck; rolled back to $previous (healthy)"
fi
record "ROLLBACK UNHEALTHY ($previous)"
ddie "$local_tag failed and the rollback to $previous is not healthy either; check the host"
