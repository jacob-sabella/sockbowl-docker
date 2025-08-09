# Sockbowl Docker

Sockbowl Docker provides scripts and containerization assets to set up the Sockbowl platform's infrastructure, including Redis, Neo4j, and essential plugins/modules. These scripts automate the process of downloading, configuring, and initializing required services for development and production environments.

## Features

- **Redis Modules:** Shell script to copy essential Redis modules (`redisearch.so`, `rejson.so`) for advanced queries and JSON support.
- **Neo4j Plugins:** Automated download and configuration of Neo4j plugins (APOC, Graph Data Science).
- **Neo4j Initialization:** Script to automatically import base data into Neo4j if not already present.
- **Container-Ready:** Designed for use in Docker containers and CI/CD pipelines.

## Usage

- Run `scripts/download-redis-modules.sh` within a Redis container to copy modules.
- Run `scripts/download-neo4j-plugins.sh` in a Neo4j container to download plugins and update config.
- Run `scripts/init-neo4j.sh` to initialize Neo4j with base packet data.

## Requirements

- Docker
- Redis Stack
- Neo4j

## License

MIT License. See `LICENSE` for details.

---

*Created by Jacob Sabella*
