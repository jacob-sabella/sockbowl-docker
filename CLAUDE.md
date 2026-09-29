# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with
code in this repository.

## Project overview

`sockbowl-docker` is the infrastructure repo for the Sockbowl platform: the
`docker-compose.yml` stack (Kafka, Postgres, Keycloak, Neo4j, Redis, and the
three app images), the Keycloak realm/RBAC model, and the shell/Node scripts
that seed, verify and smoke-test the stack. It contains no application code —
`sockbowl-game`, `sockbowl-questions` and `sockbowl-ng` are separate repos,
run either from source (local dev) or as images this repo composes together.

See `README.md` for setup and usage, `docs/auth.md` for the authentication
and RBAC design, and `docs/limits.md` for rate limiting, quotas and bans.

## Architecture

- **`docker-compose.yml`** — the base stack. Every service uses
  `network_mode: host` (advertised addresses are `${APP_HOST}:<port>`, and
  only one full stack can be up on a host at a time — see `docs/auth.md`
  "Single full-stack constraint"). Infra (Kafka, Postgres, Keycloak, Neo4j,
  Redis, plus one-shot init jobs) starts with a bare `docker compose up`;
  the three app services and watchtower are gated behind Compose **profiles**
  (`full` for the apps, `autoupdate` for watchtower) so local dev can run the
  apps from source against infra-only.
- **Overlays** (`-f` layered on top of the base file, never used standalone
  except `docker-compose.build.yml`):
  - `docker-compose.dev.yml` — local/e2e posture: `start-dev` Keycloak, demo
    accounts, the `sockbowl-e2e` direct-grant client, `ALLOW_INSECURE_DEFAULTS`,
    and relaxed rate limits/quotas (see `docs/limits.md`).
  - `docker-compose.build.yml` — points the `full` profile at locally built
    images (`sockbowl-{game,questions,ng}:local`) instead of the published
    GHCR `:main` tags.
  - `docker-compose.limits-e2e.yml` — M4's own tiny test limits, layered on
    top of the dev overlay only.
  - `docker-compose.e2eauth-relax.yml` — undoes `limits-e2e.yml` for
    `sockbowl-game` only, so `e2e:auth` can run right after M4's specs
    without a full stack cycle.
- **`keycloak/`** — `rbac-model.json` (the single source of truth for
  permission roles, composite/tier roles, the default role, the audience,
  service-client roles and demo users), `clients/*.json` (per-client
  templates, `envsubst`'d), `realm-settings.json`, `realm-export.template.json`,
  and the `themes/sockbowl` login theme.
- **`scripts/`** — realm/RBAC bring-up (`init-keycloak-realm.sh`,
  `load-rbac.sh`, sourcing `check-secrets.sh`), Neo4j plugin/data init
  (`download-neo4j-plugins.sh`, `init-neo4j.sh`), Postgres init
  (`init-postgres.sh`), the auth smoke test and its STOMP probe
  (`smoke-auth.sh`, `stomp-probe.mjs`), acceptance tests
  (`test-compose-posture.sh`, `test-limits-wiring.sh`,
  `test-rbac-reconcile.sh`, `check-env-example.sh`), a unit test
  (`test-kafka-readiness.sh`), `lib/` (`kafka-consumer-stability.sh`, and
  `clean-clone-test.sh`'s `wait-healthy.sh`), and `healthcheck/` (a tiny
  Java HTTP probe run via the buildpack JRE, since the game/questions images
  have no shell or curl — see `scripts/healthcheck/README.md`).
- **`docs/`** — `auth.md`, `limits.md`, and `superpowers/` (the original
  design spec and implementation-verification notes, kept for history; the
  two docs above are the maintained summaries).

## RBAC and security rules to keep

- **Reconcile, don't just add.** `load-rbac.sh` must keep reconciling the
  realm against `rbac-model.json` (composites, clients, demo users, the
  audience mapper, realm settings) — including pruning roles and clients that
  fell out of the model, and disabling (not deleting) demo users when
  `CREATE_DEMO_ACCOUNTS=false`. A loader that only adds silently accumulates
  drift no one notices.
- **`packet:read-answers` stays service-only.** It must never be added to any
  user-facing composite role — it exists so the game service account can
  fetch full packet content (including answers); see `docs/auth.md`.
- **Compose stays production-capable by default (D9).** `docker-compose.yml`
  alone must keep `start` (not `start-dev`), strict Keycloak hostname
  checking, demo accounts off, and no direct-grant client. Anything that
  relaxes this belongs in `docker-compose.dev.yml`, never in the base file.
- **`check-secrets.sh`'s refusal is load-bearing.** Don't add a way around it
  other than the existing `ALLOW_INSECURE_DEFAULTS` escape hatch, and don't
  let a new secret-shaped variable skip it silently — add it to the checked
  list in `scripts/check-secrets.sh` too.
- **Client IP trust is security-critical.** Never make `native` forwarded-header
  trust the default, and never let `SOCKBOWL_TRUSTED_PROXIES_REGEX` default to
  something broader than the actual reverse proxy's address — see
  `docs/auth.md` "Client IP and reverse proxies". This is shared logic
  between the RBAC/ban layer and the rate limiter.
- **The `full`/`autoupdate` profile split is deliberate.** Watchtower
  (`containrrr/watchtower`, archived upstream) auto-pulls and restarts
  containers; it must stay opt-in (`--profile autoupdate`), not bundled into
  `full` by default.
- **Redis key prefixes are a cross-repo contract.** `rl:`, `usage:`, `ban:`
  and `ipban:` are shared verbatim between game and questions (`UsageKeys` in
  each repo must stay identical — see `docs/limits.md`). Don't repurpose
  these prefixes here (e.g. in a new init script) without checking both app
  repos.
- **`.env.example` holds placeholders, not real secrets.** Anything shaped
  like `*_PASSWORD`/`*_SECRET`/`*_KEY` must stay empty or `CHANGE_ME_*`;
  `scripts/check-env-example.sh` enforces this (see "Tests" below) and also
  fails if a variable compose reads from `.env` has no line in
  `.env.example` — keep them in lock-step whenever a compose file or an
  overlay adds a new `${VAR}` or bare passthrough key.
- **Never put answers in a broadcast payload.** Game reads full packet
  content from questions over the service-to-service call and evaluates
  buzzes server-side; nothing in this repo's compose wiring or scripts should
  need to carry answer content anywhere else.

## Tests and scripts

Run individually from the repo root (they `cd` to it internally):

| Script | What it does | Needs |
|---|---|---|
| `scripts/check-env-example.sh` | `.env.example` completeness + no real secrets | nothing (no Docker) |
| `scripts/test-kafka-readiness.sh` | unit test for the Kafka-readiness log parser | nothing |
| `scripts/test-rbac-reconcile.sh` | RBAC loader reconciliation, against a throwaway Keycloak+Postgres | Docker |
| `scripts/test-compose-posture.sh` | D9 compose posture (placeholder refusal, dev/e2e overlay, demo-user disable) | Docker, one full/keycloak+postgres stack at a time |
| `scripts/test-limits-wiring.sh` | M4 rate-limit/quota compose & env wiring | Docker; `LIMITS_WIRING_LIVE=true` for the live Redis-down gate |
| `scripts/smoke-auth.sh` (+ `stomp-probe.mjs`) | full REST/GraphQL/STOMP auth matrix against an already-running stack | a running dev/e2e stack, real secrets from its `.env` |
| `scripts/clean-clone-test.sh` | simulated clean clone + from-source bring-up + smoke, both auth postures | Docker, Node ≥ 24, Ollama with `mxbai-embed-large`, sibling repo checkouts |

All of the Docker-based scripts use `network_mode: host` stacks, so only one
can run at a time on a given host (see `docs/auth.md` "Single full-stack
constraint"); each takes its own throwaway `-p` project name and tears down
with `-v` on exit.

## Working in this repo

- Compose files, `.env.example`, `keycloak/*.json` and the scripts here are
  read by three completely separate app codebases at runtime. A rename or
  removal here is a breaking change to all of them — grep the sibling repos
  (`sockbowl-game`, `sockbowl-questions`, `sockbowl-ng`) for the env var or
  config key name before renaming it.
- The README's "Quick start from source" section, between the
  `<!-- clean-clone:begin -->`/`<!-- clean-clone:end -->` markers, is executed
  **verbatim** by `scripts/clean-clone-test.sh` — it is not just
  documentation. Don't edit inside those markers without re-running that
  script; keep every command in that block shell-safe (`set -euo pipefail`).
