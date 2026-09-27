# Sockbowl Docker

Sockbowl Docker provides scripts and containerization assets to set up the Sockbowl platform's infrastructure, including Redis, Neo4j, and essential plugins/modules. These scripts automate the process of downloading, configuring, and initializing required services for development and production environments.

## Features

- **Centralized Configuration:** Single `.env` file to configure all services with a root host and protocol settings
- **Runtime Environment Config:** Angular frontend (sockbowl-ng) supports runtime configuration via environment variables—no rebuild needed
- **Redis Modules:** Shell script to copy essential Redis modules (`redisearch.so`, `rejson.so`) for advanced queries and JSON support
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

- **CREATE_DEMO_ACCOUNTS**: Create demo accounts for testing (default: `true`)
  - When set to `true`, creates 5 demo user accounts (`player1`/`player2`/`player3`/
    `testuser`/`moderator`, all `demo123`) mapped to the four RBAC tiers — see
    "Authentication modes" below for the exact role mapping

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
are gated behind the `full` Compose **profile**. This gives two workflows:

**Infra only** (default) — start the backing services and run the app code from source
(recommended for local development, since the published images may lag your local changes):
```bash
docker compose up -d          # kafka, postgres, keycloak, neo4j, redis (+ init jobs)
```

**Full stack** — start everything including the published app images from GHCR:
```bash
docker compose --profile full up -d
```

> The app images default to `ghcr.io/jacob-sabella/sockbowl-*:main`, built and pushed by
> CI. To run the *full* stack against local code changes, either build the images first
> (`./gradlew bootBuildImage` in game/questions, `docker build` in ng) and point
> `SOCKBOWL_GAME_IMAGE` / `SOCKBOWL_QUESTIONS_IMAGE` / `SOCKBOWL_NG_IMAGE` in `.env` at
> your local tags, or use the infra-only workflow above and start the apps from their
> dev servers.

Stop services:
```bash
docker compose down                      # infra
docker compose --profile full down       # everything
```

View logs:
```bash
docker compose logs -f [service_name]
```

### Authentication modes

- **Authenticated mode** (`AUTH_ENABLED=true`, **default** — this is the supported path)
  — Keycloak-backed login with RBAC (roles, game/packet ownership, ban system). With
  the shipped defaults (`AUTH_ENABLED=true`, `CREATE_DEMO_ACCOUNTS=true`), `scripts/load-rbac.sh`
  maps the demo logins (password `demo123`) to all four RBAC tiers:
  - `player1` → **admin** (everything, including the ban-management admin UI)
  - `moderator` → **moderator** (ban/unban users, no admin console)
  - `testuser` → **author** (create/generate questions)
  - `player2` → **player** (host/join games, browse packets)
  - `player3` keeps the realm-default `player` role

  The realm admin user (`KEYCLOAK_USER_*`, default `admin / admin123`) also has the
  `admin` tier.
- **Guest mode** (`AUTH_ENABLED=false`) — no Keycloak required, fastest path for quick
  local iteration; explicitly opt into it by setting `AUTH_ENABLED=false` in `.env`.

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

- Run `scripts/download-redis-modules.sh` within a Redis container to copy modules
- Run `scripts/download-neo4j-plugins.sh` in a Neo4j container to download plugins and update config
- Run `scripts/init-neo4j.sh` to initialize Neo4j with base packet data

## Requirements

- Docker and Docker Compose
- Redis Stack
- Neo4j

## License

MIT License. See `LICENSE` for details.

---

*Created by Jacob Sabella*
