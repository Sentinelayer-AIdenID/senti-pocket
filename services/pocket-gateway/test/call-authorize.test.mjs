// call-authorize.test.mjs — POST /call/authorize (live-call admission) through the real createGateway().handle(), plus
// the cross-boundary contract with the live-call Worker's own authorize() client.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createGateway } from '../src/handlers.mjs';
import {
  SentiTargetMembershipCredentialRejectedError,
  SentiTargetMembershipRateLimitedError,
  SentiTargetMembershipUnavailableError,
} from '../src/senti-target-membership.mjs';
import { authorize as workerAuthorize } from '../../../tools/live-call/worker.mjs';

const SESSION = 'session-target-1';
const AUTHORIZATION = 'Bearer pocket-token';
const identity = (scopes = ['sessions:read', 'sessions:write', 'pocket:voice', 'pocket:dial']) => Object.freeze({
  humanId: 'user-123',
  principal: 'pocket.principal.senti.v1\n8:user-123',
  scopes: Object.freeze(scopes),
});

function gatewayWith({ role = 'viewer', scopes, membership } = {}) {
  const calls = [];
  const gateway = createGateway({
    verifyToken: async (token) => (token ? identity(scopes) : null),
    getTargetMembership: async (input) => {
      calls.push(input);
      if (membership) return membership(input);
      return role === null ? null : Object.freeze({ sessionId: input.sessionId, membershipRole: role });
    },
  });
  return { gateway, calls };
}
const authorizeRequest = (body, headers = { authorization: AUTHORIZATION }) => ({ method: 'POST', path: '/call/authorize', headers, body });
const noStore = (response) => {
  assert.equal(response.headers['cache-control'], 'no-store');
  assert.equal(response.headers.pragma, 'no-cache');
};

test('a member is admitted as the authenticated human with its own role; membership is resolved once under its bearer', async () => {
  for (const role of ['viewer', 'contributor', 'admin', 'owner']) {
    const { gateway, calls } = gatewayWith({ role });
    const response = await gateway.handle(authorizeRequest({ sessionId: SESSION, roomId: 'standup' }));
    assert.equal(response.status, 200);
    assert.deepEqual(response.body, { sessionId: SESSION, roomId: 'standup', role, participantId: 'user-123' });
    assert.deepEqual(calls, [{ sessionId: SESSION, authorization: AUTHORIZATION }]);
    noStore(response);
  }
});

test('the participant id is never taken from the body', async () => {
  const { gateway } = gatewayWith({ role: 'owner' });
  const response = await gateway.handle(authorizeRequest({ sessionId: SESSION, roomId: 'standup', participantId: 'someone-else', role: 'owner' }));
  assert.equal(response.status, 200);
  assert.equal(response.body.participantId, 'user-123');
});

test('a non-member is refused, and nothing about the session leaks into a cacheable response', async () => {
  const { gateway } = gatewayWith({ role: null });
  const response = await gateway.handle(authorizeRequest({ sessionId: SESSION, roomId: 'standup' }));
  assert.equal(response.status, 403);
  assert.equal(response.body.participantId, undefined);
  noStore(response);
});

test('without the pocket:voice scope the call is refused before any membership lookup', async () => {
  const { gateway, calls } = gatewayWith({ scopes: ['sessions:read', 'sessions:write', 'pocket:dial'] });
  const response = await gateway.handle(authorizeRequest({ sessionId: SESSION, roomId: 'standup' }));
  assert.equal(response.status, 403);
  assert.equal(calls.length, 0);
});

test('malformed admission requests are refused before any membership lookup', async () => {
  for (const body of [
    'not-json', [], { roomId: 'standup' }, { sessionId: '', roomId: 'standup' }, { sessionId: SESSION },
    { sessionId: SESSION, roomId: '' }, { sessionId: SESSION, roomId: '../other' }, { sessionId: SESSION, roomId: 'a b' },
    { sessionId: SESSION, roomId: 'x'.repeat(65) }, { sessionId: SESSION, roomId: 7 },
  ]) {
    const { gateway, calls } = gatewayWith();
    const response = await gateway.handle(authorizeRequest(body));
    assert.equal(response.status, 400, JSON.stringify(body));
    assert.equal(calls.length, 0);
    noStore(response);
  }
});

test('no bearer is unauthenticated', async () => {
  const { gateway, calls } = gatewayWith();
  const response = await gateway.handle(authorizeRequest({ sessionId: SESSION, roomId: 'standup' }, {}));
  assert.equal(response.status, 401);
  assert.equal(calls.length, 0);
});

test('membership lookup failures stay fail-closed and uncacheable', async () => {
  for (const [error, status] of [
    [new SentiTargetMembershipCredentialRejectedError(), 401],
    [new SentiTargetMembershipRateLimitedError(9), 429],
    [new SentiTargetMembershipUnavailableError(), 503],
  ]) {
    const { gateway } = gatewayWith({ membership: async () => { throw error; } });
    const response = await gateway.handle(authorizeRequest({ sessionId: SESSION, roomId: 'standup' }));
    assert.equal(response.status, status);
    noStore(response);
  }
});

// The live-call Worker is the only caller. Drive ITS authorize() client against this handler, so a change on either
// side of the seam (request body, echoed fields, role names, status handling) fails here instead of in a live call.
function workerEnvFor(gateway) {
  const fetchToGateway = async (url, options) => {
    assert.equal(url, 'https://pocket-api.example/call/authorize');
    assert.equal(options.redirect, 'manual');
    const response = await gateway.handle({
      method: options.method, path: new URL(url).pathname,
      headers: { authorization: options.headers.authorization }, body: options.body,
    });
    return { ok: response.status >= 200 && response.status < 300, status: response.status, json: async () => response.body };
  };
  return { env: { GATEWAY_AUTHORIZE_URL: 'https://pocket-api.example/call/authorize', GATEWAY_HOST: 'pocket-api.example' }, fetchToGateway };
}
async function viaWorker(gateway, input) {
  const { env, fetchToGateway } = workerEnvFor(gateway);
  const saved = globalThis.fetch;
  globalThis.fetch = fetchToGateway;
  try { return await workerAuthorize(env, input); } finally { globalThis.fetch = saved; }
}

test('contract: the live-call Worker admits a member as the gateway-bound participant and refuses a non-member', async () => {
  const member = gatewayWith({ role: 'contributor' });
  assert.deepEqual(await viaWorker(member.gateway, { authorization: AUTHORIZATION, sessionId: SESSION, roomId: 'standup' }),
    { ok: true, participantId: 'user-123', role: 'contributor' });
  const stranger = gatewayWith({ role: null });
  assert.deepEqual(await viaWorker(stranger.gateway, { authorization: AUTHORIZATION, sessionId: SESSION, roomId: 'standup' }), { ok: false });
  const unscoped = gatewayWith({ scopes: ['sessions:read'] });
  assert.deepEqual(await viaWorker(unscoped.gateway, { authorization: AUTHORIZATION, sessionId: SESSION, roomId: 'standup' }), { ok: false });
});
