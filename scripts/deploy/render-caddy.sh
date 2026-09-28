#!/usr/bin/env bash
#
# render-caddy.sh: renders deploy/caddy/sockbowl.caddy.template (WP-D2,
# plans/m7-deploy.md §4.2) into a ready-to-splice Caddy site-block fragment.
# It only ever prints/writes that fragment — it never touches the VPS, the
# live aa-caddy Caddyfile, or any container. Splicing it in and reloading
# aa-caddy is scripts/deploy/caddy-apply.sh's job (WP-D3).
#
# Usage:
#   render-caddy.sh --mode prod  --host sockbowl.jacobsabella.com \
#     [--edge-prefix PREFIX] [--cf-pull-ca-pem FILE] [-o OUT]
#   render-caddy.sh --mode local --host sockbowl.jacobsabella.com \
#     [--edge-prefix PREFIX] [-o OUT]
#
# --mode prod (the VPS, D22/D26):
#   TLS_DIRECTIVE is empty by default: aa-caddy's own global `acme_dns
#   cloudflare` directive already issues the certificate for every site on
#   the box, so this one needs no `tls` directive of its own for that.
#   CLIENT_IP_HEADER_UP is empty too, UNLESS --cf-pull-ca-pem is given.
#
#   --cf-pull-ca-pem FILE turns on the full D26/O2-option-A treatment: FILE
#   must be Cloudflare's own published Authenticated Origin Pull CA
#   certificate, PEM-encoded (see
#   https://developers.cloudflare.com/ssl/origin-configuration/authenticated-origin-pull/set-up/
#   for the current download link — fetch and verify it out of band; this
#   script never fetches anything itself, and never embeds a hardcoded
#   certificate). It's embedded inline as base64 DER
#   (`trust_pool inline { trust_der ... }`), which needs no new file mount on
#   aa-caddy (D25: no change to the aa-* stack beyond a reviewed config
#   reload) — only scripts/deploy/caddy-apply.sh's reload.
#
#   Only WITH this flag does CLIENT_IP_HEADER_UP get set, ON PURPOSE:
#   trusting CF-Connecting-IP without Authenticated Origin Pulls enforced
#   would let anyone who reaches aa-caddy directly (bypassing Cloudflare —
#   nothing stops them until AOP is on) forge that header and defeat every
#   per-IP rate limit, quota and ban downstream (D26, PROGRESS.md). The two
#   are inseparable; this script refuses to render one without the other.
#
#   Until --cf-pull-ca-pem is supplied, the render is still valid, usable
#   Caddy config — the DNS-only/pre-cutover phase (§6 O1: the DNS record is
#   created grey-cloud first) has no Cloudflare in front at all yet, so
#   there is no CF-Connecting-IP header to trust or forge either way. Re-run
#   with the flag (and re-apply/reload) only after the owner confirms
#   Cloudflare SSL/TLS is Full (strict) and AOP is on (§6 O1/O2).
#
# --mode local (WP-V1, §7): a throwaway local rehearsal, NEVER the VPS.
#   TLS_DIRECTIVE is `tls internal` (Caddy's own local-only CA; no real ACME,
#   no Cloudflare). CLIENT_IP_HEADER_UP is always empty in this mode.
#
# Common flags:
#   --host HOST           required; the ${SOCKBOWL_HOST} the site answers on.
#   --edge-prefix PREFIX   default: $SOCKBOWL_EDGE_PREFIX, else sockbowl-prod.
#   -o, --output FILE      default: stdout.
#
# Env overrides (used only when the matching flag is not given):
#   SOCKBOWL_HOST, SOCKBOWL_EDGE_PREFIX, SOCKBOWL_CF_PULL_CA_PEM
#
# Exit codes: 0 on success; 1 on a usage/input error (missing --host, a
# --cf-pull-ca-pem path that doesn't exist or isn't a valid certificate,
# unknown --mode).
set -euo pipefail

usage() {
  sed -n '2,55p' "$0" | sed 's/^# \{0,1\}//'
}

die() {
  echo "[render-caddy] ERROR: $*" >&2
  exit 1
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
template="${script_dir}/../../deploy/caddy/sockbowl.caddy.template"

mode="prod"
host="${SOCKBOWL_HOST:-}"
edge_prefix="${SOCKBOWL_EDGE_PREFIX:-sockbowl-prod}"
cf_pull_ca_pem="${SOCKBOWL_CF_PULL_CA_PEM:-}"
out=""

while [ $# -gt 0 ]; do
  case "$1" in
    --mode) mode="$2"; shift 2 ;;
    --host) host="$2"; shift 2 ;;
    --edge-prefix) edge_prefix="$2"; shift 2 ;;
    --cf-pull-ca-pem) cf_pull_ca_pem="$2"; shift 2 ;;
    -o|--output) out="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

[ -n "$host" ] || die "--host is required (or set SOCKBOWL_HOST)"
[ -f "$template" ] || die "template not found: $template"

case "$mode" in
  prod)
    tls_directive=""
    client_ip_header_up=""
    if [ -n "$cf_pull_ca_pem" ]; then
      [ -f "$cf_pull_ca_pem" ] || die "--cf-pull-ca-pem file not found: $cf_pull_ca_pem"
      der_b64="$(openssl x509 -in "$cf_pull_ca_pem" -outform der 2>/dev/null | base64 -w0)" \
        || die "--cf-pull-ca-pem does not look like a valid X.509 certificate: $cf_pull_ca_pem"
      [ -n "$der_b64" ] || die "--cf-pull-ca-pem produced no certificate data: $cf_pull_ca_pem"
      tls_directive="$(printf 'tls {\n\t\tclient_auth {\n\t\t\tmode require_and_verify\n\t\t\ttrust_pool inline {\n\t\t\t\ttrust_der %s\n\t\t\t}\n\t\t}\n\t}' "$der_b64")"
      client_ip_header_up="$(printf '{\n\t\theader_up X-Forwarded-For {http.request.header.CF-Connecting-IP}\n\t}')"
    else
      echo "[render-caddy] WARNING: rendering --mode prod WITHOUT --cf-pull-ca-pem: no Authenticated Origin Pulls, no CF-Connecting-IP trust. Per-IP rate limits/quotas/bans stay collapsed to one shared bucket (D26/O2) until this is re-rendered with the flag and reapplied." >&2
    fi
    ;;
  local)
    tls_directive="tls internal"
    client_ip_header_up=""
    [ -z "$cf_pull_ca_pem" ] || die "--cf-pull-ca-pem is not meaningful with --mode local (no Cloudflare in a local rehearsal)"
    ;;
  *)
    die "--mode must be 'prod' or 'local' (got '$mode')"
    ;;
esac

render() {
  # Only the marked region is substituted and emitted: the rest of the
  # template file is documentation about the template (see its header),
  # never part of what caddy-apply.sh splices into the live Caddyfile, and
  # its prose freely mentions "${SOCKBOWL_HOST}" etc. as literal text that
  # envsubst must NOT touch.
  # shellcheck disable=SC2016 # envsubst's variable list, not shell expansion
  awk '/^# BEGIN sockbowl-m7/{p=1} p{print} /^# END sockbowl-m7/{exit}' "$template" \
    | SOCKBOWL_HOST="$host" \
      EDGE_PREFIX="$edge_prefix" \
      TLS_DIRECTIVE="$tls_directive" \
      CLIENT_IP_HEADER_UP="$client_ip_header_up" \
      envsubst '${SOCKBOWL_HOST} ${EDGE_PREFIX} ${TLS_DIRECTIVE} ${CLIENT_IP_HEADER_UP}'
}

if [ -n "$out" ]; then
  render > "$out"
  echo "[render-caddy] wrote $out (mode=$mode, host=$host, edge-prefix=$edge_prefix, aop=$([ -n "$cf_pull_ca_pem" ] && echo on || echo off))" >&2
else
  render
fi
