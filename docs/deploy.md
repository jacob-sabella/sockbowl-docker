# Deploying sockbowl (M7)

Operator runbook for the M7 cutover: sockbowl.com's replacement, served at
`https://sockbowl.jacobsabella.com` from the same shared VPS (`vps-402949b3`,
15.204.11.205) that already runs the `mage-*` and `aa-*` stacks. This is the
authoritative day-to-day reference; `plans/m7-deploy.md` is the design
document this runbook implements (§5 "Data migration and cutover" is this
file's source of truth — read it first if anything here is ambiguous).

Every script referenced below lives in `scripts/deploy/` (plus
`scripts/deploy-keycloak-theme.sh` for theme pushes) and takes `--dry-run` —
**always dry-run a step first** and read the printed commands before running
it for real. Every script also refuses outright if it's pointed at the
legacy `sockbowl-docker` project (dir or `COMPOSE_PROJECT_NAME`), and refuses
to touch any `mage-*`/`aa-*`/`*watchtower*` container — the one exception is
`caddy-apply.sh`, which may `docker exec aa-caddy caddy validate|reload`
(never stop/rm/recreate it).

## 1. Prerequisites

- **SSH access** to the VPS as `ubuntu`, key `~/.ssh/homelab` (D23; override
  with `SSH_KEY`, `VPS_USER`, `VPS_HOST` env vars if yours differ).
- **Local Docker** with buildx, to build `sockbowl-game`, `sockbowl-questions`
  and `sockbowl-ng` images locally (per repo: `./gradlew bootBuildImage` for
  the Spring services, `npm run buildprod && docker build` for ng). Tag them
  `sockbowl-{game,questions,ng}:m7-<short-sha>` (§4.4) — never `:latest` or
  `:main`; `ship-images.sh` refuses both.
- **zstd** locally and on the VPS (image shipping compresses with it).
- **`jq`, `openssl`, `shellcheck`** locally for the scripts and their tests.
- **At least 10 GB free** on the VPS filesystem holding `/home/ubuntu`
  (`preflight.sh` checks this and stops below the threshold; ~8 GB is the
  estimated real need).
- **Outbound GitHub access from the VPS** (the `neo4j-plugin-init` container
  downloads APOC and GDS 2026.09 on first boot).
- **A Cloudflare API token** for `aa-caddy`'s existing `acme_dns cloudflare`
  directive (already configured on the box; nothing new to set up for TLS
  itself — DNS-01 needs no A record, so certs can be obtained before DNS
  exists).
- **This repo, branch `main`**,
  clean and committed — `sync-bundle.sh` ships only `git archive`'s output,
  so anything uncommitted never reaches the VPS.

Read `plans/m7-deploy.md` §6 before L4/L5: several steps below need an
**owner decision** (O1–O14) that this runbook can't make for you. The
defaults noted per step are the plan's defaults, not a guess.

## 2. DNS (§6 O1)

**Owner-only, done once, any time before or during L4/L5** (DNS-01 needs no
A record, so this can happen in parallel with everything else):

1. In the Cloudflare zone `jacobsabella.com`, create an **A record
   `sockbowl` → `15.204.11.205`**, TTL Auto, no AAAA.
2. Proxy status: **default DNS-only (grey)**, matching `magic.` and
   `armagetronad.`. Turning on the orange-cloud proxy is allowed (WebSockets
   work on all Cloudflare plans; the 100s idle timeout is well above our 10s
   STOMP heartbeats) but changes the client-IP story — see O2 below.
3. **O2 (client IP, material):** rootless Docker's port driver erases the
   real client IP, so every request looks like it comes from one address.
   That makes per-IP rate limits, guest quotas (2 hosted sessions per IP),
   and IP bans effectively site-wide unless one of these is done:
   - **A (recommended):** enable the Cloudflare proxy + **Authenticated
     Origin Pulls**, and re-render Caddy's site block with
     `--render-cf-pull-ca-pem <cloudflare-origin-pull-ca.pem>` (see
     `render-caddy.sh --help` for exactly what this changes — it maps
     `CF-Connecting-IP` into `X-Forwarded-For` and requires the CF origin
     certificate on this site only). Also set Cloudflare SSL/TLS to **Full
     (strict)** and turn on "Always Use HTTPS".
   - **B:** switch rootlesskit to `slirp4netns` — this **restarts every
     container on the host**, including `mage-*`/`aa-*`. Disruptive; avoid
     unless A is rejected.
   - **C (the fallback if no decision arrives before L3):** accept the
     single-IP limitation; set generous per-IP capacities/quotas in `.env`
     and note IP bans won't be effective (subject/account bans still work).
4. Only after the record exists and has propagated, proceed to L5 (§5).

## 3. First boot (staging a brand-new environment: §5 L2)

Non-disruptive — the old stack keeps running throughout.

```
scripts/deploy/sync-bundle.sh --ref main --remote-dir /home/ubuntu/sockbowl-prod
ssh -i ~/.ssh/homelab ubuntu@15.204.11.205
  cd /home/ubuntu/sockbowl-prod
  scripts/deploy/make-env.sh                      # fills .env from .env.prod.example
scripts/deploy/ship-images.sh --image sockbowl-game:m7-<sha> \
  --image sockbowl-questions:m7-<sha> --image sockbowl-ng:m7-<sha>
# back on the VPS:
  scripts/deploy/up.sh --project-dir /home/ubuntu/sockbowl-prod -- pull kafka postgres redis neo4j
  scripts/deploy/up.sh --project-dir /home/ubuntu/sockbowl-prod -- config -q
  scripts/deploy/up.sh --project-dir /home/ubuntu/sockbowl-prod -- ps   # must be empty
```

`make-env.sh` fills every `CHANGE_ME*` secret in `.env.prod.example` from
`/home/ubuntu/sockbowl-docker/.env.alpha` when a same-named value already
exists there (so a redeploy keeps the same DB/Keycloak/game-backend
credentials the old stack used), or generates a fresh one with
`openssl rand -hex 32`. `OPENAI_API_KEY` is the one exception — it can't be
generated; if it's missing from the old env, `make-env.sh` leaves the
placeholder and prints a loud warning, and you fill it in by hand before
`up.sh` starts `sockbowl-questions` (everything else boots fine without it;
only AI packet generation fails until it's set — see O13).

**No containers are started in this step.** First real boot happens inside
L3 below, as part of the migration (an empty stack has nothing meaningful to
serve on its own before the data is there).

**Rollback:** `scripts/deploy/rollback.sh --step l2 --project-dir /home/ubuntu/sockbowl-prod --image sockbowl-game:m7-<sha> ...`
— removes the staged directory and the pulled/loaded image tags. The old
stack was never touched, so there's nothing else to undo.

**Done when:** `ship-images.sh`'s manifest shows matching image IDs on both
ends, and `config -q` validates with no output.

## 4. Migration and cutover (§5 L1, L3, L4 — the disruptive part)

### 4.1 Preflight and backups (L1, non-disruptive)

```
scripts/deploy/preflight.sh --project-dir /home/ubuntu/sockbowl-docker
scripts/deploy/backup.sh --mode dump --project sockbowl-docker \
  --pg-container sockbowl-docker-postgres-1 \
  --databases keycloak,sockbowl,sockbowl_users
scripts/deploy/backup.sh --mode pull --remote-dir /home/ubuntu/sockbowl-backups/<ts> \
  --local-dir ~/sockbowl-backups/<ts>          # O7: off-host copy, chmod 700
```

`preflight.sh` is read-only: disk/RAM checks, confirms no stray
`sockbowl-prod*` containers/volumes exist yet, records the live Caddyfile's
sha256 (for L4/rollback drift detection), and derives the
`SOCKBOWL_TRUSTED_PROXIES_REGEX` value for `.env` (printed to a file, never
written into a live `.env` automatically).

`backup.sh --mode dump` takes `pg_dump -Fc` of each database plus
`pg_dumpall --globals-only` and an online Neo4j export via APOC
(`apoc.export.cypher.all` — Neo4j Community has no online backup). Nothing
is ever printed except file paths and sha256 checksums; dump *contents* are
never echoed. This is also exactly what O14's proposed nightly cron entry
runs post-cutover, unmodified.

**Rollback:** none needed — L1 only adds new files under
`~/sockbowl-backups`.

**Done when:** local and remote sha256 sums match, and
`pg_restore --list <dump>` succeeds on every dump.

### 4.2 The disruptive cutover (L3)

Re-run a fresh `backup.sh --mode dump` immediately before this step (users
may have changed since L1), then:

```
scripts/deploy/migrate-data.sh \
  --old-project-dir /home/ubuntu/sockbowl-docker --old-env-file .env.alpha \
  --new-project-dir /home/ubuntu/sockbowl-prod --new-project sockbowl-prod \
  --neo4j-old-image <old-neo4j-image-id> --neo4j-new-image neo4j:2026.09 \
  --neo4j-old-volume sockbowl-docker_neo4j_data --neo4j-new-volume sockbowl-prod_neo4j_data \
  --neo4j-backup-dir /home/ubuntu/sockbowl-backups/<ts>/neo4j \
  --keycloak-dump /home/ubuntu/sockbowl-backups/<ts>/keycloak.dump \
  --sockbowl-dump /home/ubuntu/sockbowl-backups/<ts>/sockbowl.dump \
  --pg-container sockbowl-prod-postgres-1 --pg-user postgres \
  --baseline audit/m7/baseline-counts.json
```

This one script orchestrates all of §5 L3 steps 1–7 in order: stop the old
`sockbowl-docker` project (only — the script verifies `mage-*`/`aa-*` are
still Up afterward), offline-dump Neo4j with the **old** binary, load it into
a fresh volume with the **new** one (2026.09 upgrades the store format
in-place on first start), restore both Postgres dumps into a fresh PG 18,
bring up Keycloak 26.7.4 and wait for `/auth/health/ready`, run `rbac-init`
(the exact-set client/redirect-URI reconcile), then boot everything else and
run `verify.sh --mode counts` against the L1 baseline (tolerance 0). Each
substep is individually re-runnable from its own script if this needs to be
resumed partway (see `migrate-data.sh --help`).

Real execution of this script against the live VPS is an opus-supervised
step (§8) — it is never run for real outside `--dry-run` by this WP.

**Rollback:** `scripts/deploy/rollback.sh --step l3 --new-project sockbowl-prod --new-project-dir /home/ubuntu/sockbowl-prod --old-project-dir /home/ubuntu/sockbowl-docker --old-env-file .env.alpha`
— brings the new stack down (**no `-v`**, so the new volumes survive for
forensics) and starts the old stack back up exactly as it was (its volumes
were only ever read from, never written, during L3).

**Done when:** every `verify.sh --mode counts` row matches baseline at
tolerance 0, `docker stats` total is under 7.0 GiB with no OOMKilled
container, and the questions logs show the expected migration lines
(`PacketVisibilityMigration`, `ProvenanceBackfillRunner`,
`TaxonomySchemaInitializer`).

### 4.3 Caddy site block (L4)

```
ssh -i ~/.ssh/homelab ubuntu@15.204.11.205 'bash -s' -- \
  --caddyfile /path/to/live/Caddyfile --drop-legacy \
  --render-host sockbowl.jacobsabella.com --render-mode prod \
  --check-domain magic.jacobsabella.com --check-domain armagetronad.jacobsabella.com \
  < scripts/deploy/caddy-apply.sh
```

(`caddy-apply.sh` itself never spells `ssh` — it's meant to run directly on
the VPS via a heredoc exactly like this, so nothing sensitive is ever copied
off the box as an intermediate file.) It backs up the live Caddyfile
(`Caddyfile.bak.pre-m7-<ts>`, mode 600, same directory), splices in the
rendered `sockbowl-m7` block (optionally dropping the four dead legacy
`sockbowl.com` blocks, O6), prints **only the changed lines**
(`diff -U0` — a secret sitting in an untouched block can never appear in the
printed diff), validates the candidate inside the running `aa-caddy`
container before writing anything, writes with `cat >` (preserves the
file's inode — aa-caddy's open file descriptor and any bind-mount identity
survive the edit), then `docker exec aa-caddy caddy reload`. `--check-domain`
re-curls any other domain aa-caddy serves to confirm it's unaffected.

Once applied, watch `docker logs aa-caddy` for
`certificate obtained successfully ... sockbowl.jacobsabella.com` (DNS-01
needs no A record, so this can succeed before O1's record is even created).
Then verify by hand (this is also `verify.sh --mode curl`, see §5 below):

```
scripts/deploy/verify.sh --mode curl --host sockbowl.jacobsabella.com --ip 15.204.11.205
node scripts/stomp-probe.mjs <config.json>   # SOCKBOWL_RESOLVE=sockbowl.jacobsabella.com:443:15.204.11.205
```

**Rollback:** `scripts/deploy/rollback.sh --step l4 --caddyfile /path/to/live/Caddyfile --rollback-ts <ts>`
(delegates to `caddy-apply.sh --rollback <ts>`, which restores the
byte-identical backup file and reloads).

**Done when:** every curl/STOMP check passes and the certificate's issuer is
Let's Encrypt.

### 4.4 Public verification (L5) and decommission (L6)

After O1's DNS record has propagated: repeat the §4.2 curl set **without**
`--resolve`, run the Playwright suites against the live host (guest suite,
`e2e npm run smoke`, one full-match as a guest, the cast receiver page),
create a temporary Keycloak user for an authenticated UI-login check (O10;
delete it afterward), and have the owner confirm a real login (plus Google,
once O5's redirect URI is added). Record evidence in
`audit/m7/live-verify.md`.

L6 (decommission) only happens after **7 days of soak** and the owner's
explicit go-ahead: disconnect `aa-caddy` from the old
`sockbowl-docker_sockbowl` network, `docker compose -p sockbowl-docker rm`
the stopped containers — **volumes are kept** until the owner separately
approves deleting `neo4j_data`/`postgres_data`.

## 5. Verification (routine, and after any change)

`scripts/deploy/verify.sh` is read-only and safe to run at any time against
a live deploy — it never starts, stops or changes anything.

- **`--mode curl --host HOST [--ip IP] [--cacert FILE]`**: the shared HTTP
  probe set — `/` (200), `/assets/config.js` (200, path-mode URL),
  the OIDC discovery document (issuer matches the public URL), `/auth/admin/`
  (404 — O4), `/questions/actuator/health` (404 — never public),
  `POST /api/v1/session/create-new-game-session` (200/400, never 404 — proves
  `/api/*` reaches game, not ng's SPA fallback), `/questions/api/qbreader/category-counts`
  (200 — proves the `/questions/*` prefix strip), and a WebSocket upgrade on
  `/ws` (101, or any non-404 status).
- **`--mode counts --project NAME (--write-baseline FILE | --baseline FILE)`**:
  compares Neo4j label/relationship counts, Keycloak realm/user/IdP/
  federated-identity/credential counts, and
  `sockbowl_legacy.user_used_question`, via `docker compose exec` (never an
  exposed port). Used at L1 (`--write-baseline`) and L3/ongoing
  (`--baseline`, tolerance 0).

For the full auth/REST/GraphQL/STOMP matrix, see `scripts/smoke-auth.sh`
(delegates its WebSocket half to `scripts/stomp-probe.mjs`) — path mode:

```
SOCKBOWL_PATH_MODE=1 SOCKBOWL_PUBLIC_URL=https://sockbowl.jacobsabella.com \
SMOKE_RESOLVE=sockbowl.jacobsabella.com:443:<ip> SMOKE_CACERT=<ca.crt> \
NEO4J_CONTAINER=<project>-neo4j-1 COMPOSE_PROJECT_NAME=<project> \
DEMO_PASSWORD=... SOCKBOWL_GAME_BACKEND_SECRET=... NEO4J_PASSWORD=... \
bash scripts/smoke-auth.sh
```

`SMOKE_RESOLVE`/`SMOKE_CACERT` are forwarded to `stomp-probe.mjs` as
`SOCKBOWL_RESOLVE`/`NODE_EXTRA_CA_CERTS` — needed for a local rehearsal
resolving the public hostname to `127.0.0.1` against Caddy's internal CA
(§7), and equally usable with a real IP/real CA against the VPS directly,
before DNS exists. A live stack has small per-IP rate-limit and per-guest
hosted-session quota budgets (`SOCKBOWL_RL_SESSION_CREATE_*`,
`SOCKBOWL_QUOTA_*_HOSTED_SESSIONS` in `.env.prod.example`) — running this
script (or manual curl probing) many times in quick succession from the same
address can exhaust them and produce `429`s that look like failures but
aren't; either space runs out, or temporarily set
`SOCKBOWL_RATELIMIT_ENABLED=false`/`SOCKBOWL_QUOTA_ENABLED=false` in a
**local rehearsal's own env only** (never in the real `.env` on the VPS).

## 6. Rollback

One entry point, `scripts/deploy/rollback.sh`, for every non-L1 rollback
(L1 needs none — see §4.1):

| `--step` | Undoes | What it does |
|---|---|---|
| `l2` | staged-but-not-started bundle | `rm -rf <project-dir>`, `docker image rm` each `--image` |
| `l3` | migrated-and-booted new stack | `docker compose -p <new-project> down` (no `-v`), restart the old `sockbowl-docker` stack, verify it's Up |
| `l4` | a bad Caddy reload | delegates to `caddy-apply.sh --rollback <ts>` (byte-identical restore + reload) |

Every step refuses to target the legacy project as its own destination (it
would make no sense to "roll back" onto `sockbowl-docker`), and every
container action carries the same `mage-*`/`aa-*`/`watchtower` guard as
every other script here.

## 7. Backups and restores

`scripts/deploy/backup.sh --mode dump` (see §4.1) is reusable indefinitely
after cutover — O14 proposes a nightly VPS crontab entry running it
unmodified, with 7-day retention, plus `backup.sh --mode pull` on a
schedule from the operator's machine for the off-host copy (O7). To restore
from a dump, see `migrate-data.sh`'s own steps 3–4 (Neo4j
`neo4j-admin database load --overwrite-destination=true`; Postgres
`pg_restore --no-owner --role=$POSTGRES_USER -d <db>`) — run them by hand
against the specific dump you need, rather than the whole orchestration
script, if you're restoring outside a full migration.

`backup.sh --mode offline-neo4j` (stops the `neo4j` container) is the
**disruptive**, authoritative dump path used only inside `migrate-data.sh`
at real cutover — never run it against a live serving stack outside that
one scripted moment.

## 8. Theme deploys

```
scripts/deploy-keycloak-theme.sh
```

Rsyncs `keycloak/themes/sockbowl` to the VPS's project dir, then
**restarts** the `keycloak` container. This changed in M7: the prod overlay
runs Keycloak with `start` (§3.5), not the old `start-dev`, and `start`
caches themes — a plain file sync no longer takes effect on its own, so this
script now restarts the container (bind mount and realm config are
untouched, so no data changes; expect a brief availability gap during the
restart). Guarded the same way as everything else (refuses `sockbowl-docker`,
refuses any `mage-*`/`aa-*`/`watchtower` container name).

## 9. Routine app deploys (after cutover)

For a routine `sockbowl-game`/`sockbowl-questions`/`sockbowl-ng` update with
no data migration involved:

```
scripts/deploy/ship-images.sh --image sockbowl-game:m7-<new-sha> ...
scripts/deploy/up.sh --project-dir /home/ubuntu/sockbowl-prod -- pull sockbowl-game sockbowl-questions sockbowl-ng
scripts/deploy/up.sh --project-dir /home/ubuntu/sockbowl-prod -- up -d --profile full
scripts/deploy/verify.sh --mode curl --host sockbowl.jacobsabella.com
```

`up.sh` is a thin, guarded wrapper around `docker compose` — it never
invents commands of its own, it just supplies the right
`-p`/`--env-file`/`-f` flags and forwards everything after `--` verbatim, so
every call site (staging, migration, a local rehearsal, this routine
redeploy) uses the identical project identity and guard.

## 10. Local rehearsal (WP-V1, §7)

Everything above can — and should — be rehearsed locally first, under the
fullstack lock, before touching the VPS: a throwaway Compose project served
at `https://sockbowl.jacobsabella.com` resolved to `127.0.0.1` via a local
Caddy with an internal CA (no `/etc/hosts` edits). See `plans/m7-deploy.md`
§7 for the full recipe (image tags, `scripts/deploy/verify.compose.yml`,
extracting the internal CA with
`docker compose cp caddy:/data/caddy/pki/authorities/local/root.crt`, and
the full gate list). The same `--resolve`/`--cacert` pattern used there for
curl, and `SOCKBOWL_RESOLVE`/`NODE_EXTRA_CA_CERTS` for
`smoke-auth.sh`/`stomp-probe.mjs`, is exactly what §4.3 and §5 above reuse
against the real VPS before DNS exists.
