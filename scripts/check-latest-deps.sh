#!/usr/bin/env bash
#
# check-latest-deps.sh — M6 DEP1: latest-dependency governance check.
#
# Re-derives, LIVE (this makes real network calls), the same freshness data
# the M6 W1 "S2" scout recorded in audit/m6/deps-*.json, for all four
# sockbowl repos, and fails if anything is behind its latest stable release
# without a matching entry in deps-pins.json. It never writes to any repo,
# publishes anything, or modifies package.json/build.gradle/lockfiles: it
# only reads. Safe to run from a clean clone as long as the sibling repos
# are checked out next to sockbowl-docker (see --src below).
#
# Ecosystems covered:
#   - npm:            sockbowl-docker/scripts, sockbowl-ng (root and e2e)
#   - gradle:         sockbowl-game, sockbowl-questions (com.github.ben-manes
#                     gradle-versions-plugin, applied via a throwaway
#                     initscript — nothing is added to either repo's build)
#   - docker images:  every literal `image: repo:tag` in docker-compose.yml
#                     (no ${VAR} placeholders), plus the nginx base image in
#                     sockbowl-ng's Dockerfile
#   - github actions: every `uses: owner/repo@ref` in all four repos'
#                     .github/workflows/*.yml
#
# A candidate "latest" that looks like a pre-release (-M<n>, -RC<n>, -EA<n>,
# -alpha*, -beta*, *SNAPSHOT*) never counts as "behind latest" on its own —
# that is the M6 ledger's general policy ("stable over milestone"), not a
# per-package pin. Genuine stable-vs-stable gaps need a deps-pins.json entry
# or they fail the check.
#
# Usage:
#   scripts/check-latest-deps.sh [--src <dir with sibling sockbowl-* repos>]
#                                 [--skip-npm] [--skip-gradle]
#                                 [--skip-images] [--skip-actions]
#
# Env overrides (all optional):
#   SOCKBOWL_MAVEN_REPO_LOCAL   passed to gradle as -Dmaven.repo.local, so a
#                               pre-warmed local repo (e.g. this project's
#                               milestone m2repo caches) can be reused and
#                               game's mavenLocal() resolution of the
#                               questions models jar can succeed without a
#                               GitHub Packages token. Unset = gradle default
#                               (~/.m2/repository).
#   SOCKBOWL_GRADLE_EXTRA_ARGS  extra args appended to every ./gradlew call.
#
# Exit code: 0 if every dependency is at latest or covered by an allowlist
# entry whose pin matches the repo's current version; 1 otherwise. Warnings
# (a registry/API call failed, a tool is missing, a repo isn't checked out)
# are printed but do not fail the check — an inconclusive check must not
# masquerade as a clean one, but it also must not block on flaky networks;
# V1 re-runs this and treats persistent warnings as their own finding.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC_ROOT="$(cd "$DOCKER_ROOT/.." && pwd)"
PINS_FILE="$DOCKER_ROOT/deps-pins.json"

SKIP_NPM=0
SKIP_GRADLE=0
SKIP_IMAGES=0
SKIP_ACTIONS=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --src) SRC_ROOT="$(cd "$2" && pwd)"; shift 2 ;;
    --skip-npm) SKIP_NPM=1; shift ;;
    --skip-gradle) SKIP_GRADLE=1; shift ;;
    --skip-images) SKIP_IMAGES=1; shift ;;
    --skip-actions) SKIP_ACTIONS=1; shift ;;
    -h|--help) sed -n '2,45p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ ! -f "$PINS_FILE" ]]; then
  echo "check-latest-deps.sh: missing $PINS_FILE" >&2
  exit 2
fi
python3 -c "import json; json.load(open('$PINS_FILE'))" || {
  echo "check-latest-deps.sh: $PINS_FILE is not valid JSON" >&2
  exit 2
}

FAILURES=()
WARNINGS=()

# --- helpers ---------------------------------------------------------------

is_prerelease() {
  local v="$1"
  [[ "$v" =~ -(M|RC|EA)[0-9]+([.-].*)?$ ]] && return 0
  [[ "$v" == *SNAPSHOT* ]] && return 0
  [[ "$v" =~ -(alpha|beta)([.-]?[0-9]*)?$ ]] && return 0
  return 1
}

pin_for() {
  # prints "<pin>\t<reason>" for the first deps-pins.json entry with this
  # exact name, or nothing if there isn't one.
  python3 - "$PINS_FILE" "$1" <<'PY'
import json, sys
pins = json.load(open(sys.argv[1]))
name = sys.argv[2]
for p in pins:
    if p.get("name") == name:
        print(f"{p.get('pin','')}\t{p.get('reason','')}")
        break
PY
}

# check_dep <name> <current> <latest>
check_dep() {
  local name="$1" current="$2" latest="$3"
  if [[ -z "$latest" ]]; then
    WARNINGS+=("$name: could not determine latest (network/API issue?) — skipped")
    return
  fi
  if [[ -z "$current" ]]; then
    WARNINGS+=("$name: could not determine current version — skipped")
    return
  fi
  if [[ "$current" == "$latest" ]]; then
    return
  fi
  if is_prerelease "$latest"; then
    return
  fi
  local line pin reason
  line="$(pin_for "$name")"
  if [[ -n "$line" ]]; then
    pin="${line%%$'\t'*}"
    reason="${line#*$'\t'}"
    if [[ "$current" == "$pin" ]]; then
      return
    fi
    FAILURES+=("$name: repo has $current, but its deps-pins.json pin is $pin (drifted off its own documented pin; latest is $latest) — $reason")
    return
  fi
  FAILURES+=("$name: $current -> $latest is available, and there is no deps-pins.json entry")
}

latest_dockerhub_tag() {
  # $1 = docker hub repo path (e.g. library/postgres), $2 = tag regex.
  #
  # Uses the plain OCI distribution API (registry-1.docker.io) rather than
  # Docker Hub's own /v2/repositories/.../tags listing API: the listing
  # API's "-last_updated" ordering is unreliable for heavily-mirrored
  # official images (multi-arch rebuilds bump old tags' timestamps too, so
  # the true latest tag is not reliably near the top of any single page),
  # while the distribution API's tags/list returns the complete tag set in
  # one call, letting `sort -V` find the real max deterministically.
  local repo="$1" pattern="$2" tags
  tags="$(python3 -c "
import json, re, sys, urllib.request

repo = sys.argv[1]
pat = re.compile(sys.argv[2])
try:
    auth_url = f'https://auth.docker.io/token?service=registry.docker.io&scope=repository:{repo}:pull'
    with urllib.request.urlopen(auth_url, timeout=15) as resp:
        token = json.load(resp)['token']
    req = urllib.request.Request(
        f'https://registry-1.docker.io/v2/{repo}/tags/list',
        headers={'Authorization': f'Bearer {token}'},
    )
    with urllib.request.urlopen(req, timeout=15) as resp:
        d = json.load(resp)
    for t in d.get('tags', []):
        if pat.match(t):
            print(t)
except Exception:
    sys.exit(0)
" "$repo" "$pattern" 2>/dev/null)"
  [[ -z "$tags" ]] && return 1
  sort -V <<<"$tags" | tail -1
}

latest_quay_tag() {
  # $1 = quay repo path (e.g. keycloak/keycloak), $2 = tag regex.
  #
  # Uses quay's own OCI distribution endpoint (/v2/<repo>/tags/list) and
  # follows its Link-header pagination fully, rather than quay's custom API
  # (/api/v1/repository/.../tag/), which returned tags in an order that did
  # not reliably surface the true latest one within a bounded page count.
  local repo="$1" pattern="$2" tags
  tags="$(python3 -c "
import json, re, sys, urllib.request

repo = sys.argv[1]
pat = re.compile(sys.argv[2])
url = f'https://quay.io/v2/{repo}/tags/list?n=100'
try:
    for _ in range(50):
        req = urllib.request.Request(url)
        with urllib.request.urlopen(req, timeout=15) as resp:
            d = json.load(resp)
            link = resp.getheader('Link')
        for t in d.get('tags', []):
            if pat.match(t):
                print(t)
        if not link:
            break
        m = re.search(r'<([^>]+)>', link)
        if not m:
            break
        url = 'https://quay.io' + m.group(1)
except Exception:
    sys.exit(0)
" "$repo" "$pattern" 2>/dev/null)"
  [[ -z "$tags" ]] && return 1
  sort -V <<<"$tags" | tail -1
}

# --- npm ---------------------------------------------------------------

check_npm_dir() {
  local dir="$1" label="$2"
  if [[ ! -f "$dir/package.json" ]]; then
    WARNINGS+=("$label: no package.json at $dir — skipped")
    return
  fi
  if ! command -v npm >/dev/null 2>&1; then
    WARNINGS+=("$label: npm not on PATH — skipped")
    return
  fi
  local deps
  # Prefer the exact version a fresh `npm ci` would actually install (from
  # package-lock.json's top-level packages entry), since that's what CI and
  # a clean clone get. Fall back to the installed node_modules version, then
  # to package.json's declared floor (after stripping ^/~) only if neither
  # is available — that floor is the least accurate of the three, since a
  # caret range can already resolve well past it.
  deps="$(node -e '
    const fs = require("fs");
    const path = require("path");
    const dir = process.argv[1];
    const pkg = require(path.join(dir, "package.json"));
    let lockPkgs = {};
    try {
      const lock = require(path.join(dir, "package-lock.json"));
      lockPkgs = lock.packages || {};
    } catch (e) { /* no lockfile: fall back below */ }
    const all = Object.assign({}, pkg.dependencies || {}, pkg.devDependencies || {});
    for (const [n, v] of Object.entries(all)) {
      let resolved = lockPkgs["node_modules/" + n] && lockPkgs["node_modules/" + n].version;
      if (!resolved) {
        try {
          resolved = require(path.join(dir, "node_modules", n, "package.json")).version;
        } catch (e) { /* not installed either */ }
      }
      if (!resolved) resolved = String(v).replace(/^[\^~]/, "");
      console.log(n + "\t" + resolved);
    }
  ' "$dir" 2>/dev/null)"
  if [[ -z "$deps" ]]; then
    return
  fi
  while IFS=$'\t' read -r name declared; do
    [[ -z "$name" ]] && continue
    local latest
    latest="$(npm view "$name" version 2>/dev/null)"
    # Namespaced by location: the same package name (e.g. "ws") can be
    # pinned differently, or not at all, in different package.json files.
    check_dep "npm:${label}:${name}" "$declared" "$latest"
  done <<<"$deps"
}

run_npm_checks() {
  check_npm_dir "$DOCKER_ROOT/scripts" "docker/scripts"
  check_npm_dir "$SRC_ROOT/sockbowl-ng" "ng/root"
  check_npm_dir "$SRC_ROOT/sockbowl-ng/e2e" "ng/e2e"
}

# --- gradle --------------------------------------------------------------

GRADLE_INIT=""
make_gradle_init() {
  GRADLE_INIT="$(mktemp /tmp/check-latest-deps-versions-XXXXXX.gradle)"
  cat >"$GRADLE_INIT" <<'EOF'
initscript {
    repositories { gradlePluginPortal() }
    dependencies { classpath 'com.github.ben-manes:gradle-versions-plugin:0.53.0' }
}
rootProject {
    apply plugin: com.github.benmanes.gradle.versions.VersionsPlugin
}
EOF
}
# shellcheck disable=SC2329 # invoked indirectly via the EXIT trap below
cleanup_gradle_init() {
  [[ -n "$GRADLE_INIT" && -f "$GRADLE_INIT" ]] && rm -f "$GRADLE_INIT"
}
trap cleanup_gradle_init EXIT

check_gradle_repo() {
  local dir="$1" label="$2"; shift 2
  local extra_args=("$@")
  if [[ ! -x "$dir/gradlew" ]]; then
    WARNINGS+=("$label: no gradlew at $dir — skipped")
    return
  fi
  local maven_arg=()
  [[ -n "${SOCKBOWL_MAVEN_REPO_LOCAL:-}" ]] && maven_arg=(-Dmaven.repo.local="$SOCKBOWL_MAVEN_REPO_LOCAL")
  local report="$dir/build/dependencyUpdates/report.json"
  rm -f "$report"
  local out
  # shellcheck disable=SC2086
  if ! out="$(cd "$dir" && ./gradlew --init-script "$GRADLE_INIT" dependencyUpdates \
        -Drevision=release -DoutputFormatter=json \
        "${maven_arg[@]}" "${extra_args[@]}" ${SOCKBOWL_GRADLE_EXTRA_ARGS:-} -q 2>&1)"; then
    WARNINGS+=("$label: ./gradlew dependencyUpdates failed — skipped ($(echo "$out" | tail -1))")
    return
  fi
  if [[ ! -f "$report" ]]; then
    WARNINGS+=("$label: dependencyUpdates produced no report — skipped")
    return
  fi
  while IFS=$'\t' read -r name current latest; do
    [[ -z "$name" ]] && continue
    check_dep "gradle:${label}:${name}" "$current" "$latest"
  done < <(python3 -c "
import json
d = json.load(open('$report'))
for r in d['outdated']['dependencies']:
    avail = r.get('available') or {}
    latest = avail.get('release') or avail.get('milestone') or avail.get('integration') or ''
    print(f\"{r['group']}:{r['name']}\t{r['version']}\t{latest}\")
")
}

run_gradle_checks() {
  make_gradle_init
  check_gradle_repo "$SRC_ROOT/sockbowl-game" "game" -PsockbowlUseMavenLocal=true
  check_gradle_repo "$SRC_ROOT/sockbowl-questions" "questions"
}

# --- docker images ---------------------------------------------------------

run_image_checks() {
  local compose_file="$DOCKER_ROOT/docker-compose.yml"
  if [[ ! -f "$compose_file" ]]; then
    WARNINGS+=("docker-compose.yml not found — skipped image checks")
  else
    while IFS=: read -r img tag; do
      [[ -z "$img" || -z "$tag" ]] && continue
      local latest=""
      case "$img" in
        postgres) latest="$(latest_dockerhub_tag library/postgres '^[0-9]+(\.[0-9]+)?$')" ;;
        alpine) latest="$(latest_dockerhub_tag library/alpine '^[0-9]+\.[0-9]+\.[0-9]+$')" ;;
        redis) latest="$(latest_dockerhub_tag library/redis '^[0-9]+\.[0-9]+\.[0-9]+$')" ;;
        neo4j) latest="$(latest_dockerhub_tag library/neo4j '^[0-9]{4}\.[0-9]{2}(\.[0-9]+)?$')" ;;
        curlimages/curl) latest="$(latest_dockerhub_tag curlimages/curl '^[0-9]+\.[0-9]+\.[0-9]+$')" ;;
        containrrr/watchtower) latest="$(latest_dockerhub_tag containrrr/watchtower '^[0-9]+\.[0-9]+\.[0-9]+$')" ;;
        apache/kafka) latest="$(latest_dockerhub_tag apache/kafka '^[0-9]+\.[0-9]+\.[0-9]+$')" ;;
        quay.io/keycloak/keycloak) latest="$(latest_quay_tag keycloak/keycloak '^[0-9]+\.[0-9]+\.[0-9]+$')" ;;
        *) continue ;;
      esac
      if [[ -z "$latest" ]]; then
        WARNINGS+=("$img: registry query failed or returned no matching tag — skipped")
        continue
      fi
      check_dep "image:${img}" "$tag" "$latest"
    done < <(grep -Eo 'image: *[A-Za-z0-9._/-]+:[A-Za-z0-9._-]+' "$compose_file" \
              | sed -E 's/^image: *//' | sort -u)
  fi

  local ng_dockerfile="$SRC_ROOT/sockbowl-ng/Dockerfile"
  if [[ -f "$ng_dockerfile" ]]; then
    local tag
    tag="$(grep -m1 -Eo '^FROM +nginx:[A-Za-z0-9._-]+' "$ng_dockerfile" | sed -E 's/^FROM +nginx://')"
    if [[ -n "$tag" ]]; then
      local latest
      latest="$(latest_dockerhub_tag library/nginx '^[0-9]+\.[0-9]+\.[0-9]+$')"
      if [[ -z "$latest" ]]; then
        WARNINGS+=("nginx: registry query failed — skipped")
      else
        check_dep "image:nginx" "$tag" "$latest"
      fi
    else
      WARNINGS+=("could not parse the nginx base tag from sockbowl-ng/Dockerfile — skipped")
    fi
  else
    WARNINGS+=("sockbowl-ng/Dockerfile not found — skipped nginx check")
  fi
}

# --- github actions ---------------------------------------------------------

run_action_checks() {
  if ! command -v gh >/dev/null 2>&1; then
    WARNINGS+=("gh CLI not found — skipped github-actions checks")
    return
  fi
  local repo wf_dir
  for repo in sockbowl-game sockbowl-questions sockbowl-ng sockbowl-docker; do
    if [[ "$repo" == "sockbowl-docker" ]]; then
      wf_dir="$DOCKER_ROOT/.github/workflows"
    else
      wf_dir="$SRC_ROOT/$repo/.github/workflows"
    fi
    [[ -d "$wf_dir" ]] || continue
    while IFS='@' read -r action version; do
      [[ -z "$action" || -z "$version" ]] && continue
      [[ "$action" == *'{{'* ]] && continue
      local latest
      latest="$(gh api "repos/${action}/releases/latest" --jq .tag_name 2>/dev/null)"
      check_dep "action:${action}" "$version" "$latest"
    done < <(grep -rhoE 'uses: *[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@[A-Za-z0-9._-]+' "$wf_dir" 2>/dev/null \
              | sed -E 's/^uses: *//' | sort -u)
  done
}

# --- run ---------------------------------------------------------------

[[ "$SKIP_NPM" -eq 0 ]] && run_npm_checks
[[ "$SKIP_GRADLE" -eq 0 ]] && run_gradle_checks
[[ "$SKIP_IMAGES" -eq 0 ]] && run_image_checks
[[ "$SKIP_ACTIONS" -eq 0 ]] && run_action_checks

if [[ "${#WARNINGS[@]}" -gt 0 ]]; then
  echo "--- warnings (did not fail the check) ---"
  printf '  %s\n' "${WARNINGS[@]}"
fi

if [[ "${#FAILURES[@]}" -gt 0 ]]; then
  echo "--- FAILED: dependencies behind latest without an allowlist entry ---"
  printf '  %s\n' "${FAILURES[@]}"
  echo
  echo "Fix: bump the dependency, or add/update an entry in $PINS_FILE citing"
  echo "the ledger decision to keep it pinned."
  exit 1
fi

echo "check-latest-deps: all dependencies are at latest or covered by $PINS_FILE."
exit 0
