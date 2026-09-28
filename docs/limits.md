# Rate limiting, quotas and abuse controls (M4)

This is the docker-repo reference for the Redis-backed rate limiting, quota
and ban system `sockbowl-game` and `sockbowl-questions` both implement. It
exists so nothing in this repo has to cite a design-phase implementation plan
that lives outside this repo to explain itself.

## Why questions depends on redis

M4 added rate limiting, quotas and a ban mirror to both backends, all backed
by the same Redis instance. `sockbowl-questions` therefore now depends on
`redis` (`condition: service_healthy`), and **shares** `sockbowl-game`'s
Redis host, port and DB index — hardcoded to match rather than exposed as
independently overridable env vars, because the two services' limiter,
quota and ban keys (`rl:`, `usage:`, `ban:`, `ipban:` prefixes) are meant to
collide by design and must land in the same Redis DB.

## Identity and tiers

Every request is resolved to a `LimitSubject{sub, ip, tier}`:

- `tier` is the highest composite role on the token: `admin` > `moderator` >
  `author` > `player`. An authenticated user with none of these is `player`.
  Anonymous callers are `guest`. A token whose `azp` is a configured
  `SOCKBOWL_RL_SERVICE_CLIENTS` entry (default `sockbowl-game-backend`) is
  `service` — it skips per-user quotas entirely and uses the `service`
  ceiling policy instead.
- Tier rate-limit multipliers: guest/player 1.0, author 2.0, moderator 3.0,
  admin 10.0 (admin skips quotas but keeps a rate ceiling, so a stolen admin
  token still can't flood the service). `session-create` additionally has a
  guest multiplier of 0.6.
- `ip` is `request.getRemoteAddr()` unless a trusted reverse proxy is
  configured — see `docs/auth.md`'s "Client IP and reverse proxies" section;
  the same resolver and the same env vars (`SOCKBOWL_FORWARD_HEADERS_STRATEGY`,
  `SOCKBOWL_TRUSTED_PROXIES_REGEX`, `SOCKBOWL_REMOTE_IP_HEADER`) apply to
  bans and rate limiting alike.

## Rate-limit policies

Every capacity/refill-period pair below is overridable through a
`SOCKBOWL_RL_*` env var (see `.env.example`'s "Rate limiting, quotas and
abuse controls" section for the exact names); leaving a variable unset (or
commented out) keeps the app's built-in default shown here.

**sockbowl-game:**

| Policy | Key | Default capacity / refill | Applies to |
|---|---|---|---|
| `default` | user-or-ip | 120 / 1m | every non-exempt REST request |
| `service` | user | 6000 / 1m | SERVICE-tier callers instead of `default` |
| `session-create` | user-or-ip | 5 / 10m | `POST .../create-new-game-session` |
| `session-join` | ip | 20 / 1m | join-by-code endpoints (brute-force guard) |
| `ws-connect` | ip | 10 / 1m | STOMP CONNECT |
| `stomp-send-ip` | ip | 120 burst, 60 / 1s | every STOMP SEND, per instance |
| `stomp-buzz` | connection | 5 burst, 3 / 1s | SEND `/app/game/player-incoming-buzz` |

**sockbowl-questions:**

| Policy | Key | Default capacity / refill | Applies to |
|---|---|---|---|
| `default` | user-or-ip | 120 / 1m | REST fallback |
| `service` | user | 6000 / 1m | SERVICE-tier callers |
| `graphql-read` | user-or-ip | 240 / 1m | per top-level GraphQL Query field |
| `graphql-write` | user | 60 / 1m | per top-level GraphQL Mutation field |
| `ai-generate` | user | 10 / 1h, **fails closed** | packet generation (REST and GraphQL) |
| `import` | user | 10 / 1h | qbreader import |

A policy that **fails closed** (`ai-generate`, and the global server-key AI
budget below) returns `503 {"error":"limiter_unavailable"}` when Redis is
down, instead of letting the request through — this is deliberate, since
those calls cost real money against a server-held API key. Everything else
fails open on a Redis outage (logged at WARN at most once a minute), because
`sockbowl.ratelimit.enabled=false` (`SOCKBOWL_RATELIMIT_ENABLED=false`) is
also the documented escape hatch for local dev without Redis.

## Quotas

Quotas cap standing usage rather than request rate. `-1` means unlimited.

| Metric | Enforced in | Kind | guest | player | author | moderator | admin |
|---|---|---|---|---|---|---|---|
| `hosted-sessions` | game | concurrent | 2 | 3 | 5 | 5 | -1 |
| `ai.generations` | questions | daily, server-key calls only | 0 | 0 | 20 | 20 | -1 |
| `imports` | questions | daily | 0 | 0 | 10 | 10 | -1 |
| `packets-owned` | questions | owned count | 0 | 0 | 300 | 300 | -1 |

Bringing your own AI API key (`X-API-Key`) counts against the `ai-generate`
**rate limit** only, never against the `ai.generations` **quota** — the
quota exists to cap spend against the server's own key. Separately, there is
a **global**, server-wide daily budget for server-key generations,
`SOCKBOWL_AI_SERVER_DAILY_BUDGET` (default `200`), which fails closed like
`ai-generate` above; `SOCKBOWL_AI_SERVER_ALLOWED_MODELS` restricts which
model names a server-key call may request.

A hosted session counts against its owner's `hosted-sessions` quota until it
goes idle for `sockbowl.quota.session-idle-timeout` (30 minutes, not
overridable from `.env`) — there's no explicit "end session" call; the quota
recovers on its own once the session goes stale.

## Bans

Bans (subject and IP) are administered in game (`user:ban` permission) and
mirrored into Redis (`ban:{sub}`, `ipban:all`) so both game and questions can
check them without a database round trip. Questions fails a ban check open
if Redis is unreachable, consistent with the rest of the limiter.

## HTTP and GraphQL error shapes

```json
429 {"error":"rate_limited","policy":"session-create","retryAfterSeconds":37,"message":"Too many requests"}
    headers: Retry-After, X-RateLimit-Limit, X-RateLimit-Remaining, X-RateLimit-Policy
429 {"error":"quota_exceeded","metric":"ai.generations","limit":20,"used":20,"resetsAt":"...|null"}
503 {"error":"limiter_unavailable","policy":"ai-generate"}
403 {"error":"banned","reason":"...","expiresAt":"...|null"}
403 {"error":"ip_banned","expiresAt":"..."}
```

GraphQL errors mirror the same fields as extensions on a typed error
(`RATE_LIMITED`, `QUOTA_EXCEEDED`, `BANNED`, `LIMITER_UNAVAILABLE`); a
GraphQL response is still HTTP 200 unless the coarse per-request policy
trips. STOMP rejections use game's existing `ERROR`-frame contract
(`StompErrorCode` gains `RATE_LIMITED`, `QUOTA_EXCEEDED`, `IP_BANNED`) — see
`docs/auth.md`.

## Compose overlays

Three overlays layer on top of each other, each for a different purpose —
see the README's "Limits and quotas" section for the exact commands and
project-name conventions:

- **`docker-compose.dev.yml`** relaxes rate policies and hosted-session
  quotas so a Playwright worker pool or bot harness sharing one IP doesn't
  get throttled by the production-sized defaults above. It's part of the
  normal local-dev and e2e/CI stack.
- **`docker-compose.limits-e2e.yml`** does the opposite for M4's own specs:
  tiny `session-create`/`stomp-buzz` limits and the real (small)
  hosted-session quotas, so a spec can trip a limit and observe recovery
  within its own timeout. Always layered on top of the dev overlay, never
  standalone, and always under its own project name.
- **`docker-compose.e2eauth-relax.yml`** undoes `limits-e2e.yml` for
  `sockbowl-game` only, so M2's `e2e:auth` regression suite can run right
  after `limits-e2e.yml`'s specs on the same stack, without a full
  teardown/bring-up cycle.

## Env var reference

Every `SOCKBOWL_RL_*`/`SOCKBOWL_QUOTA_*` override is documented, commented
out by default, in `.env.example`'s "Rate limiting, quotas and abuse
controls" section — uncommenting one overrides that single policy or quota;
leaving it alone keeps the default from the tables above.
