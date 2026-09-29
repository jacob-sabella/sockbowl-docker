#!/usr/bin/env bash
#
# check-env-example.sh — .env.example completeness and placeholder-safety check.
#
# Fails (exit 1) if:
#   1. Any variable that docker-compose.yml or one of its overlays reads from
#      the top-level `.env` file — either as `${VAR}` / `${VAR:-default}`
#      interpolation, or as a bare `KEY:` passthrough under an `environment:`
#      mapping (docker compose resolves an unset bare key to null and drops
#      it from the container, letting the app's own default apply; see
#      docker-compose.yml's M4 comment block) — has no line for it in
#      .env.example, active or documented-but-commented-out.
#   2. .env.example itself holds a real-looking value (not empty, and not a
#      `CHANGE_ME_*` placeholder) for a variable whose name looks like a
#      credential (`*_PASSWORD`, `*_SECRET`, `*_KEY`), other than the
#      documented dev-only exceptions below.
#
# This never modifies anything; see docs/limits.md and docs/auth.md for the
# design this enforces. Run from anywhere; usage: scripts/check-env-example.sh
set -euo pipefail
shopt -s inherit_errexit

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ENV_EXAMPLE=".env.example"
FAIL=0

if [ ! -f "$ENV_EXAMPLE" ]; then
  echo "FAIL: $ENV_EXAMPLE not found in $ROOT" >&2
  exit 1
fi

# Every docker-compose*.yml in the repo root: the base file plus every
# overlay (dev, build, limits-e2e, e2eauth-relax, and any added later).
compose_files=()
for f in docker-compose*.yml; do
  [ -f "$f" ] && compose_files+=("$f")
done
if [ "${#compose_files[@]}" -eq 0 ]; then
  echo "FAIL: no docker-compose*.yml files found in $ROOT" >&2
  exit 1
fi

# --- Step 1: collect every variable name compose reads from the environment ---
#
# Strip full-line comments first (a `#`-prefixed compose line is prose, not
# live config — e.g. docker-compose.build.yml's header shows an example
# `GITHUB_REPOSITORY=...` shell invocation that must NOT count as "consumed").
# Then collect two shapes:
#   a) ${VAR} / ${VAR:-default} / ${VAR:=default} interpolation, anywhere.
#   b) a bare `KEY:` mapping entry (no value after the colon) inside an
#      `environment:` block — the M4 unset-passthrough contract. Restricted
#      to SCREAMING_SNAKE_CASE keys so real YAML structure keys (services,
#      environment, depends_on, ...) are never mistaken for one.
consumed_tmp="$(mktemp)"
trap 'rm -f "$consumed_tmp"' EXIT

for f in "${compose_files[@]}"; do
  grep -v '^[[:space:]]*#' "$f"
done > "$consumed_tmp.nocomments"

grep -ohE '\$\{[A-Za-z_][A-Za-z0-9_]*(:?[-=][^}]*)?\}' "$consumed_tmp.nocomments" \
  | sed -E 's/^\$\{([A-Za-z_][A-Za-z0-9_]*).*\}$/\1/' \
  >> "$consumed_tmp" || true

grep -ohE '^[[:space:]]+[A-Z][A-Z0-9_]*:[[:space:]]*$' "$consumed_tmp.nocomments" \
  | sed -E 's/^[[:space:]]+([A-Z][A-Z0-9_]*):[[:space:]]*$/\1/' \
  >> "$consumed_tmp" || true

rm -f "$consumed_tmp.nocomments"

mapfile -t consumed < <(sort -u "$consumed_tmp")

# --- Step 2: collect every variable .env.example declares ---
#
# A "declared" line is an assignment, active or commented-out-as-documentation
# (`KEY=...` or `#KEY=...`); prose comments that merely mention a variable
# name don't count, so this only matches a line shaped like an assignment.
mapfile -t declared < <(grep -ohE '^#?[A-Z][A-Z0-9_]*=' "$ENV_EXAMPLE" \
  | sed -E 's/^#?([A-Z][A-Z0-9_]*)=$/\1/' | sort -u)

declare -A is_declared=()
for v in "${declared[@]}"; do
  is_declared["$v"]=1
done

missing=()
for v in "${consumed[@]}"; do
  [ -n "$v" ] || continue
  if [ -z "${is_declared[$v]:-}" ]; then
    missing+=("$v")
  fi
done

if [ "${#missing[@]}" -gt 0 ]; then
  echo "FAIL: variables read from .env by compose but missing from $ENV_EXAMPLE:" >&2
  for v in "${missing[@]}"; do
    echo "  - $v" >&2
  done
  FAIL=1
else
  echo "PASS: every variable compose reads from .env is documented in $ENV_EXAMPLE (${#consumed[@]} checked)"
fi

# --- Step 3: refuse a real-looking secret value ---
#
# Documented dev-only literals that are not production secrets, so a real
# (non-CHANGE_ME) value is expected and fine:
#   DEMO_PASSWORD — only read when CREATE_DEMO_ACCOUNTS=true (dev/e2e only;
#     see scripts/check-secrets.sh, which never checks this variable either).
declare -A secret_allowlist=(["DEMO_PASSWORD"]=1)

bad_secrets=()
while IFS='=' read -r key value; do
  case "$key" in
    ''|'#'*) continue ;;
  esac
  case "$key" in
    *_PASSWORD | *_SECRET | *_KEY) ;;
    *) continue ;;
  esac
  [ -n "${secret_allowlist[$key]:-}" ] && continue
  [ -n "$value" ] || continue
  case "$value" in
    CHANGE_ME_*) continue ;;
  esac
  bad_secrets+=("$key")
done < "$ENV_EXAMPLE"

if [ "${#bad_secrets[@]}" -gt 0 ]; then
  echo "FAIL: $ENV_EXAMPLE holds a non-placeholder value for:" >&2
  for v in "${bad_secrets[@]}"; do
    echo "  - $v (expected empty or a CHANGE_ME_* placeholder)" >&2
  done
  FAIL=1
else
  echo "PASS: no non-placeholder secret values in $ENV_EXAMPLE"
fi

exit "$FAIL"
