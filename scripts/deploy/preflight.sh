#!/usr/bin/env bash
#
# preflight.sh — WP-D3 (plans/m7-deploy.md §4.5, §5 step L1.1 "Preflight
# checks"). Runs directly on the target host (the VPS in a real deploy; a
# local throwaway stack when this WP tests it under the fullstack lock) —
# nothing here spells "ssh". Read-only: it never starts, stops or removes a
# container or volume, so it is always safe to re-run.
#
# Checks (each prints "PASS: ..." / "FAIL: ..."):
#   1. At least --min-free-gb GB free on the filesystem holding --project-dir
#      (§5 L1: ~8 GB estimated need; the plan's stop threshold is 10 GB).
#   2. RAM snapshot (informational only; O3's swap decision and the L3 "no
#      OOM" gate use it, but preflight itself never fails on low RAM).
#   3. No containers whose name starts with "${COMPOSE_PROJECT_NAME}-" exist
#      yet (a stale prior run would collide with a fresh `up`).
#   4. No volumes whose name starts with "${COMPOSE_PROJECT_NAME}_" exist yet
#      (same reason, for `docker compose up` without `-v` on a previous
#      incomplete run).
#   5. Records the live Caddyfile's sha256 to --out-dir/caddyfile.sha256 (§5
#      L1: "Record the Caddyfile checksum" — L4/rollback compares against
#      this to detect any out-of-band edit).
#   6. Derives the anchored SOCKBOWL_TRUSTED_PROXIES_REGEX (D26/.env.prod.
#      example) from `docker network inspect --edge-network`'s subnet plus
#      --edge-container's address on it, and writes it to
#      --out-dir/trusted-proxies-regex.txt. This never overwrites a real
#      .env — the operator copies the value in by hand (or a future WP wires
#      it into make-env.sh), so a bad derivation can never silently widen the
#      trust boundary.
#
# Usage:
#   scripts/deploy/preflight.sh [--dry-run]
#     [--project-dir DIR] [--compose-project-name NAME]
#     [--edge-network NAME] [--edge-container NAME]
#     [--caddyfile PATH] [--min-free-gb N] [--out-dir DIR]
#
# Defaults match a real prod deploy (REMOTE_DIR, sockbowl-prod, aa-web_default,
# aa-caddy, /etc/caddy or the aa-web bind mount's Caddyfile path via
# --caddyfile, 10, --out-dir defaults to --project-dir/../sockbowl-backups/preflight).
# A local rehearsal (this WP, or WP-V1) overrides every one of them to its own
# throwaway names.
#
# Exit: 0 only if every check passes. --dry-run still performs the read-only
# checks (there is nothing unsafe to skip) but does not write any file under
# --out-dir; it prints what it would have written instead.
set -euo pipefail
shopt -s inherit_errexit

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_SCRIPT_NAME="preflight"
# shellcheck source=scripts/deploy/lib.sh
source "$SCRIPT_DIR/lib.sh"

project_dir="$REMOTE_DIR"
compose_project_name="sockbowl-prod"
edge_network="aa-web_default"
edge_container="aa-caddy"
caddyfile=""
min_free_gb=10
out_dir=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --project-dir) project_dir="$2"; shift 2 ;;
    --compose-project-name) compose_project_name="$2"; shift 2 ;;
    --edge-network) edge_network="$2"; shift 2 ;;
    --edge-container) edge_container="$2"; shift 2 ;;
    --caddyfile) caddyfile="$2"; shift 2 ;;
    --min-free-gb) min_free_gb="$2"; shift 2 ;;
    --out-dir) out_dir="$2"; shift 2 ;;
    -h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) ddie "unknown argument: $1" ;;
  esac
done
[ -n "$out_dir" ] || out_dir="$(dirname -- "$project_dir")/sockbowl-backups/preflight"

deploy_guard_no_legacy_project "$project_dir" "$compose_project_name"

FAILED=0
pass() { dlog "PASS: $*"; }
failc() { dlog "FAIL: $*"; FAILED=$((FAILED + 1)); }

dlog "== preflight: $compose_project_name @ $project_dir =="

# 1. Disk space -----------------------------------------------------------
df_target="$project_dir"
[ -d "$df_target" ] || df_target="$(dirname -- "$df_target")"
[ -d "$df_target" ] || df_target="."
avail_kb="$(df -Pk "$df_target" | awk 'NR==2 {print $4}')"
avail_gb=$((avail_kb / 1024 / 1024))
if [ "$avail_gb" -ge "$min_free_gb" ]; then
  pass "disk: ${avail_gb}GB free on $df_target (>= ${min_free_gb}GB)"
else
  failc "disk: only ${avail_gb}GB free on $df_target (< ${min_free_gb}GB; §5 L1 estimates ~8GB needed)"
fi

# 2. RAM snapshot (informational) ------------------------------------------
if command -v free >/dev/null 2>&1; then
  ram_line="$(free -m | awk '/^Mem:/ {print "total="$2"MiB used="$3"MiB free="$4"MiB avail="$7"MiB"}')"
  dlog "RAM snapshot: $ram_line (O3: no host change is the default; escalate on OOM at L3, don't preflight-fail on it)"
else
  dlog "RAM snapshot: 'free' not available on this host; skipping (informational only)"
fi

# 3. No stale containers ----------------------------------------------------
stale_containers="$(docker ps -a --format '{{.Names}}' | grep -E "^${compose_project_name}-" || true)"
if [ -z "$stale_containers" ]; then
  pass "no pre-existing '${compose_project_name}-*' containers"
else
  failc "pre-existing containers found (a prior incomplete run?): $(tr '\n' ' ' <<<"$stale_containers")"
fi

# 4. No stale volumes ---------------------------------------------------------
stale_volumes="$(docker volume ls --format '{{.Name}}' | grep -E "^${compose_project_name}_" || true)"
if [ -z "$stale_volumes" ]; then
  pass "no pre-existing '${compose_project_name}_*' volumes"
else
  failc "pre-existing volumes found (a prior incomplete run?): $(tr '\n' ' ' <<<"$stale_volumes")"
fi

# 5. Caddyfile checksum -------------------------------------------------------
if [ -n "$caddyfile" ]; then
  if [ -f "$caddyfile" ]; then
    sum="$(sha256sum "$caddyfile" | awk '{print $1}')"
    pass "Caddyfile checksum: $sum ($caddyfile)"
    if [ "$DRY_RUN" = "true" ]; then
      dlog "[dry-run] would write $out_dir/caddyfile.sha256 = $sum"
    else
      mkdir -p "$out_dir"
      printf '%s  %s\n' "$sum" "$caddyfile" > "$out_dir/caddyfile.sha256"
      dlog "wrote $out_dir/caddyfile.sha256"
    fi
  else
    failc "Caddyfile not found at $caddyfile (pass --caddyfile, e.g. the bind-mounted path from aa-web's compose file)"
  fi
else
  dlog "SKIP: no --caddyfile given; the real run passes aa-caddy's live Caddyfile path"
fi

# 6. Derive SOCKBOWL_TRUSTED_PROXIES_REGEX -------------------------------------
if docker network inspect "$edge_network" >/dev/null 2>&1; then
  edge_ip="$(docker network inspect "$edge_network" \
    --format "{{range .Containers}}{{if eq .Name \"${edge_container}\"}}{{.IPv4Address}}{{end}}{{end}}" 2>/dev/null \
    | cut -d/ -f1)"
  if [ -n "$edge_ip" ]; then
    escaped_ip="$(printf '%s' "$edge_ip" | sed 's/\./\\./g')"
    regex="^${escaped_ip}\$"
    pass "derived SOCKBOWL_TRUSTED_PROXIES_REGEX=$regex (from ${edge_container}@${edge_network})"
    if [ "$DRY_RUN" = "true" ]; then
      dlog "[dry-run] would write $out_dir/trusted-proxies-regex.txt"
    else
      mkdir -p "$out_dir"
      printf '%s\n' "$regex" > "$out_dir/trusted-proxies-regex.txt"
      dlog "wrote $out_dir/trusted-proxies-regex.txt — copy this into .env's SOCKBOWL_TRUSTED_PROXIES_REGEX by hand; never widen it to the whole subnet (.env.prod.example)"
    fi
  else
    failc "could not find '${edge_container}' on network '${edge_network}' (is it up and joined yet?)"
  fi
else
  failc "edge network '${edge_network}' does not exist (create it, or join the existing aa-web_default on the real VPS, before deploying)"
fi

dlog "== preflight: done, $FAILED check(s) failed =="
[ "$FAILED" -eq 0 ]
