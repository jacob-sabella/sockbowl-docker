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

Start all services:
```bash
docker-compose up -d
```

Stop all services:
```bash
docker-compose down
```

View logs:
```bash
docker-compose logs -f [service_name]
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
