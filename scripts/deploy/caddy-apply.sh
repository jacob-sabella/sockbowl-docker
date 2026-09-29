#!/usr/bin/env bash
#
# caddy-apply.sh — WP-D3 (plans/m7-deploy.md §4.2, §5 L4). Splices the
# rendered sockbowl-m7 site block into aa-caddy's live Caddyfile and reloads
# it. This is deliberately the ONE script in scripts/deploy/ that is allowed
# to touch a container named "aa-caddy" — and only ever via `docker exec ...
# caddy validate|reload`, never stop/rm/recreate (§4.5, §5's "the aa-caddy
# reload is the only permitted change to the aa stack"). Every other
# `aa-*`/`mage-*`/`*watchtower*` name is still refused via
# deploy_guard_container_name.
#
# Per §4.2, this is meant to run directly on the VPS (invoked over an ssh
# heredoc from the operator's machine — see docs/deploy.md — so nothing is
# ever copied off the box); this script itself never spells "ssh".
#
# Steps (--drop-legacy and --rollback are mutually exclusive):
#   apply (default):
#     1. Copy --caddyfile to <same-dir>/Caddyfile.bak.pre-m7-<ts>, mode 600.
#     2. Build a candidate: strip any existing "# BEGIN/END sockbowl-m7"
#        region from --caddyfile, optionally (--drop-legacy) strip every
#        top-level site block whose header matches --legacy-host-pattern
#        (brace-depth aware, so nested `handle {}` blocks inside a dropped
#        site block don't confuse the scan), then append the rendered
#        fragment (--fragment FILE, or rendered on the fly by calling
#        render-caddy.sh with --render-host/--render-mode/--render-edge-prefix
#        /--render-cf-pull-ca-pem).
#     3. Print ONLY the changed lines: `diff -U0` (zero context lines, so a
#        secret sitting in an untouched global options block or another
#        site's block can never appear in the printed diff — only lines this
#        script actually added or removed are shown).
#     4. Validate the candidate inside the running container:
#        `docker exec -i aa-caddy caddy validate --adapter caddyfile
#        --config /dev/stdin < candidate`. Aborts here on a validation
#        failure — nothing is written.
#     5. `cat candidate > --caddyfile` (never `mv`/`cp -f` — this keeps the
#        original inode, so aa-caddy's already-open file descriptor and any
#        bind-mount identity survive the edit).
#     6. `docker exec aa-caddy caddy reload --config /etc/caddy/Caddyfile
#        --adapter caddyfile`.
#     7. If --check-domain is given (repeatable), curl --resolve each one
#        against https://127.0.0.1:443/ and require 200/301/302 (§5 L4.4:
#        "magic. and armagetronad. still return their normal status").
#   --rollback TS: `cat <dir>/Caddyfile.bak.pre-m7-TS > --caddyfile` (same
#     inode-preserving write) then the same reload as step 6.
#
# Usage:
#   scripts/deploy/caddy-apply.sh [--dry-run] --caddyfile PATH
#     [--container NAME] [--legacy-host-pattern REGEX] [--drop-legacy]
#     (--fragment FILE | --render-host HOST [--render-mode prod|local]
#      [--render-edge-prefix PREFIX] [--render-cf-pull-ca-pem FILE])
#     [--check-domain HOST ...]
#   scripts/deploy/caddy-apply.sh [--dry-run] --caddyfile PATH --rollback TS
#     [--container NAME] [--backup-dir DIR]
#
# Exit: 0 on success. 1 on a usage error, a validate failure (nothing is
# written), or a --check-domain probe that doesn't come back 2xx/3xx.
set -euo pipefail
shopt -s inherit_errexit

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_SCRIPT_NAME="caddy-apply"
# shellcheck source=scripts/deploy/lib.sh
source "$SCRIPT_DIR/lib.sh"

caddyfile=""
container="aa-caddy"
legacy_pattern='sockbowl\.com'
drop_legacy=false
fragment=""
render_host=""
render_mode="prod"
render_edge_prefix=""
render_cf_pull_ca_pem=""
rollback_ts=""
backup_dir=""
check_domains=()

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --caddyfile) caddyfile="$2"; shift 2 ;;
    --container) container="$2"; shift 2 ;;
    --legacy-host-pattern) legacy_pattern="$2"; shift 2 ;;
    --drop-legacy) drop_legacy=true; shift ;;
    --fragment) fragment="$2"; shift 2 ;;
    --render-host) render_host="$2"; shift 2 ;;
    --render-mode) render_mode="$2"; shift 2 ;;
    --render-edge-prefix) render_edge_prefix="$2"; shift 2 ;;
    --render-cf-pull-ca-pem) render_cf_pull_ca_pem="$2"; shift 2 ;;
    --rollback) rollback_ts="$2"; shift 2 ;;
    --backup-dir) backup_dir="$2"; shift 2 ;;
    --check-domain) check_domains+=("$2"); shift 2 ;;
    -h|--help) sed -n '2,55p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) ddie "unknown argument: $1" ;;
  esac
done

[ -n "$caddyfile" ] || ddie "--caddyfile is required"
[ -n "$backup_dir" ] || backup_dir="$(dirname -- "$caddyfile")"
deploy_guard_container_name "$container" "aa-caddy"

check_domains_curl() {
  local ok=true
  for host in "${check_domains[@]}"; do
    local code
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 \
      --resolve "${host}:443:127.0.0.1" "https://${host}/" 2>/dev/null || echo 000)"
    case "$code" in
      2??|3??) dlog "PASS: https://${host}/ -> $code" ;;
      *) dlog "FAIL: https://${host}/ -> $code (expected 2xx/3xx)"; ok=false ;;
    esac
  done
  [ "$ok" = "true" ]
}

reload_caddy() {
  dlog "validating and reloading $container"
  run docker exec "$container" caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile
}

# ---- rollback -----------------------------------------------------------------
if [ -n "$rollback_ts" ]; then
  [ -f "$caddyfile" ] || ddie "--caddyfile not found: $caddyfile"
  bak="$backup_dir/Caddyfile.bak.pre-m7-${rollback_ts}"
  [ -f "$bak" ] || ddie "backup not found: $bak"
  dlog "== caddy-apply rollback: restoring $bak -> $caddyfile =="
  if [ "$DRY_RUN" = "true" ]; then
    dlog "[dry-run] would run: cat '$bak' > '$caddyfile'"
  else
    cat "$bak" > "$caddyfile"
  fi
  reload_caddy
  [ "${#check_domains[@]}" -eq 0 ] || check_domains_curl
  dlog "== caddy-apply rollback: done =="
  exit 0
fi

# ---- apply --------------------------------------------------------------------
[ -f "$caddyfile" ] || ddie "--caddyfile not found: $caddyfile"

if [ -z "$fragment" ]; then
  [ -n "$render_host" ] || ddie "either --fragment FILE or --render-host HOST is required"
  fragment="$(mktemp)"
  render_args=(--mode "$render_mode" --host "$render_host")
  if [ -n "$render_edge_prefix" ]; then render_args+=(--edge-prefix "$render_edge_prefix"); fi
  if [ -n "$render_cf_pull_ca_pem" ]; then render_args+=(--cf-pull-ca-pem "$render_cf_pull_ca_pem"); fi
  "$SCRIPT_DIR/render-caddy.sh" "${render_args[@]}" -o "$fragment"
fi
[ -s "$fragment" ] || ddie "rendered fragment is empty: $fragment"

ts="$(date -u +%Y%m%d-%H%M%S)"
bak="$backup_dir/Caddyfile.bak.pre-m7-${ts}"
dlog "== caddy-apply: $caddyfile (container=$container, drop-legacy=$drop_legacy) =="
dlog "1. backing up -> $bak"
run cp "$caddyfile" "$bak"
[ "$DRY_RUN" = "true" ] || chmod 600 "$bak"

candidate="$(mktemp)"
trap 'rm -f "$candidate"' EXIT

dlog "2. building candidate (strip old sockbowl-m7 region$([ "$drop_legacy" = "true" ] && echo ", drop legacy /$legacy_pattern/ blocks"))"
strip_marked_region() {
  awk '
    /^# BEGIN sockbowl-m7/ { skip=1 }
    !skip { print }
    /^# END sockbowl-m7/ { skip=0 }
  '
}
strip_legacy_blocks() {
  awk -v pat="$legacy_pattern" '
    BEGIN { depth=0; skipping=0 }
    {
      line=$0
      if (!skipping && depth==0 && line ~ pat && line ~ /\{[ \t]*$/) {
        skipping=1
        tmp=line; n=gsub(/\{/,"{",tmp); depth+=n
        tmp=line; n=gsub(/\}/,"}",tmp); depth-=n
        next
      }
      if (skipping) {
        tmp=line; n=gsub(/\{/,"{",tmp); depth+=n
        tmp=line; n=gsub(/\}/,"}",tmp); depth-=n
        if (depth<=0) skipping=0
        next
      }
      print
    }
  '
}
if [ "$drop_legacy" = "true" ]; then
  strip_marked_region < "$caddyfile" | strip_legacy_blocks > "$candidate"
else
  strip_marked_region < "$caddyfile" > "$candidate"
fi
{
  printf '\n'
  cat "$fragment"
  printf '\n'
} >> "$candidate"

dlog "3. diff (changed lines only, -U0 — never prints untouched lines, so no other site's secrets can appear):"
diff -U0 "$caddyfile" "$candidate" || true

dlog "4. validating candidate inside $container"
if [ "$DRY_RUN" = "true" ]; then
  dlog "[dry-run] would run: docker exec -i $container caddy validate --adapter caddyfile --config /dev/stdin < $candidate"
else
  docker exec -i "$container" caddy validate --adapter caddyfile --config /dev/stdin < "$candidate"
fi

dlog "5. writing candidate in place (cat > file, preserves the inode)"
if [ "$DRY_RUN" = "true" ]; then
  dlog "[dry-run] would run: cat '$candidate' > '$caddyfile'"
else
  cat "$candidate" > "$caddyfile"
fi

dlog "6. reload"
reload_caddy

if [ "${#check_domains[@]}" -gt 0 ]; then
  dlog "7. checking unrelated domains still answer"
  check_domains_curl
fi

dlog "== caddy-apply: done. Rollback: scripts/deploy/caddy-apply.sh --caddyfile '$caddyfile' --rollback $ts =="
