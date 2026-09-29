#!/usr/bin/env bash
#
# lib.sh — shared helpers for scripts/deploy/*.sh (WP-D3, plans/m7-deploy.md
# §4.5). Sourced, never executed directly (it has no shebang-worthy body of
# its own beyond function/variable definitions).
#
# What every deploy script gets from this file:
#   - dlog / dwarn / ddie: consistent, timestamped, stderr-safe logging.
#   - DRY_RUN parsing (--dry-run / SOCKBOWL_DEPLOY_DRY_RUN=true) and `run`,
#     which either executes its argument list or only prints it — every
#     script in this directory uses `run` for anything that touches the
#     filesystem, Docker or a remote host, so `--dry-run` never has to be
#     reimplemented per script and can never accidentally skip the print.
#   - deploy_guard_no_legacy_project: refuses to operate against the
#     `sockbowl-docker` project dir or `COMPOSE_PROJECT_NAME` (§4.5: "Each
#     refuses to run if the target project dir is /home/ubuntu/sockbowl-docker
#     or COMPOSE_PROJECT_NAME=sockbowl-docker").
#   - deploy_guard_container_name: refuses any action against a container
#     whose name matches `^(mage-|aa-)` or `watchtower`, with a single named
#     exception mechanism for caddy-apply.sh's `docker exec aa-caddy caddy
#     validate/reload` (the one permitted touch to the aa stack, per §4.5 and
#     §5 L4's header).
#   - deploy_ssh / deploy_ssh_pipe: the only places an `ssh` invocation is
#     ever constructed, so every remote command is visible to `--dry-run` and
#     uses the same user/host/key/known-hosts posture.
#
# None of this ever prints a secret: callers pass secret values as env vars
# to the remote command, never as literal argv text that dlog/run would echo
# (see backup.sh/make-env.sh/ship-images.sh for the pattern: build the remote
# command string from names/paths only, and let the *remote* shell resolve
# any secret-bearing env var it already has).

# ---- logging ----------------------------------------------------------------

_deploy_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

dlog() { printf '[%s] [%s] %s\n' "$(_deploy_ts)" "${DEPLOY_SCRIPT_NAME:-deploy}" "$*"; }
dwarn() { printf '[%s] [%s] WARNING: %s\n' "$(_deploy_ts)" "${DEPLOY_SCRIPT_NAME:-deploy}" "$*" >&2; }
ddie() {
  printf '[%s] [%s] ERROR: %s\n' "$(_deploy_ts)" "${DEPLOY_SCRIPT_NAME:-deploy}" "$*" >&2
  exit 1
}

# ---- dry-run ------------------------------------------------------------------

DRY_RUN="${SOCKBOWL_DEPLOY_DRY_RUN:-false}"

# Every script in this directory parses its own "--dry-run) DRY_RUN=true;
# shift ;;" case arm (so it stays visible right next to that script's other
# flags) — this file only defines what DRY_RUN then does.

# run <cmd> [args...] — executes, or with DRY_RUN=true only logs, the exact
# argv it was given (never a string re-parsed by a shell, so quoting in the
# printed form is illustrative only — this is not what re-running the log
# line would do byte-for-byte if an argument contains a space, but no deploy
# script here ever depends on that: dry-run output is for a human to read).
run() {
  if [ "$DRY_RUN" = "true" ]; then
    printf '[dry-run] would run:'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi
  "$@"
}

# run_with_stdin <file> <cmd> [args...] — like `run`, but for a command that
# needs a file piped to its stdin (e.g. `pg_restore ... < dump`). A bare
# `run cmd < "$file"` is wrong for this: the shell opens `$file` for reading
# to set up the redirection BEFORE `run` is even called, so it fails on a
# missing file even under --dry-run, defeating the entire point of dry-run
# (the file — a backup not yet taken — is not expected to exist). Here the
# open only happens on the real-run branch, after the dry-run check.
run_with_stdin() {
  local file="$1"; shift
  if [ "$DRY_RUN" = "true" ]; then
    printf '[dry-run] would run (stdin < %s):' "$file"
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi
  "$@" < "$file"
}

# run_remote_note <description> — dry-run/real-run symmetric line for a step
# that has no single local argv (e.g. "the next 6 steps run over one ssh
# session"). Real runs just log it at the same point a dry-run would print it.
run_remote_note() {
  if [ "$DRY_RUN" = "true" ]; then
    printf '[dry-run] would: %s\n' "$*"
  else
    dlog "$*"
  fi
}

# ---- project/host guards -----------------------------------------------------

# deploy_guard_no_legacy_project <project-dir> <compose-project-name>
# Refuses (exit 1, even under --dry-run — a guard that only warns during a
# rehearsal is not a guard) if either argument names the legacy stack.
deploy_guard_no_legacy_project() {
  local dir="$1" name="$2" base
  base="$(basename -- "$dir")"
  if [ "$base" = "sockbowl-docker" ]; then
    ddie "refusing to operate on project dir '$dir': basename is 'sockbowl-docker' (the legacy stack, never this script's target — see plans/m7-deploy.md §4.5)"
  fi
  if [ "$name" = "sockbowl-docker" ]; then
    ddie "refusing to operate with COMPOSE_PROJECT_NAME=sockbowl-docker (the legacy stack's project name)"
  fi
}

# deploy_guard_container_name <name> [allowed-exception]
# Refuses any name matching ^(mage-|aa-) or containing "watchtower", unless it
# is byte-identical to <allowed-exception> (used only by caddy-apply.sh for
# "aa-caddy", and only for its own validate/reload exec — never for stopping,
# removing or recreating it).
deploy_guard_container_name() {
  local name="$1" allowed="${2:-}"
  if [ -n "$allowed" ] && [ "$name" = "$allowed" ]; then
    return 0
  fi
  case "$name" in
    mage-*|aa-*|*watchtower*)
      ddie "refusing to touch container '$name': names matching ^(mage-|aa-) or containing 'watchtower' belong to the shared host's other tenants or its update agent (D25/§4.5) and are off limits to this script"
      ;;
  esac
}

# ---- ssh (the only place these scripts ever spell "ssh") ---------------------

VPS_USER="${VPS_USER:-ubuntu}"
VPS_HOST="${VPS_HOST:-15.204.11.205}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/homelab}"
REMOTE_DIR="${REMOTE_DIR:-/home/ubuntu/sockbowl-prod}"

_deploy_ssh_argv() {
  printf '%s\n' "ssh" "-i" "$SSH_KEY" "-o" "BatchMode=yes" "${VPS_USER}@${VPS_HOST}"
}

# deploy_ssh <remote-command-string> — runs (or dry-run-prints) one remote
# command over ssh. The command string is the caller's responsibility to
# quote safely; it is passed as a single argv element to ssh, exactly like a
# manual `ssh host 'cmd'` invocation.
deploy_ssh() {
  local cmd="$1"
  run ssh -i "$SSH_KEY" -o BatchMode=yes "${VPS_USER}@${VPS_HOST}" "$cmd"
}

# deploy_ssh_heredoc_note <description> — dry-run/real-run symmetric marker
# for the caddy-apply.sh-style "runs on the VPS via an ssh heredoc" pattern
# (plans/m7-deploy.md §4.2), where the actual invocation is
# `ssh ... 'bash -s' -- args < scripts/deploy/caddy-apply.sh` from the
# operator's shell (documented in docs/deploy.md), not a nested ssh call
# inside this script.
deploy_ssh_heredoc_note() {
  run_remote_note "runs directly on the VPS (invoked as: ssh -i \$SSH_KEY \${VPS_USER}@\${VPS_HOST} 'bash -s' -- $* < \"\$0\"); this process itself never re-execs ssh"
}
