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
- **Watchtower**: Auto-updates containers

## Usage

The app services (`sockbowl-game`, `sockbowl-questions`, `sockbowl-ng`, `watchtower`)
are gated behind the `full` Compose **profile**. This gives two workflows, in two
postures (see "Authentication modes" below for the posture difference):

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

Watchtower (part of the `full` profile) needs the host's Docker socket bind-mounted in
to watch and auto-update the app containers. The default, `DOCKER_SOCKET_PATH=/var/run/docker.sock`,
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
