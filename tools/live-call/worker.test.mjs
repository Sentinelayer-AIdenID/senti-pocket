import test from 'node:test';
import assert from 'node:assert/strict';

globalThis.Response = class { constructor(body, init = {}) { this.body = body; this.status = init.status ?? 200; this.webSocket = init.webSocket; } };

const worker = await import('./worker.mjs');
const { authorizeEndpoint, authorize, buildForwardUrl } = worker;

function mkReq(url, { upgrade = false, auth = null } = {}) {
  const h = new Map();
  if (upgrade) h.set('upgrade', 'websocket');
  if (auth) h.set('authorization', auth);
  return { url, method: 'GET', headers: { get: (k) => (h.has(k.toLowerCase()) ? h.get(k.toLowerCase()) : null) } };
}

test('authorizeEndpoint pins https + host', () => {
  assert.equal(authorizeEndpoint({ GATEWAY_AUTHORIZE_URL: 'https://gw.example/authorize', GATEWAY_HOST: 'gw.example' }), 'https://gw.example/authorize');
  assert.equal(authorizeEndpoint({ GATEWAY_AUTHORIZE_URL: 'http://gw.example/authorize' }), null); // not https
  assert.equal(authorizeEndpoint({ GATEWAY_AUTHORIZE_URL: 'https://evil.example/x', GATEWAY_HOST: 'gw.example' }), null); // host mismatch
  assert.equal(authorizeEndpoint({}), null);
});

test('buildForwardUrl strips the bearer token and binds the AUTHORIZED participant + role', () => {
  const out = buildForwardUrl('https://w/call/R/ws?session=S&token=secret&participant=iamroot&role=owner', {
    roomId: 'R', participantId: 'alice', role: 'viewer',
  });
  const u = new URL(out);
  assert.equal(u.searchParams.get('token'), null); // stripped — removing the delete makes this fail
  assert.equal(u.searchParams.get('participant'), 'alice'); // authorized, not the caller's 'iamroot'
  assert.equal(u.searchParams.get('role'), 'viewer');
  assert.equal(u.searchParams.get('room'), 'R');
});

test('authorize fails closed with no endpoint (and never calls fetch)', async () => {
  let called = false;
  const saved = globalThis.fetch;
  globalThis.fetch = async () => { called = true; return { ok: true, json: async () => ({}) }; };
  try {
    const r = await authorize({}, { authorization: 'Bearer t', sessionId: 'S', roomId: 'R' });
    assert.equal(r.ok, false);
    assert.equal(called, false);
  } finally { globalThis.fetch = saved; }
});

test('authorize returns the gateway-bound principal + role for a member, and rejects a non-member role', async () => {
  const env = { GATEWAY_AUTHORIZE_URL: 'https://gw.example/authorize', GATEWAY_HOST: 'gw.example' };
  const saved = globalThis.fetch;
  try {
    globalThis.fetch = async () => ({ ok: true, json: async () => ({ sessionId: 'S', roomId: 'R', role: 'admin', participantId: 'p1' }) });
    assert.deepEqual(await authorize(env, { authorization: 'Bearer t', sessionId: 'S', roomId: 'R' }), { ok: true, participantId: 'p1', role: 'admin' });

    globalThis.fetch = async () => ({ ok: true, json: async () => ({ sessionId: 'S', roomId: 'R', role: 'stranger', participantId: 'p1' }) });
    assert.equal((await authorize(env, { authorization: 'Bearer t', sessionId: 'S', roomId: 'R' })).ok, false); // bad role
  } finally { globalThis.fetch = saved; }
});

test('authorize rejects a mismatched (session, room) echo (confused-deputy)', async () => {
  const env = { GATEWAY_AUTHORIZE_URL: 'https://gw.example/authorize', GATEWAY_HOST: 'gw.example' };
  const saved = globalThis.fetch;
  try {
    globalThis.fetch = async () => ({ ok: true, json: async () => ({ sessionId: 'OTHER', roomId: 'R', role: 'owner', participantId: 'p1' }) });
    assert.equal((await authorize(env, { authorization: 'Bearer t', sessionId: 'S', roomId: 'R' })).ok, false);
  } finally { globalThis.fetch = saved; }
});

test('default fetch: /health is open; an unauthorized call route is 403', async () => {
  const health = await worker.default.fetch(mkReq('https://w/health'), {});
  assert.equal(health.status, 200);
  assert.equal(JSON.parse(health.body).ok, true);

  // No GATEWAY_AUTHORIZE_URL configured -> fail closed.
  const forbidden = await worker.default.fetch(mkReq('https://w/call/R/ws?session=S', { upgrade: true, auth: 'Bearer t' }), {});
  assert.equal(forbidden.status, 403);
});
