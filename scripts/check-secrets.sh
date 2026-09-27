#!/bin/sh
#
# check-secrets.sh — refuse to boot with placeholder / well-known-weak secrets.
#
# Sourced (not executed) by scripts/init-keycloak-realm.sh and
# scripts/load-rbac.sh, both of which mount this file at /check-secrets.sh
# and source it near the top, before doing anything else:
#
#   . "$(dirname "$0")/check-secrets.sh"
#
# Since it's sourced, `exit` here exits the caller directly.
#
# Unless ALLOW_INSECURE_DEFAULTS=true, this fails when KEYCLOAK_ADMIN_PASSWORD,
# KEYCLOAK_USER_PASSWORD or POSTGRES_PASSWORD is one of a short list of
# well-known weak/placeholder values (or unset), or when
# SOCKBOWL_GAME_BACKEND_SECRET still starts with change-me / CHANGE_ME.
#
# docker-compose.dev.yml sets ALLOW_INSECURE_DEFAULTS=true for local and e2e
# use. The production compose file (docker-compose.yml alone) does not, so a
# clean-clone-with-.env.example-as-is deployment refuses to start instead of
# quietly running with default-admin/admin123-style credentials (AUTH-05).
#
# Never prints a secret's value, only which variable is weak.

if [ "${ALLOW_INSECURE_DEFAULTS:-false}" = "true" ]; then
  return 0 2>/dev/null || exit 0
fi

_sockbowl_weak_found=0

_sockbowl_is_weak_password() {
  case "$1" in
    ""|admin123|admin|123456789|changeme|CHANGE_ME) return 0 ;;
    *) return 1 ;;
  esac
}

for _sockbowl_var_name in KEYCLOAK_ADMIN_PASSWORD KEYCLOAK_USER_PASSWORD POSTGRES_PASSWORD; do
  eval "_sockbowl_var_value=\"\${${_sockbowl_var_name}:-}\""
  if _sockbowl_is_weak_password "$_sockbowl_var_value"; then
    echo "check-secrets: ${_sockbowl_var_name} is a placeholder / well-known-weak value." >&2
    _sockbowl_weak_found=1
  fi
done

case "${SOCKBOWL_GAME_BACKEND_SECRET:-}" in
  ""|change-me*|CHANGE_ME*)
    echo "check-secrets: SOCKBOWL_GAME_BACKEND_SECRET is a placeholder value." >&2
    _sockbowl_weak_found=1
    ;;
esac

unset _sockbowl_var_name _sockbowl_var_value

if [ "$_sockbowl_weak_found" = "1" ]; then
  echo "check-secrets: refusing to start with insecure default/placeholder secrets." >&2
  echo "check-secrets: set real values in .env, or set ALLOW_INSECURE_DEFAULTS=true for local/dev use (docker-compose.dev.yml already does this). See README.md's Authentication modes section." >&2
  exit 1
fi

unset _sockbowl_weak_found
