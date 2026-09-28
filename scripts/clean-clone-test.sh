#!/usr/bin/env bash
#
# clean-clone-test.sh — proves the README's "Quick start from source" block
# (the fenced commands between the <!-- clean-clone:begin --> / :end --
# markers) works from a real `git clone`, with no local state (.env, dist/,
# node_modules, build/, or anything else .gitignore'd) leaking in.
#
# It clones sockbowl-{docker,game,questions,ng} from local paths into a fresh
# temp dir, executes the README block verbatim in that clone, waits for the
# stack to come up healthy, then runs the auth-on or auth-off smoke path
# against it before tearing everything down. See plans/m6-release.md §3 for
# the full design this implements.
#
# Usage:
#   scripts/clean-clone-test.sh --auth on|off [options]
#
# Options:
#   --src DIR          Parent directory holding sockbowl-{docker,game,
#                       questions,ng} checkouts to clone from.
#                       Default: the parent of this repo's own checkout.
#   --ref REF           Branch/tag to clone in every repo that has no
#                       per-repo override below. No default: pass this or
#                       all four --*-ref flags.
#   --docker-ref REF     Per-repo override for sockbowl-docker (default: --ref).
#   --game-ref REF       Per-repo override for sockbowl-game (default: --ref).
#   --questions-ref REF  Per-repo override for sockbowl-questions (default: --ref).
#   --ng-ref REF         Per-repo override for sockbowl-ng (default: --ref).
#   --auth on|off        Required. Which posture to bring the stack up with
#                        and which smoke path to run.
#   --keep               Don't delete the temp clone dir on exit (still tears
#                        down the stack and releases the lock/slot).
#   --timing-log FILE    Also append the timing summary to FILE (NDJSON-ish,
#                        one "phase=... seconds=..." line per phase).
#
# Locking / stack slots:
#   By default this takes the whole-host full-stack lock (mkdir-based,
#   $SOCKBOWL_FULLSTACK_LOCK, default "${TMPDIR:-/tmp}/sockbowl-fullstack.lock")
#   and brings the stack up on host networking, exactly as documented.
#
#   Set SOCKBOWL_SLOT_SH=/path/to/slot.sh to run inside a private-network
#   stack slot instead (see that tool's own README for what a "slot" is).
#   In that mode this script acquires a slot itself, routes every `docker
#   compose` invocation (including the one inside the README block itself —
#   see the `docker()` shell function below) through
#   `slot.sh $N compose ...`, and routes every check that talks to the
#   stack's published ports (curl, smoke-auth.sh, the ng e2e/Playwright
#   commands) through `slot.sh $N exec`. Nothing outside this script's own
#   process is aware a slot was used: the README block still reads as if it
#   were running against host networking, because inside a slot `localhost`
#   *is* the stack.
#
# Env passed through to the extracted README block and the probes below:
#   MAVEN_REPO, SOCKBOWL_PROJECT (set by this script, not the caller).
#
# Requires (checked up front, before anything is cloned or built):
#   docker, docker compose v2, node >=24, and the host's Ollama with
#   mxbai-embed-large pulled (questions' embedding prerequisite).
set -euo pipefail
shopt -s inherit_errexit

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=scripts/lib/wait-healthy.sh
source "$SCRIPT_DIR/lib/wait-healthy.sh"

SRC="$(cd "$REPO_ROOT/.." && pwd)"
REF=""
DOCKER_REF=""
GAME_REF=""
QUESTIONS_REF=""
NG_REF=""
AUTH_MODE=""
KEEP=0
TIMING_LOG=""

usage() {
  cat <<'EOF'
Usage: clean-clone-test.sh --auth on|off [options]

Options:
  --src DIR             Parent dir holding sockbowl-{docker,game,questions,ng}
                        (default: the parent of this checkout).
  --ref REF             Default branch/tag for every repo below.
  --docker-ref REF      Per-repo override (default: --ref).
  --game-ref REF        Per-repo override (default: --ref).
  --questions-ref REF   Per-repo override (default: --ref).
  --ng-ref REF          Per-repo override (default: --ref).
  --auth on|off         Required: which posture to bring the stack up with.
  --keep                Don't delete the temp clone dir on exit.
  --timing-log FILE     Also append phase timings to FILE.

See this script's own header comment for the full design, including how
SOCKBOWL_SLOT_SH opts into running inside a stack slot instead of taking the
whole-host full-stack lock.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --src) SRC="$2"; shift 2 ;;
    --ref) REF="$2"; shift 2 ;;
    --docker-ref) DOCKER_REF="$2"; shift 2 ;;
    --game-ref) GAME_REF="$2"; shift 2 ;;
    --questions-ref) QUESTIONS_REF="$2"; shift 2 ;;
    --ng-ref) NG_REF="$2"; shift 2 ;;
    --auth) AUTH_MODE="$2"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    --timing-log) TIMING_LOG="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "clean-clone-test.sh: unknown arg $1" >&2; exit 2 ;;
  esac
done

case "$AUTH_MODE" in
  on) AUTH_ENABLED_VALUE=true ;;
  off) AUTH_ENABLED_VALUE=false ;;
  *) echo "clean-clone-test.sh: --auth on|off is required (got '${AUTH_MODE}')" >&2; exit 2 ;;
esac

DOCKER_REF="${DOCKER_REF:-$REF}"
GAME_REF="${GAME_REF:-$REF}"
QUESTIONS_REF="${QUESTIONS_REF:-$REF}"
NG_REF="${NG_REF:-$REF}"
[ -n "$DOCKER_REF" ] || { echo "clean-clone-test.sh: no ref for sockbowl-docker (pass --ref or --docker-ref)" >&2; exit 2; }
[ -n "$GAME_REF" ] || { echo "clean-clone-test.sh: no ref for sockbowl-game (pass --ref or --game-ref)" >&2; exit 2; }
[ -n "$QUESTIONS_REF" ] || { echo "clean-clone-test.sh: no ref for sockbowl-questions (pass --ref or --questions-ref)" >&2; exit 2; }
[ -n "$NG_REF" ] || { echo "clean-clone-test.sh: no ref for sockbowl-ng (pass --ref or --ng-ref)" >&2; exit 2; }

# ---------------------------------------------------------------------------
# Timing
# ---------------------------------------------------------------------------
declare -a TIMING_NAMES=()
declare -a TIMING_SECS=()

run_phase() {
  local name="$1"; shift
  local t0 t1 rc=0
  t0=$(date +%s)
  echo ""
  echo "=== [$(date -u +%FT%TZ)] phase: $name ==="
  if "$@"; then rc=0; else rc=$?; fi
  t1=$(date +%s)
  TIMING_NAMES+=("$name")
  TIMING_SECS+=("$((t1 - t0))")
  echo "=== [$(date -u +%FT%TZ)] phase: $name done in $((t1 - t0))s (rc=$rc) ==="
  return "$rc"
}

print_timings() {
  echo ""
  echo "===== clean-clone-test.sh timings (auth=$AUTH_MODE) ====="
  local i
  for i in "${!TIMING_NAMES[@]}"; do
    printf '%-28s %6ss\n' "${TIMING_NAMES[$i]}" "${TIMING_SECS[$i]}"
    if [ -n "$TIMING_LOG" ]; then
      printf 'phase=%s auth=%s seconds=%s ts=%s\n' \
        "${TIMING_NAMES[$i]}" "$AUTH_MODE" "${TIMING_SECS[$i]}" "$(date -u +%FT%TZ)" >>"$TIMING_LOG"
    fi
  done
}

# ---------------------------------------------------------------------------
# Prerequisites (fail fast with the documented remedy, not mid-run)
# ---------------------------------------------------------------------------
check_prereqs() {
  local fail=0
  if ! command -v docker >/dev/null 2>&1; then
    echo "MISSING: docker. Install Docker (see README.md Prerequisites)." >&2
    fail=1
  else
    echo "docker: $(docker --version)"
  fi
  if ! docker compose version >/dev/null 2>&1; then
    echo "MISSING: docker compose v2 plugin. Install it (see README.md Prerequisites)." >&2
    fail=1
  else
    echo "docker compose: $(docker compose version --short 2>/dev/null || docker compose version)"
  fi
  if ! command -v node >/dev/null 2>&1; then
    echo "MISSING: node >= 24. Install it (see README.md Prerequisites)." >&2
    fail=1
  else
    local nv
    nv="$(node --version)"
    echo "node: $nv"
    local major="${nv#v}"; major="${major%%.*}"
    if [ "${major:-0}" -lt 24 ]; then
      echo "TOO OLD: node $nv (need >= 24). Install a newer node." >&2
      fail=1
    fi
  fi
  if [ "${SOCKBOWL_SKIP_OLLAMA_CHECK:-0}" != "1" ]; then
    if ! command -v ollama >/dev/null 2>&1; then
      echo "MISSING: ollama. Install it and run 'ollama pull mxbai-embed-large' (see README.md Prerequisites), or set SOCKBOWL_SKIP_OLLAMA_CHECK=1 if a slot's Ollama relay covers this." >&2
      fail=1
    elif ! ollama list 2>/dev/null | grep -q '^mxbai-embed-large'; then
      echo "MISSING: the mxbai-embed-large model. Run 'ollama pull mxbai-embed-large'." >&2
      fail=1
    else
      echo "ollama: mxbai-embed-large present"
    fi
  fi
  [ "$fail" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Locking: a stack slot (SOCKBOWL_SLOT_SH set) or the whole-host lock.
# ---------------------------------------------------------------------------
USE_SLOT=0
SLOT_N=""
LOCK_DIR=""
SLOT_SCRATCH_BASE=""
if [ -n "${SOCKBOWL_SLOT_SH:-}" ]; then
  USE_SLOT=1
  # slot.sh's own `exec` subcommand only bind-mounts /home/jsabella/Projects
  # and its own scratchpad directory into the exec container (see that
  # tool's README); a `-w` workdir outside both is silently replaced with
  # the scratchpad root instead of failing loudly (slot.sh: "cwd ... is not
  # mounted ... using $SP"). A plain `mktemp -d` clones under /tmp, which is
  # neither, so every probe below that runs `stack_exec -w "$TMP/..."` would
  # silently execute from the scratchpad instead of the clone (e.g. `npm run
  # smoke` failing with ENOENT on the scratchpad's own package.json instead
  # of running the e2e suite at all). Clone under the scratchpad instead, so
  # every exec'd workdir is one slot.sh actually mounts.
  SLOT_SCRATCH_BASE="$(cd "$(dirname "$SOCKBOWL_SLOT_SH")/.." && pwd)"
fi

acquire() {
  if [ "$USE_SLOT" -eq 1 ]; then
    echo "acquiring a stack slot via $SOCKBOWL_SLOT_SH"
    SLOT_N="$("$SOCKBOWL_SLOT_SH" acquire --owner "clean-clone-test auth=$AUTH_MODE")"
    echo "acquired slot $SLOT_N"
  else
    LOCK_DIR="${SOCKBOWL_FULLSTACK_LOCK:-${TMPDIR:-/tmp}/sockbowl-fullstack.lock}"
    local waited=0 timeout="${SOCKBOWL_LOCK_TIMEOUT:-1800}"
    while ! mkdir "$LOCK_DIR" 2>/dev/null; do
      if [ "$waited" -ge "$timeout" ]; then
        echo "timed out waiting for lock $LOCK_DIR (held by: $(cat "$LOCK_DIR/owner.txt" 2>/dev/null || echo unknown))" >&2
        return 1
      fi
      echo "full-stack lock held, waiting ($waited/${timeout}s)..."
      sleep 15
      waited=$((waited + 15))
    done
    echo "clean-clone-test.sh pid $$ auth=$AUTH_MODE started $(date -u +%FT%TZ)" >"$LOCK_DIR/owner.txt"
    echo "acquired lock $LOCK_DIR"
  fi
}

release() {
  if [ "$USE_SLOT" -eq 1 ] && [ -n "$SLOT_N" ]; then
    "$SOCKBOWL_SLOT_SH" release "$SLOT_N" || true
  elif [ -n "$LOCK_DIR" ]; then
    rm -rf "$LOCK_DIR" || true
  fi
}

# ---------------------------------------------------------------------------
# Compose command: goes through the slot when one is in use.
# ---------------------------------------------------------------------------
compose_cmd() {
  if [ "$USE_SLOT" -eq 1 ]; then
    echo "$SOCKBOWL_SLOT_SH" "$SLOT_N" compose -p "$PROJECT" \
      -f docker-compose.yml -f docker-compose.dev.yml -f docker-compose.build.yml --profile full
  else
    echo docker compose -p "$PROJECT" \
      -f docker-compose.yml -f docker-compose.dev.yml -f docker-compose.build.yml --profile full
  fi
}

# Runs CMD... against the stack's published ports. Inside a slot, that means
# `slot.sh $N exec`; on host networking it just runs directly (localhost
# already is the stack, exactly as auth-smoke.yml assumes).
stack_exec() {
  if [ "$USE_SLOT" -eq 1 ]; then
    "$SOCKBOWL_SLOT_SH" "$SLOT_N" exec -p "$PROJECT" "$@"
  else
    # Emulate slot.sh exec's `-w DIR -- cmd...` / `-e VAR[=VAL]... -- cmd...`
    # surface so callers below don't need an if/else of their own.
    local -a env_args=() args=()
    local workdir=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -w) workdir="$2"; shift 2 ;;
        -e) env_args+=("$2"); shift 2 ;;
        --) shift; args=("$@"); break ;;
        *) args=("$@"); break ;;
      esac
    done
    if [ -n "$workdir" ]; then
      (cd "$workdir" && env "${env_args[@]}" "${args[@]}")
    else
      env "${env_args[@]}" "${args[@]}"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Cleanup (always runs, in reverse order of what succeeded)
# ---------------------------------------------------------------------------
TMP=""
CREATED_GAME_TAG=0
CREATED_QUESTIONS_TAG=0
CREATED_NG_TAG=0
STACK_UP=0
JQ_DIR=""

cleanup() {
  local rc=$?
  if [ "$STACK_UP" -eq 1 ]; then
    echo "tearing down stack (project $PROJECT)..."
    # shellcheck disable=SC2046
    $(compose_cmd) down -v --remove-orphans || true
  fi
  [ "$CREATED_GAME_TAG" -eq 1 ] && docker rmi sockbowl-game:local >/dev/null 2>&1 || true
  [ "$CREATED_QUESTIONS_TAG" -eq 1 ] && docker rmi sockbowl-questions:local >/dev/null 2>&1 || true
  [ "$CREATED_NG_TAG" -eq 1 ] && docker rmi sockbowl-ng:local >/dev/null 2>&1 || true
  if [ "$KEEP" -eq 0 ] && [ -n "$TMP" ]; then
    # Leave the directory we're about to delete first: the teardown above
    # needs cwd inside the clone (relative -f compose file paths), but
    # deleting cwd out from under this shell makes every subshell forked
    # afterwards (release's slot.sh, print_timings) print a spurious
    # "shell-init: error retrieving current directory" to stderr.
    cd "$REPO_ROOT" 2>/dev/null || cd / 2>/dev/null || true
    rm -rf "$TMP"
  else
    [ -n "$TMP" ] && echo "kept temp clone at $TMP (--keep)"
  fi
  release
  print_timings
  exit "$rc"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Phases
# ---------------------------------------------------------------------------

do_prereqs() { check_prereqs; }

do_acquire() { acquire; }

PROJECT=""
do_clone() {
  if [ -n "$SLOT_SCRATCH_BASE" ]; then
    TMP="$(mktemp -d "$SLOT_SCRATCH_BASE/cc1-clone.XXXXXX")"
  else
    TMP="$(mktemp -d)"
  fi
  echo "cloning into $TMP"
  local repo ref
  for repo in docker game questions ng; do
    case "$repo" in
      docker) ref="$DOCKER_REF" ;;
      game) ref="$GAME_REF" ;;
      questions) ref="$QUESTIONS_REF" ;;
      ng) ref="$NG_REF" ;;
    esac
    echo "-- git clone --branch $ref file://$SRC/sockbowl-$repo"
    git clone --no-hardlinks --quiet --branch "$ref" "file://$SRC/sockbowl-$repo" "$TMP/sockbowl-$repo"
    git -C "$TMP/sockbowl-$repo" remote set-url --push origin no_push
  done
  if [ "$USE_SLOT" -eq 1 ]; then
    PROJECT="sbslot${SLOT_N}-cc${AUTH_MODE}"
  else
    PROJECT="sockbowl-source-cc${AUTH_MODE}-$$"
  fi
}

do_build_and_up() {
  cd "$TMP/sockbowl-docker"
  local block_file
  block_file="$(mktemp)"
  awk '/<!-- clean-clone:begin -->/{f=1;next}/<!-- clean-clone:end -->/{f=0}f' README.md \
    | sed -e '/^```/d' >"$block_file"
  if [ ! -s "$block_file" ]; then
    echo "could not find a non-empty clean-clone:begin/:end block in README.md" >&2
    return 1
  fi

  # `command docker`, not the shadowed function defined below, since at this
  # point we want the real binary regardless of definition order.
  command docker image inspect sockbowl-game:local >/dev/null 2>&1 || CREATED_GAME_TAG=1
  command docker image inspect sockbowl-questions:local >/dev/null 2>&1 || CREATED_QUESTIONS_TAG=1
  command docker image inspect sockbowl-ng:local >/dev/null 2>&1 || CREATED_NG_TAG=1

  # Shadow `docker` for the duration of the block so its own literal
  # `docker compose ...` line goes through the slot (see the header comment).
  # Everything else (`docker tag`, `docker images -q`, the gradle/npm
  # sub-shells) is untouched. Exported so it reaches the `bash "$block_file"`
  # child process below.
  #
  # IMPORTANT (see scratchpad/slots/README.md "Incident 2026-09-28 ~18:30:
  # fork bomb"): an exported bash function is inherited by every descendant
  # bash process, not just the one direct child we intend it for. slot.sh is
  # itself a bash script that calls `docker compose` internally to actually
  # run the command against the generated overlay; without the `unset -f
  # docker` below, that inner call would hit this same shadow again, forward
  # back into slot.sh again, and so on without end. So the slot-routing
  # branch unsets the shadow (removing its exported `BASH_FUNC_docker%%`
  # from the environment) *before* forking off to slot.sh, so slot.sh's own
  # subprocess tree never sees it. slot.sh now also defends against this
  # itself (it unsets any inherited `docker` function at startup and aborts
  # past a recursion-depth guard), but this script must not rely on that as
  # its only safeguard.
  # shellcheck disable=SC2329
  docker() {
    if [ "${SOCKBOWL_CC_USE_SLOT:-0}" = "1" ] && [ "${1:-}" = "compose" ]; then
      shift
      unset -f docker
      "$SOCKBOWL_CC_SLOT_SH" "$SOCKBOWL_CC_SLOT_N" compose "$@"
    else
      command docker "$@"
    fi
  }
  export -f docker
  export SOCKBOWL_CC_USE_SLOT="$USE_SLOT"
  export SOCKBOWL_CC_SLOT_SH="${SOCKBOWL_SLOT_SH:-}"
  export SOCKBOWL_CC_SLOT_N="$SLOT_N"

  echo "running the README clean-clone block against $TMP/sockbowl-docker (project=$PROJECT)"
  SOCKBOWL_PROJECT="$PROJECT" \
    MAVEN_REPO="$TMP/m2" \
    AUTH_ENABLED="$AUTH_ENABLED_VALUE" \
    bash -euo pipefail "$block_file"
  local rc=$?
  rm -f "$block_file"
  unset -f docker
  [ "$rc" -eq 0 ] && STACK_UP=1
  return "$rc"
}

do_wait_healthy() {
  cd "$TMP/sockbowl-docker"
  # shellcheck disable=SC2046
  wait_healthy 900 10 "" $(compose_cmd)
}

do_security_headers() {
  local out
  out="$(stack_exec -- curl -sI http://localhost/)"
  echo "$out"
  local h
  for h in "Content-Security-Policy" "X-Content-Type-Options" "Referrer-Policy" "X-Frame-Options" "Permissions-Policy"; do
    if ! echo "$out" | grep -qi "^$h:"; then
      echo "MISSING security header: $h" >&2
      return 1
    fi
  done
  echo "all 5 security headers present"
}

# scripts/smoke-auth.sh (owned outside this WP, unmodified) needs jq. The
# slot exec image (mcr.microsoft.com/playwright:*-noble, see
# scratchpad/slots/README.md) doesn't ship it — only host-networking mode's
# plain host shell does. Fetch a static binary once, into the scratchpad
# (so it lands somewhere slot.sh's exec container actually mounts, and so a
# later run reuses it instead of re-fetching), and only ever *prepend* it
# onto PATH for that one call, so nothing else the script or its own PATH
# entries (node, npm, the browsers under /ms-playwright) needs goes missing.
ensure_slot_jq() {
  [ -n "$JQ_DIR" ] && return 0
  JQ_DIR="$SLOT_SCRATCH_BASE/cc1-jq-bin"
  if [ ! -x "$JQ_DIR/jq" ]; then
    mkdir -p "$JQ_DIR"
    echo "fetching a static jq into $JQ_DIR (the slot exec image has none; scripts/smoke-auth.sh needs it)"
    curl -fsSL -o "$JQ_DIR/jq.download" \
      "https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-amd64"
    chmod +x "$JQ_DIR/jq.download"
    mv "$JQ_DIR/jq.download" "$JQ_DIR/jq"
  fi
}

do_auth_on_smoke() {
  cd "$TMP/sockbowl-docker"
  local game_secret neo4j_pw
  game_secret="$(grep '^SOCKBOWL_GAME_BACKEND_SECRET=' .env | tail -n1 | cut -d= -f2-)"
  neo4j_pw="$(grep '^NEO4J_PASSWORD=' .env | tail -n1 | cut -d= -f2-)"
  # smoke-auth.sh's STOMP rows delegate to scripts/stomp-probe.mjs, whose
  # deps (scripts/package.json: @stomp/stompjs, ws) are never installed by
  # anything in the clean-clone block itself — smoke-auth.sh doesn't
  # self-install them despite that package.json's own comment ("runs `npm
  # install` here before invoking the probe"); only auth-smoke.yml's own
  # separate `npm install` (working-directory: scripts) step does. Without
  # this, the probe crashes with ERR_MODULE_NOT_FOUND on every clean clone,
  # slot or host alike, and smoke-auth.sh only *logs* that as one more
  # FAIL row rather than a hard stop — so it's easy to miss.
  ( cd "$TMP/sockbowl-docker/scripts" && npm ci --quiet ) || return 1
  echo "-- scripts/smoke-auth.sh"
  if [ "$USE_SLOT" -eq 1 ]; then
    ensure_slot_jq
    stack_exec -w "$TMP/sockbowl-docker" \
      -e "SOCKBOWL_GAME_BACKEND_SECRET=$game_secret" \
      -e "NEO4J_PASSWORD=$neo4j_pw" \
      -- bash -c "PATH=\"$JQ_DIR:\$PATH\" exec scripts/smoke-auth.sh"
  else
    stack_exec -w "$TMP/sockbowl-docker" \
      -e "SOCKBOWL_GAME_BACKEND_SECRET=$game_secret" \
      -e "NEO4J_PASSWORD=$neo4j_pw" \
      -- scripts/smoke-auth.sh
  fi
  echo "-- ng tests-auth/auth-login-play.spec.ts"
  ( cd "$TMP/sockbowl-ng" && npm ci --quiet ) || return 1
  if [ "$USE_SLOT" -eq 1 ]; then
    # The exec image ships one pinned Playwright version's browsers. Match
    # it to whatever this clone's root package.json actually resolved
    # (ng's own e2e/ can pin a different, older one — see the default in
    # scratchpad/slots/README.md, "Change it if the e2e Playwright version
    # changes"), so a Playwright bump here doesn't fail as a confusing
    # "browserType.launch: Executable doesn't exist" instead of a clear
    # image pull.
    local pw_version
    pw_version="$(node -p "require('$TMP/sockbowl-ng/node_modules/@playwright/test/package.json').version" 2>/dev/null || true)"
    if [ -n "$pw_version" ]; then
      export SLOT_EXEC_IMAGE="mcr.microsoft.com/playwright:v${pw_version}-noble"
      echo "using slot exec image $SLOT_EXEC_IMAGE (this clone's resolved @playwright/test version)"
    fi
  fi
  stack_exec -w "$TMP/sockbowl-ng" \
    -e "SOCKBOWL_APP=http://localhost" \
    -- npx playwright test -c playwright.auth.config.ts tests-auth/auth-login-play.spec.ts
}

do_auth_off_smoke() {
  ( cd "$TMP/sockbowl-ng/e2e" && npm ci --quiet ) || return 1
  stack_exec -w "$TMP/sockbowl-ng/e2e" \
    -e "SOCKBOWL_API=http://localhost:7000" \
    -e "SOCKBOWL_WS=ws://localhost:7000/sockbowl-game" \
    -e "SOCKBOWL_QUESTIONS=http://localhost:7009" \
    -e "SOCKBOWL_APP=http://localhost" \
    -- npm run smoke
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
run_phase prereqs do_prereqs
run_phase acquire-lock do_acquire
run_phase clone do_clone
run_phase build-and-up do_build_and_up
run_phase wait-healthy do_wait_healthy
run_phase security-headers do_security_headers
if [ "$AUTH_MODE" = on ]; then
  run_phase auth-on-smoke do_auth_on_smoke
else
  run_phase auth-off-smoke do_auth_off_smoke
fi

echo ""
echo "clean-clone-test.sh: PASS (auth=$AUTH_MODE)"
