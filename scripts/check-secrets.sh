#!/bin/sh
#
# check-secrets.sh: refuse to run with default or placeholder secrets.
#
# Sourced by scripts/init-keycloak-realm.sh and scripts/load-rbac.sh (it can
# also be executed on its own). POSIX sh, so it works under alpine's ash as
# well as bash.
#
# Fails (exit 1, which also ends the sourcing script) when any of these is
# set to a known default or a CHANGE_ME / change-me placeholder:
#   KEYCLOAK_ADMIN_PASSWORD, KEYCLOAK_USER_PASSWORD, POSTGRES_PASSWORD,
#   SOCKBOWL_GAME_BACKEND_SECRET
#
# Unset or empty variables are not checked: each container only receives the
# secrets it needs, and the consumer fails on its own if a required one is
# missing.
#
# Escape hatch for local development only (docker-compose.dev.yml sets it):
#   ALLOW_INSECURE_DEFAULTS=true
#

# Prints the reason when the value is insecure, nothing otherwise.
sockbowl_insecure_reason() {
  case "$1" in
    admin123|admin|123456789|changeme|CHANGE_ME|password|demo123)
      echo "a well-known default" ;;
    CHANGE_ME*|change-me*|change_me*|changeme*|ChangeMe*)
      echo "a placeholder" ;;
    *) ;;
  esac
}

sockbowl_check_secrets() {
  _sb_bad=0
  for _sb_var in KEYCLOAK_ADMIN_PASSWORD KEYCLOAK_USER_PASSWORD POSTGRES_PASSWORD SOCKBOWL_GAME_BACKEND_SECRET; do
    eval "_sb_val=\${${_sb_var}:-}"
    [ -n "$_sb_val" ] || continue
    _sb_reason="$(sockbowl_insecure_reason "$_sb_val")"
    if [ -n "$_sb_reason" ]; then
      if [ "${ALLOW_INSECURE_DEFAULTS:-false}" = "true" ]; then
        echo "[check-secrets] WARNING: ${_sb_var} is ${_sb_reason} value (allowed because ALLOW_INSECURE_DEFAULTS=true; never do this in production)" >&2
      else
        echo "[check-secrets] ERROR: ${_sb_var} is ${_sb_reason} value. Replace the placeholder with a real secret in .env, or set ALLOW_INSECURE_DEFAULTS=true for local development only (docker-compose.dev.yml)." >&2
        _sb_bad=1
      fi
    fi
  done
  unset _sb_var _sb_val _sb_reason
  if [ "$_sb_bad" -ne 0 ]; then
    unset _sb_bad
    return 1
  fi
  unset _sb_bad
  return 0
}

sockbowl_check_secrets || exit 1
