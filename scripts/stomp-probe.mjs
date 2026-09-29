#!/usr/bin/env node
// stomp-probe.mjs — the STOMP half of scripts/smoke-auth.sh.
//
// A tiny @stomp/stompjs + ws probe against a real sockbowl-game STOMP endpoint
// (see docs/auth.md: StompInboundInterceptor, StompConnectAuthenticator,
// StompDestinationGuard). It takes one argument, a JSON config file describing
// the seats and tokens scripts/smoke-auth.sh already set up over REST/GraphQL/
// Keycloak, and runs a fixed suite of CONNECT/SEND/SUBSCRIBE scenarios against
// them: every STOMP authorization case, named explicitly
// (forged SEND, cross-game SUBSCRIBE, bad secret, banned CONNECT), plus the
// service-to-service proof: the game fetching a packet from
// questions with its own service token, driven end-to-end over a real STOMP
// SetMatchPacket.
//
// Usage: node scripts/stomp-probe.mjs <config.json>
// Exit: 0 if every scenario passed, 1 otherwise. Prints "PASS:"/"FAIL:" lines
// (scripts/smoke-auth.sh's own convention; see scripts/test-rbac-reconcile.sh).
//
// Config shape (all fields required unless noted):
//   wsUrl                 ws(s)://host:port/sockbowl-game
//   guest                 { gameSessionId, playerSessionId, playerSecret } — a
//                         guest-joined seat (join-game-session-by-code).
//   fakeGameSessionId     a syntactically valid but non-existent game id.
//   authSeat              { gameSessionId, playerSessionId, token } — a seat
//                         joined via join-game-session-authenticated as an
//                         author-tier user who owns `packetId` and hosts a
//                         proctorless (SINGLE_PLAYER) game.
//   otherGameSessionId    a second, unrelated real game id (cross-game SUBSCRIBE
//                         target); it need not have `authSeat`'s player in it.
//   mismatchToken         a valid bearer for a *different* user than authSeat's
//                         (identity-mismatch probe).
//   serviceToken          a client-credentials token for sockbowl-game-backend
//                         (service tokens must never authenticate as a player).
//   bannedSeat            { gameSessionId, playerSessionId, token } — another
//                         authenticated seat, for a user smoke-auth.sh has
//                         already banned via the admin API before this script
//                         runs.
//   packetId              a DRAFT (or PUBLISHED/EPHEMERAL) packet id that
//                         authSeat's owner may set on their own match.

import { Client } from '@stomp/stompjs';
import WebSocket from 'ws';
import { readFileSync } from 'node:fs';

const CONFIG_PATH = process.argv[2];
if (!CONFIG_PATH) {
  console.error('usage: node stomp-probe.mjs <config.json>');
  process.exit(2);
}

// SOCKBOWL_RESOLVE=host:port:ip — the same curl-style --resolve triple
// scripts/smoke-auth.sh already applies to every REST/GraphQL call (via
// SMOKE_RESOLVE), forwarded here as this env var (see smoke-auth.sh's own
// comment on SMOKE_RESOLVE). curl's --resolve has no Node equivalent baked
// into `ws`/`http`/`https`, so without this the OS resolver would look up
// the *real* public hostname instead of the local rehearsal stack, which in
// a path-mode local rehearsal either fails outright or, worse, silently
// reaches a different (real) host — surfacing here as onWebSocketError
// (WS_ERROR) on every single scenario, never a STOMP-level error, since the
// TCP/TLS connection itself never reaches this stack's Caddy at all.
// A custom `lookup` (passed straight through by `ws` to node's http/https
// client, which forwards it to net.connect/tls.connect) resolves only the
// configured hostname to the given IP while leaving `servername` as the
// original hostname, so TLS SNI and certificate hostname checks still see
// the name the internal CA (NODE_EXTRA_CA_CERTS) actually issued for.
function buildWsOptions() {
  const raw = process.env.SOCKBOWL_RESOLVE;
  if (!raw) return undefined;
  const parts = raw.split(':');
  if (parts.length !== 3) {
    console.error(`SOCKBOWL_RESOLVE must be host:port:ip, got: ${raw}`);
    process.exit(2);
  }
  const [resolveHost, , resolveIp] = parts;
  return {
    // Node's net.connect (Happy Eyeballs, the default since Node 18) calls a
    // custom `lookup` with `{ all: true }` and expects back an array of
    // `{ address, family }` (not the classic dns.lookup callback shape of
    // `(err, address, family)`) — get this wrong and it throws
    // ERR_INVALID_IP_ADDRESS deep inside net.connect instead of ever
    // reaching this stack's Caddy, which looks identical to a real
    // connection failure (surfaces in stomp-probe.mjs as onWebSocketError).
    lookup: (hostname, opts, cb) => {
      if (hostname !== resolveHost) {
        // Fall back to the real resolver for anything else (there
        // shouldn't be anything else, but never silently misroute it).
        import('node:dns').then(({ lookup }) => lookup(hostname, opts, cb));
        return;
      }
      if (opts && opts.all) {
        cb(null, [{ address: resolveIp, family: 4 }]);
      } else {
        cb(null, resolveIp, 4);
      }
    },
    servername: resolveHost,
  };
}
const WS_OPTIONS = buildWsOptions();

/** @type {any} */
const cfg = JSON.parse(readFileSync(CONFIG_PATH, 'utf8'));
const WS_URL = cfg.wsUrl;
if (!WS_URL) {
  console.error('config is missing "wsUrl"');
  process.exit(2);
}

let passed = 0;
let failed = 0;

function record(name, ok, detail) {
  if (ok) {
    passed++;
    console.log(`PASS: ${name}`);
  } else {
    failed++;
    console.log(`FAIL: ${name}${detail ? ' — ' + detail : ''}`);
  }
}

/**
 * Unwrap a STOMP ERROR frame the same way sockbowl-ng's bot harness does
 * (e2e/harness/bot.ts): `code` is UPPER_SNAKE from the JSON body, falling back
 * to the `x-sockbowl-error`/`message` headers (plan section 2.5,
 * SockbowlStompErrorHandler).
 */
function parseStompError(frame) {
  const body = frame?.body;
  const headers = frame?.headers ?? {};
  let parsed = null;
  try {
    parsed = body ? JSON.parse(body) : null;
  } catch {
    parsed = null;
  }
  const code =
    (parsed && typeof parsed.code === 'string' && parsed.code) ||
    headers['x-sockbowl-error'] ||
    headers['message'] ||
    'INTERNAL';
  return { code, message: parsed?.message ?? null };
}

/**
 * One WebSocket/STOMP connection under test. Tracks every fatal ERROR (there
 * is at most one: the server closes the socket on the first one) and every
 * message delivered to a subscription, and lets scenarios wait for either.
 */
class Probe {
  constructor(connectHeaders) {
    this.connected = false;
    this.errors = [];
    this._listeners = [];
    this.client = new Client({
      webSocketFactory: () =>
        WS_OPTIONS ? new WebSocket(WS_URL, [], WS_OPTIONS) : new WebSocket(WS_URL),
      connectHeaders,
      reconnectDelay: 0,
      heartbeatIncoming: 0,
      heartbeatOutgoing: 0,
      onConnect: () => {
        this.connected = true;
        this._fire();
      },
      onStompError: (frame) => {
        this.errors.push(parseStompError(frame));
        this._fire();
      },
      onWebSocketError: (e) => {
        this.errors.push({ code: 'WS_ERROR', message: String(e?.message ?? e) });
        this._fire();
      },
    });
  }

  _fire() {
    this._listeners.forEach((l) => l());
  }

  connect() {
    this.client.activate();
    return this;
  }

  subscribe(destination, onMessage) {
    return this.client.subscribe(destination, onMessage);
  }

  send(destination, headers, body) {
    this.client.publish({ destination, headers: headers ?? {}, body: JSON.stringify(body ?? {}) });
  }

  close() {
    try {
      this.client.deactivate();
    } catch {
      /* ignore */
    }
  }

  /**
   * Resolve as soon as `pred(this)` is true, a fatal error arrives, or
   * `timeoutMs` elapses. Never rejects.
   * @returns {Promise<{ok: boolean, code?: string, message?: string}>}
   */
  waitUntil(pred, timeoutMs) {
    return new Promise((resolve) => {
      let done = false;
      const cleanup = () => {
        clearTimeout(timer);
        this._listeners = this._listeners.filter((l) => l !== check);
      };
      const check = () => {
        if (done) return;
        if (this.errors.length) {
          done = true;
          cleanup();
          resolve({ ok: false, code: this.errors[0].code, message: this.errors[0].message });
          return;
        }
        if (pred(this)) {
          done = true;
          cleanup();
          resolve({ ok: true });
        }
      };
      const timer = setTimeout(() => {
        if (done) return;
        done = true;
        cleanup();
        resolve({ ok: false, code: 'TIMEOUT' });
      }, timeoutMs);
      this._listeners.push(check);
      check();
    });
  }
}

function describeFailure(r, expectedCode) {
  if (r.ok) return `expected ERROR ${expectedCode}, but the action succeeded`;
  return `expected ${expectedCode}, got ${r.code}${r.message ? ': ' + r.message : ''}`;
}

/** CONNECT must fail with exactly `expectedCode`. */
async function expectConnectError(name, connectHeaders, expectedCode, timeoutMs = 8000) {
  const p = new Probe(connectHeaders).connect();
  const r = await p.waitUntil((pr) => pr.connected, timeoutMs);
  p.close();
  if (!r.ok && r.code === expectedCode) record(name, true);
  else record(name, false, describeFailure(r, expectedCode));
}

/** CONNECT must succeed (used as a sanity check that the happy path still works). */
async function expectConnectOk(name, connectHeaders, timeoutMs = 8000) {
  const p = new Probe(connectHeaders).connect();
  const r = await p.waitUntil((pr) => pr.connected, timeoutMs);
  p.close();
  if (r.ok) record(name, true);
  else record(name, false, `CONNECT failed: ${r.code}${r.message ? ': ' + r.message : ''}`);
}

/**
 * CONNECT must succeed, then `action(probe)` must provoke a fatal ERROR with
 * exactly `expectedCode` (every SEND/SUBSCRIBE rejection is fatal per plan
 * section 2.5: "Fatal vs non-fatal").
 */
async function expectActionError(name, connectHeaders, action, expectedCode, timeoutMs = 8000) {
  const p = new Probe(connectHeaders).connect();
  const connectResult = await p.waitUntil((pr) => pr.connected, timeoutMs);
  if (!connectResult.ok) {
    p.close();
    record(name, false, `setup CONNECT failed: ${connectResult.code}`);
    return;
  }
  action(p);
  const r = await p.waitUntil(() => false, timeoutMs);
  p.close();
  if (!r.ok && r.code === expectedCode) record(name, true);
  else record(name, false, describeFailure(r, expectedCode));
}

/**
 * AUTH-18 end-to-end: CONNECT as the packet's own author, SEND SetMatchPacket,
 * and wait for the MatchPacketUpdate broadcast that only appears once the game
 * server has fetched the packet from questions with its own service token
 * (WP-G4's PacketClient/JwtDecoderConfig) and the D2/D15 visibility check has
 * let it through.
 */
async function serviceTokenPathE2e(name, authSeat, packetId, timeoutMs = 15000) {
  const connectHeaders = {
    gameSessionId: authSeat.gameSessionId,
    playerSessionId: authSeat.playerSessionId,
    Authorization: `Bearer ${authSeat.token}`,
  };
  const p = new Probe(connectHeaders).connect();
  const connectResult = await p.waitUntil((pr) => pr.connected, 8000);
  if (!connectResult.ok) {
    p.close();
    record(name, false, `CONNECT failed: ${connectResult.code}`);
    return;
  }

  let matched = false;
  let lastError = null;
  const onMessage = (m) => {
    let parsed;
    try {
      parsed = JSON.parse(m.body);
    } catch {
      return;
    }
    const batch =
      parsed?.messageContentType === 'SockbowlMultiOutMessage' && Array.isArray(parsed.sockbowlOutMessages)
        ? parsed.sockbowlOutMessages
        : [parsed];
    for (const item of batch) {
      if (item?.messageContentType === 'MatchPacketUpdate' && item.packetId === packetId) matched = true;
      if (item?.messageContentType === 'ProcessError') lastError = item;
    }
  };
  p.subscribe(`/queue/event/${authSeat.gameSessionId}`, onMessage);
  p.subscribe(`/queue/event/${authSeat.gameSessionId}/${authSeat.playerSessionId}`, onMessage);

  p.send(
    '/app/game/config/set-match-packet',
    { gameSessionId: authSeat.gameSessionId, playerSessionId: authSeat.playerSessionId },
    { packetId },
  );

  await p.waitUntil(() => matched || lastError !== null, timeoutMs);
  p.close();

  if (matched) record(name, true);
  else if (lastError) record(name, false, `game returned ProcessError ${lastError.code ?? ''}: ${lastError.error ?? ''}`);
  else record(name, false, `no MatchPacketUpdate for packetId=${packetId} within ${timeoutMs}ms`);
}

async function main() {
  const { guest, fakeGameSessionId, authSeat, otherGameSessionId, mismatchToken, serviceToken, bannedSeat, packetId } =
    cfg;

  // ---- CONNECT: guest / credential rows (section 4.1) ----
  await expectConnectError(
    'guest CONNECT with no playerSecret header -> AUTH_REQUIRED',
    { gameSessionId: guest.gameSessionId, playerSessionId: guest.playerSessionId },
    'AUTH_REQUIRED',
  );
  await expectConnectError(
    'bad secret: guest CONNECT with the wrong playerSecret -> INVALID_CREDENTIALS',
    { gameSessionId: guest.gameSessionId, playerSessionId: guest.playerSessionId, playerSecret: 'not-the-real-secret' },
    'INVALID_CREDENTIALS',
  );
  await expectConnectError(
    'CONNECT against an unknown game session -> SESSION_NOT_FOUND',
    { gameSessionId: fakeGameSessionId, playerSessionId: 'nonexistent-player', playerSecret: 'x' },
    'SESSION_NOT_FOUND',
  );
  await expectConnectError(
    'CONNECT with a player id not in the session -> PLAYER_NOT_IN_SESSION',
    { gameSessionId: guest.gameSessionId, playerSessionId: 'nonexistent-player', playerSecret: 'x' },
    'PLAYER_NOT_IN_SESSION',
  );
  await expectConnectOk('guest CONNECT with the correct playerSecret still works (D1, auth is additive)', {
    gameSessionId: guest.gameSessionId,
    playerSessionId: guest.playerSessionId,
    playerSecret: guest.playerSecret,
  });

  // ---- CONNECT: authenticated-seat credential rows ----
  await expectConnectError(
    'authenticated seat CONNECT with no bearer -> AUTH_REQUIRED',
    { gameSessionId: authSeat.gameSessionId, playerSessionId: authSeat.playerSessionId },
    'AUTH_REQUIRED',
  );
  await expectConnectError(
    "identity mismatch: another user's JWT on this seat -> IDENTITY_MISMATCH",
    {
      gameSessionId: authSeat.gameSessionId,
      playerSessionId: authSeat.playerSessionId,
      Authorization: `Bearer ${mismatchToken}`,
    },
    'IDENTITY_MISMATCH',
  );
  await expectConnectError(
    'service token as a player -> INVALID_CREDENTIALS (a service identity can never be a player)',
    {
      gameSessionId: authSeat.gameSessionId,
      playerSessionId: authSeat.playerSessionId,
      Authorization: `Bearer ${serviceToken}`,
    },
    'INVALID_CREDENTIALS',
  );

  // ---- banned CONNECT (WP-D3's fourth named probe) ----
  // scripts/smoke-auth.sh bans this user via the admin API before invoking us.
  await expectConnectError(
    'banned CONNECT: a banned user cannot connect even with a valid, matching JWT -> BANNED',
    {
      gameSessionId: bannedSeat.gameSessionId,
      playerSessionId: bannedSeat.playerSessionId,
      Authorization: `Bearer ${bannedSeat.token}`,
    },
    'BANNED',
  );

  // ---- forged SEND (AUTH-01: clients must not be able to spoof server events) ----
  const authHeaders = {
    gameSessionId: authSeat.gameSessionId,
    playerSessionId: authSeat.playerSessionId,
    Authorization: `Bearer ${authSeat.token}`,
  };
  await expectActionError(
    'forged SEND: SEND straight to a broker queue (not /app/**) -> FORBIDDEN_DESTINATION',
    authHeaders,
    (p) =>
      p.send(
        `/queue/event/${authSeat.gameSessionId}`,
        { gameSessionId: authSeat.gameSessionId, playerSessionId: authSeat.playerSessionId },
        { messageContentType: 'MatchPacketUpdate', packetId: 'forged-by-a-client' },
      ),
    'FORBIDDEN_DESTINATION',
  );
  await expectActionError(
    "forged identity headers on SEND: gameSessionId header not the caller's own -> IDENTITY_MISMATCH",
    authHeaders,
    (p) =>
      p.send(
        '/app/game/config/get-game',
        { gameSessionId: otherGameSessionId, playerSessionId: authSeat.playerSessionId },
        {},
      ),
    'IDENTITY_MISMATCH',
  );

  // ---- cross-game SUBSCRIBE (AUTH-02: no reading another game's queues) ----
  await expectActionError(
    'cross-game SUBSCRIBE: another game\'s event queue -> FORBIDDEN_DESTINATION',
    authHeaders,
    (p) => p.subscribe(`/queue/event/${otherGameSessionId}`, () => {}),
    'FORBIDDEN_DESTINATION',
  );

  // ---- AUTH-18 end to end: game fetches the packet from questions with its own service token ----
  await serviceTokenPathE2e(
    'service-token path: SetMatchPacket succeeds and the game reports the fetched packet (AUTH-18)',
    authSeat,
    packetId,
  );

  console.log(`\n${passed} passed, ${failed} failed`);
  process.exit(failed > 0 ? 1 : 0);
}

main().catch((err) => {
  console.error('stomp-probe.mjs crashed:', err);
  process.exit(1);
});
