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

- **AUTH_ENABLED**: Enable/disable Keycloak authentication (default: `false`)

- **KEYCLOAK_USER_*** variables**: Configure the admin user created in the Keycloak realm
  - Username, email, first/last name, and password
  - This user will have both `admin` and `user` roles

- **CREATE_DEMO_ACCOUNTS**: Create demo accounts for testing (default: `false`)
  - When set to `true`, creates 4 demo user accounts:
    - `player1` / `demo123`
    - `player2` / `demo123`
    - `player3` / `demo123`
    - `testuser` / `demo123`
  - All demo accounts have the `user` role

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

> The app images are `ghcr.io/jacob-sabella/sockbowl-*:main`, built and pushed by CI.
> To run the *full* stack against local code changes, build the images first
> (`./gradlew bootBuildImage` in game/questions, `docker build` in ng) or use the
> infra-only workflow above and start the apps from their dev servers.

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

- **Guest mode** (`AUTH_ENABLED=false`, default) — no Keycloak required; fastest path.
- **Authenticated mode** (`AUTH_ENABLED=true`) — Keycloak-backed login with RBAC
  (roles, game/packet ownership, ban system). For an easy local test, also set
  `CREATE_DEMO_ACCOUNTS=true` and sign in as **`moderator / demo123`** (has the
  `admin` role) to exercise the ban-management admin UI, or `player1 / demo123` as a
  regular user. The realm admin user (`KEYCLOAK_USER_*`, default `admin / admin123`)
  also has the `admin` role.

### Upgrading Postgres data

Postgres is now `postgres:17` and **cannot read a PG13 data directory**. If you are
upgrading an existing stack, wipe the old volume first (dev data is recreated on boot):
```bash
docker compose down
docker volume rm sockbowl-docker_postgres_data
```

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
