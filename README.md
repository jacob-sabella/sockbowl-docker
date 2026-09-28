# Sockbowl Docker

Sockbowl Docker provides scripts and containerization assets to set up the Sockbowl platform's infrastructure, including Redis, Neo4j, and essential plugins/modules. These scripts automate the process of downloading, configuring, and initializing required services for development and production environments.

## Features

- **Centralized Configuration:** Single `.env` file to configure all services with a root host and protocol settings
- **Runtime Environment Config:** Angular frontend (sockbowl-ng) supports runtime configuration via environment variables—no rebuild needed
- **Neo4j Plugins:** Automated download and configuration of Neo4j plugins (APOC, Graph Data Science)
- **Neo4j Initialization:** Script to automatically import base data into Neo4j if not already present
- **Container-Ready:** Designed for use in Docker containers and CI/CD pipelines

## Configuration

The setup uses a centralized `.env` file for configuration. Copy `.env.example` to `.env` and customize as needed:

```bash
cp .env.example .env
```

### Key Configuration Variables

- **APP_HOST**: The hostname/domain for your application (default: `localhost`)
  - For production, set this to your domain (e.g., `sockbowl.example.com`)

- **APP_PROTOCOL** / **WS_PROTOCOL**: Protocol settings
  - Development: `http` / `ws`
  - Production with HTTPS: `https` / `wss`

- **AUTH_ENABLED**: Enable/disable Keycloak authentication (default: `true`, the
  supported path — see "Authentication modes" below for how to run with it `false`)

- **KEYCLOAK_USER_*** variables**: Configure the admin user created in the Keycloak realm
  - Username, email, first/last name, and password
  - This user has the `admin` RBAC tier (see "Authentication modes")

- **CREATE_DEMO_ACCOUNTS**: Create demo accounts for testing (default: `false` —
  this file is production-capable by default; use the dev/e2e overlay below
  instead of flipping this here)
  - When set to `true`, creates 5 demo user accounts (`player1`/`player2`/`player3`/
    `testuser`/`moderator`, password `DEMO_PASSWORD`) mapped to the four RBAC tiers
    — see "Authentication modes" below for the exact role mapping

All services will use these centralized values for:
- Internal service connections (where appropriate)
- CORS allowed origins
- API URLs and WebSocket connections
- Authentication endpoints
- Keycloak realm configuration (redirect URIs, user accounts)

### Frontend Runtime Configuration

The `sockbowl-ng` Angular application supports runtime environment configuration, allowing you to:
- Deploy the same Docker image to multiple environments
- Configure via environment variables without rebuilding
- Use internal Docker network connections where appropriate
- Set external-facing URLs for CORS and allowed origins

## Services

The docker-compose stack includes:
- **Kafka**: Message broker
- **PostgreSQL**: Database for Keycloak
- **Keycloak**: Authentication service
- **Neo4j**: Graph database for questions
- **Redis**: Cache and session store
- **sockbowl-game**: Game session service
- **sockbowl-questions**: Question management service
- **sockbowl-ng**: Angular frontend
- **Watchtower**: Auto-updates containers, opt-in (`autoupdate` profile — see
  "Watchtower / Docker socket" below)

## Quick start from source

This is the proven, from-source path: build each app's own image from a
sibling checkout and bring up the full stack against them, without any
GitHub Packages token or a pushed GHCR image. `scripts/clean-clone-test.sh`
runs exactly this block, verbatim, against a throwaway clone on every commit
that touches it — see `CLAUDE.md` "Working in this repo" before editing
between the markers below.

**Prerequisites:**
- Docker and Docker Compose v2 (`docker compose version`).
- Node.js 24+ (for `sockbowl-ng`'s production build). No JDK install needed —
  `sockbowl-game` and `sockbowl-questions` provision their own via Gradle's
  foojay toolchain resolver.
- Ollama, with `mxbai-embed-large` pulled: `ollama pull mxbai-embed-large`
  (see "Ollama embedding model" below — `sockbowl-questions` won't report
  healthy without it).
- This repo checked out as a sibling directory of `sockbowl-game`,
  `sockbowl-questions` and `sockbowl-ng` (i.e. `../sockbowl-game` etc.,
  relative to this repo, all resolve).

**Steps** (run from this repo's root):

<!-- clean-clone:begin -->
```bash
SOCKBOWL_PROJECT="${SOCKBOWL_PROJECT:-sockbowl-source}"
MAVEN_REPO="${MAVEN_REPO:-$HOME/.m2/repository}"

# 1. Questions: publish the models jar to the local Maven repo, then build
#    its image. GITHUB_REPOSITORY must be a valid lowercase "owner/repo" —
#    bootBuildImage's imageName defaults to ghcr.io/${GITHUB_REPOSITORY}:${version},
#    and an unset GITHUB_REPOSITORY falls back to the literal "OWNER/REPO",
#    which fails outright (Docker repository paths must be lowercase). It
#    only has to be well-formed for this local, throwaway tag.
(cd ../sockbowl-questions && \
  GITHUB_REPOSITORY=jacob-sabella/sockbowl-questions \
  ./gradlew publishToMavenLocal bootBuildImage -Dmaven.repo.local="$MAVEN_REPO")
docker tag "$(docker images -q ghcr.io/*/sockbowl-questions* | head -1)" sockbowl-questions:local

# 2. Game: build its image against the models jar just published above
#    (no GitHub Packages token needed).
(cd ../sockbowl-game && \
  GITHUB_REPOSITORY=jacob-sabella/sockbowl-game \
  ./gradlew bootBuildImage -Dmaven.repo.local="$MAVEN_REPO" -PsockbowlUseMavenLocal=true)
docker tag "$(docker images -q ghcr.io/*/sockbowl-game* | head -1)" sockbowl-game:local

# 3. ng: production build. The Dockerfile copies a pre-built dist/, so this
#    must run before the compose build below.
(cd ../sockbowl-ng && npm ci && npm run buildprod)

# 4. Generate a real .env: copy the placeholders, then overwrite the
#    CHANGE_ME_* secrets scripts/check-secrets.sh would otherwise refuse.
cp .env.example .env
{
  echo "POSTGRES_PASSWORD=$(openssl rand -hex 24)"
  echo "NEO4J_PASSWORD=$(openssl rand -hex 24)"
  echo "KEYCLOAK_ADMIN_PASSWORD=$(openssl rand -hex 24)"
  echo "KEYCLOAK_USER_PASSWORD=$(openssl rand -hex 24)"
  echo "SOCKBOWL_GAME_BACKEND_SECRET=$(openssl rand -hex 24)"
} >> .env

# 5. Bring up the full stack (dev/e2e posture) against the images just built.
docker compose -p "$SOCKBOWL_PROJECT" \
  -f docker-compose.yml -f docker-compose.dev.yml -f docker-compose.build.yml \
  --profile full up -d --build
```
<!-- clean-clone:end -->

Then wait for every service to report healthy
(`docker compose -p "$SOCKBOWL_PROJECT" ps`) and visit `http://localhost`.
Tear down with:

```bash
docker compose -p "$SOCKBOWL_PROJECT" \
  -f docker-compose.yml -f docker-compose.dev.yml -f docker-compose.build.yml \
  --profile full down -v --remove-orphans
```

**What this proves, and what it doesn't:** this is the from-source path,
verified end to end by `scripts/clean-clone-test.sh` against a real clean
clone (no `.env`, no `node_modules`, no local build state — only committed
files). The alternative *registry* path (pulling the published GHCR `:main`
images instead of building them) is documented in "Usage" below, but can
only be proven from a clean clone once those images have actually been
pushed to GHCR.

## Usage

The app services (`sockbowl-game`, `sockbowl-questions`, `sockbowl-ng`) are
gated behind the `full` Compose **profile** (watchtower has its own
`autoupdate` profile — see "Watchtower / Docker socket" below). This gives
two workflows, in two postures (see "Authentication modes" below for the
posture difference):

**Infra only** (default) — start the backing services and run the app code from source
(recommended for local development, since the published images may lag your local changes):
```bash
docker compose up -d          # kafka, postgres, keycloak, neo4j, redis (+ init jobs)
```

**Full stack, production posture** — everything, including the published app images
from GHCR, with Keycloak in `start` mode, demo accounts off, and no direct-grant client:
```bash
docker compose --profile full up -d
```

**Full stack, dev/e2e posture** — layer `docker-compose.dev.yml` on top to get a fast
Keycloak (`start-dev`), seeded demo logins, and a password-grant `sockbowl-e2e` client
(so Playwright/CI can fetch tokens without driving the login UI). Use a separate
Compose **project name** (`-p`) so this can coexist with a production stack on the same
host:
```bash
docker compose -p sockbowl-e2e -f docker-compose.yml -f docker-compose.dev.yml \
  --profile full up -d
```

> The app images default to `ghcr.io/jacob-sabella/sockbowl-*:main`, built and pushed by
> CI. To run either posture above against local code changes instead, either build the
> images first (`./gradlew bootBuildImage` in game/questions, `docker build` in ng) and
> point `SOCKBOWL_GAME_IMAGE` / `SOCKBOWL_QUESTIONS_IMAGE` / `SOCKBOWL_NG_IMAGE` in
> `.env` at your local tags, or layer `docker-compose.build.yml` (see its header
> comment), e.g.:
> ```bash
> docker compose -p sockbowl-e2e -f docker-compose.yml -f docker-compose.dev.yml \
>   -f docker-compose.build.yml --profile full up -d --build
> ```
> or use the infra-only workflow above and start the apps from their dev servers.

Stop services:
```bash
docker compose down                                                  # infra, prod project
docker compose --profile full down                                   # full stack, prod project
docker compose -p sockbowl-e2e -f docker-compose.yml \
  -f docker-compose.dev.yml --profile full down -v                   # full stack, dev/e2e project
```

View logs:
```bash
docker compose logs -f [service_name]
```

### Authentication modes

`docker-compose.yml` alone is **production-capable by default**: Keycloak runs
`start` (not `start-dev`) with strict hostname checking against `KEYCLOAK_PUBLIC_URL`,
demo accounts are off, there's no direct-grant client, and
`scripts/check-secrets.sh` refuses to boot with placeholder credentials (see
"Production secrets" below). Local development and Playwright/CI use the
`docker-compose.dev.yml` overlay from the Usage section above instead of changing
these defaults.

- **Authenticated mode** (`AUTH_ENABLED=true`, **default** — this is the supported path)
  — Keycloak-backed login with RBAC (roles, game/packet ownership, ban system).
  With the dev/e2e overlay (`CREATE_DEMO_ACCOUNTS=true`, `SOCKBOWL_E2E=true`),
  `scripts/load-rbac.sh` maps the demo logins (password `DEMO_PASSWORD`, default
  `demo123`) to all four RBAC tiers:
  - `player1` → **admin** (everything, including the ban-management admin UI)
  - `moderator` → **moderator** (ban/unban users, manage taxonomy: categories/subcategories/difficulties, no admin console)
  - `testuser` → **author** (create/generate questions)
  - `player2` → **player** (host/join games, browse packets)
  - `player3` keeps the realm-default `player` role

  The realm admin user (`KEYCLOAK_USER_*`) also has the `admin` tier.
- **Guest mode** (`AUTH_ENABLED=false`) — no Keycloak required, fastest path for quick
  local iteration; explicitly opt into it by setting `AUTH_ENABLED=false` in `.env`.

### Limits and quotas

M4 adds Redis-backed rate limiting, abuse controls and per-role quotas to
`sockbowl-game` and `sockbowl-questions` (see `docs/limits.md` for the
full design). `sockbowl-questions` now depends on `redis` (`condition:
service_healthy`) and shares game's Redis host/port/DB index, so both
services' limiter, quota and ban keys land together.

Both apps enable rate limiting and quotas by default (`SOCKBOWL_RATELIMIT_ENABLED`
/ `SOCKBOWL_QUOTA_ENABLED`, both `true` in `.env.example`) with production-sized
policies (session creation, join-by-code, GraphQL reads/writes, AI generation,
imports, STOMP CONNECT/SEND/buzz, and per-role hosted-session/AI/import/packet
quotas). See `.env.example`'s "Rate limiting, quotas and abuse controls"
section for the individual `SOCKBOWL_RL_*` / `SOCKBOWL_QUOTA_*` overrides —
each is commented out there, so uncommenting one overrides that single
policy or quota and leaving it alone keeps the app's built-in default.

Two overlays layer on top of the dev/e2e posture from "Authentication modes"
above:

- **`docker-compose.dev.yml`** relaxes the rate policies and hosted-session
  quotas that would otherwise throttle a Playwright worker pool or the bot
  harness sharing one IP (M2's and M3's e2e suites, and normal local dev).
  It's already part of the dev/e2e command above — nothing extra to add.
- **`docker-compose.limits-e2e.yml`** does the opposite for M4's own
  Playwright specs: tiny `session-create` and `stomp-buzz` limits and the
  real (small) hosted-session quotas, so a spec can trip a limit and watch it
  recover within the test's timeout. Layer it on top of the dev overlay, and
  use its own project name so it doesn't throttle any other suite sharing
  the host:
  ```bash
  docker compose -p sockbowl-m4e2e \
    -f docker-compose.yml -f docker-compose.dev.yml -f docker-compose.limits-e2e.yml \
    [-f docker-compose.build.yml] --profile full up -d --build
  ```
- **`docker-compose.e2eauth-relax.yml`** undoes `docker-compose.limits-e2e.yml`
  for `sockbowl-game` only, so `npm run e2e:auth` (M2's regression suite) can
  run against the same stack right after `m4:limits` without a full
  down/up: layer it last, `up -d sockbowl-game` (which recreates only that
  service — `game`/`questions`/`ng` stay up), and flush any Redis rate-limit
  buckets `m4:limits` left over before starting `e2e:auth`. Its own header
  comment has the exact env vars and why each one is set back to the dev
  overlay's value:
  ```bash
  docker compose -p sockbowl-m4e2e \
    -f docker-compose.yml -f docker-compose.dev.yml -f docker-compose.limits-e2e.yml \
    -f docker-compose.e2eauth-relax.yml [-f docker-compose.build.yml] \
    --profile full up -d sockbowl-game
  ```

`scripts/test-limits-wiring.sh` is a standalone acceptance check for this
wiring (throwaway project, config validation plus a live Redis/env-injection
check); see its header comment for what it does and does not require from
game/questions.

### Testing token refresh (short-lived access tokens)

`KC_ACCESS_TOKEN_LIFESPAN` (default `300` seconds) sets the access-token
lifespan on the `sockbowl-game` and `sockbowl-e2e` Keycloak clients
(`keycloak/clients/*.json`, applied by `scripts/load-rbac.sh`/the `rbac-init`
job). It is **not** read by `sockbowl-game` or `sockbowl-questions` — a token's
`exp` is entirely Keycloak's doing — so setting it only in a test runner's own
environment (for example when invoking `npm run e2e:auth` in `sockbowl-ng`,
whose `auth-refresh-logout.spec.ts` needs a short-lived token to actually
observe a refresh) has **no effect on the stack**: the client still issues
300s tokens, and the spec ends up waiting on a token that was never going to
expire, so it can pass without ever exercising a refresh.

To shorten the tokens the running stack actually issues, set
`KC_ACCESS_TOKEN_LIFESPAN` when you bring the dev/e2e overlay up (or on a
stack that's already up, re-run just `rbac-init`, which reconciles the
client in place — no restart of Keycloak or the apps needed):

```bash
# Bringing the stack up fresh:
KC_ACCESS_TOKEN_LIFESPAN=60 docker compose -p sockbowl-e2e \
  -f docker-compose.yml -f docker-compose.dev.yml --profile full up -d

# Or, against an already-running e2e stack:
docker compose -p sockbowl-e2e -f docker-compose.yml -f docker-compose.dev.yml \
  run --rm -e KC_ACCESS_TOKEN_LIFESPAN=60 rbac-init
```

Then run `npm run e2e:auth` (in `sockbowl-ng`) with the **same** value, so the
spec's own wait matches what Keycloak is actually issuing:

```bash
KC_ACCESS_TOKEN_LIFESPAN=60 SOCKBOWL_APP=http://localhost npm run e2e:auth
```

Set it back to (or just leave off, to fall back to) `300` afterwards if you're
going to keep using the same stack for anything else — a 60s access token is
fine for this one spec, but makes every other manual/e2e session in that
stack re-authenticate constantly.

### Production secrets

Copying `.env.example` as-is and deploying with plain `docker compose --profile full
up -d` (no `docker-compose.dev.yml`) will not come up: `keycloak-realm-init` and
`rbac-init` both source `scripts/check-secrets.sh`, which refuses to proceed while
`POSTGRES_PASSWORD`, `KEYCLOAK_ADMIN_PASSWORD`, `KEYCLOAK_USER_PASSWORD` or
`SOCKBOWL_GAME_BACKEND_SECRET` still hold one of the shipped `CHANGE_ME_*` /
well-known-weak placeholder values. Set real values in `.env` before deploying.
`ALLOW_INSECURE_DEFAULTS=true` bypasses this check; only the dev/e2e overlay sets it,
and it should never be set in a real deployment's `.env`.

### Watchtower / Docker socket

Watchtower is **opt-in**, in its own `autoupdate` Compose profile (not part of
`full`): `containrrr/watchtower` is archived upstream (no more releases or
security fixes), so auto-pulling and restarting containers from an
unmaintained image is a worse default than requiring an explicit opt-in.
`nickfedor/watchtower` is the actively maintained fork and a likely drop-in
replacement, not switched to yet since it hasn't been smoke-tested against
this compose file.

To bring it up alongside the app stack:
```bash
docker compose --profile full --profile autoupdate up -d
```

It needs the host's Docker socket bind-mounted in to watch and auto-update
the app containers. The default, `DOCKER_SOCKET_PATH=/var/run/docker.sock`,
matches **rootful** Docker (Docker Desktop, and most Linux installs where the daemon
runs as root). If your host runs **rootless** Docker instead, the socket lives under
your user's runtime dir — set this in `.env`:
```bash
DOCKER_SOCKET_PATH=${XDG_RUNTIME_DIR}/docker.sock
```

### Upgrading Postgres data

Postgres is now `postgres:18` and **cannot read a data directory initialized by an
older major version** (17, 13, etc). If you are upgrading an existing stack, wipe the
old volume first (dev data is recreated on boot):
```bash
docker compose down
docker volume rm sockbowl-docker_postgres_data
```

To keep real data across a major version bump instead of wiping it, run `pg_upgrade`
(or dump/restore via `pg_dump` / `pg_restore`) before switching the image tag — this
compose file does not automate that migration.

Separately, the `postgres:18+` image itself changed its expected volume mount point:
it now keeps data in a major-version-specific subdirectory
(`/var/lib/postgresql/18/docker`) and expects the volume mounted at
`/var/lib/postgresql` (not the old `.../postgresql/data`), so that a future
`pg_upgrade --link` isn't blocked by a mount-point boundary. This compose file already
mounts it that way; if you're diffing against an older copy, update the mount rather
than just the image tag.

### Script Usage

- Run `scripts/download-neo4j-plugins.sh` in a Neo4j container to download plugins and update config
- Run `scripts/init-neo4j.sh` to initialize Neo4j with base packet data

### Ollama embedding model (required even with `SOCKBOWL_AI_PROVIDER=openai`)

`sockbowl-questions` always builds its Neo4j vector store against an Ollama embedding
model, regardless of `SOCKBOWL_AI_PROVIDER` (that variable only picks the **chat**
model). With the shipped defaults, the host's Ollama must already have the embedding
model pulled *before* the stack comes up:
```bash
ollama pull mxbai-embed-large
```
If it isn't pulled, questions' vector store initialization gets a 404 from Ollama on
startup and the service never reports healthy (`docker compose ps` sticks on
`starting`/`unhealthy`), which then blocks `sockbowl-game`'s `depends_on`. This isn't
currently exposed as its own compose env var — the model name is fixed in
`sockbowl-questions`' `application.yml` (`spring.ai.ollama.embedding.options.model`,
currently `mxbai-embed-large`, 1024 dimensions) — so pulling that exact model is the
only fix on the compose side.

## Requirements

- Docker and Docker Compose
- Redis 8.x (Search/JSON/Bloom/TimeSeries are built in; no separate Stack image needed)
- Neo4j
- Ollama, with `mxbai-embed-large` pulled (`ollama pull mxbai-embed-large`) — needed
  for `sockbowl-questions`' vector store even when using the OpenAI chat provider;
  see "Ollama embedding model" above

## License

MIT License. See `LICENSE` for details.

---

*Created by Jacob Sabella*
