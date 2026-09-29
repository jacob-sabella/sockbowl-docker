#!/usr/bin/env bash
#
# ssh-deploy-gate.sh — the forced command for the CI deploy key on the prod
# host. The key's authorized_keys line is:
#
#   command="/home/ubuntu/sockbowl-prod/scripts/deploy/ssh-deploy-gate.sh",restrict ssh-ed25519 AAAA... sockbowl-ci-deploy
#
# so whatever the client asks to run, sshd runs this script instead and puts
# the request in SSH_ORIGINAL_COMMAND. The only request accepted is
#
#   deploy <game|questions|ng> <40-hex commit sha>
#
# which becomes deploy-service.sh. Anything else is refused, so a leaked key
# can at most redeploy an image CI already published.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
request="${SSH_ORIGINAL_COMMAND:-}"

if [[ "$request" =~ ^deploy\ (game|questions|ng)\ ([0-9a-f]{40})$ ]]; then
  exec "$SCRIPT_DIR/deploy-service.sh" \
    --service "${BASH_REMATCH[1]}" --sha "${BASH_REMATCH[2]}" \
    --project-dir "$(cd "$SCRIPT_DIR/../.." && pwd)"
fi

echo "refused: only 'deploy <game|questions|ng> <40-hex sha>' is allowed" >&2
exit 1
