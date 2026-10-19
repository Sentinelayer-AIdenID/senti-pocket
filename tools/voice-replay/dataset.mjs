import { createHash } from 'node:crypto';

export const SCHEMA = 'voice-replay.dataset.v1';
const ID = /^[a-z][a-z0-9_-]{0,63}$/;
const SOURCE_ID = /^[A-Za-z0-9][A-Za-z0-9_.:-]{0,159}$/;
const HEX = /^[0-9a-f]{64}$/;
const RESERVED = new Set(['keep_listening', 'interrupt', '__proto__', 'prototype', 'constructor']);
const id = (value, pattern = ID) => typeof value === 'string' && pattern.test(value);
const text = (s, max) => typeof s === 'string' && s.trim().length > 0 && s.length <= max;
const integer = (v) => Number.isSafeInteger(v) && v >= 0;
const fail = () => { throw new Error('invalid_dataset'); };
export const bytesHash = (value) => createHash('sha256').update(value).digest('hex');

// Labels and complete future turns are never part of the router state.
export function validateDataset(input) {
  const data = structuredClone(input);
  if (data?.schema !== SCHEMA || !id(data.corpus_id) || !Array.isArray(data.sessions) ||
      !data.sessions.length || data.sessions.length > 128) fail();
  const sessionIds = new Set(), sources = new Set(), sourceKeys = new Set(), splitTexts = new Map();
  for (const session of data.sessions) {
    if (!id(session.session_id, SOURCE_ID) || sessionIds.has(session.session_id) ||
        !['development', 'holdout'].includes(session.split) || !['recorded', 'synthetic'].includes(session.source_kind) ||
        !HEX.test(session.source_sha256) || sources.has(session.source_sha256) ||
        !Array.isArray(session.agents) || session.agents.length < 2 || session.agents.length > 32 ||
        !Array.isArray(session.turns) || !session.turns.length || session.turns.length > 10000) fail();
    sessionIds.add(session.session_id); sources.add(session.source_sha256);
    const ids = new Set(), aliases = new Set();
    for (const agent of session.agents) {
      if (!id(agent.id) || RESERVED.has(agent.id) || ids.has(agent.id) ||
          !text(agent.role, 256) || !Array.isArray(agent.aliases) || !agent.aliases.length || agent.aliases.length > 8) fail();
      ids.add(agent.id);
      for (const alias of agent.aliases) {
        if (!text(alias, 80) || !/^[\p{L}\p{N}_-]+$/u.test(alias)) fail();
        const normalized = alias.toLocaleLowerCase('en-US');
        if (aliases.has(normalized)) fail();
        aliases.add(normalized);
      }
    }
    const turnIds = new Set(); let previousStart = -1;
    for (const turn of session.turns) {
      if (!id(turn.id, SOURCE_ID) || turnIds.has(turn.id) || !integer(turn.start_us) || turn.start_us < previousStart ||
          !text(turn.source_key, 200) || !text(turn.text, 8000) ||
          !Array.isArray(turn.context) || turn.context.length > 8 || !turn.label ||
          ![...ids, 'keep_listening', 'interrupt'].includes(turn.label.target) ||
          !['observed_first_reply', 'adjudicated'].includes(turn.label.basis)) fail();
      if (sourceKeys.has(turn.source_key)) fail();
      const turnHash = bytesHash(turn.text.normalize('NFKC').toLocaleLowerCase('en-US').replace(/\s+/g, ' ').trim());
      if (splitTexts.has(turnHash) && splitTexts.get(turnHash) !== session.split) fail();
      splitTexts.set(turnHash, session.split);
      sourceKeys.add(turn.source_key); turnIds.add(turn.id); previousStart = turn.start_us;
      let contextStart = -1;
      for (const context of turn.context) {
        if (!integer(context.utc_us) || context.utc_us >= turn.start_us || context.utc_us < contextStart ||
            !text(context.actor_id, 80) || !text(context.source_key, 200) || !text(context.text, 4000) ||
            context.source_key === turn.source_key || context.source_key === turn.label.reply_source_key) fail();
        contextStart = context.utc_us;
      }
      if (turn.label.basis === 'observed_first_reply' && !text(turn.label.reply_source_key, 200)) fail();
    }
  }
  return data;
}

/** Synthetic text timing only: Unicode codepoint chunks, final prefix included exactly once. */
export function partials(value, { charsPerPartial = 24, partialMs = 250 } = {}) {
  if (!text(value, 8000) || !Number.isInteger(charsPerPartial) || charsPerPartial < 1 || charsPerPartial > 8000 ||
      !Number.isInteger(partialMs) || partialMs < 1 || partialMs > 10000) fail();
  const points = [...value], result = [];
  for (let end = Math.min(charsPerPartial, points.length); ; end = Math.min(end + charsPerPartial, points.length)) {
    result.push({ prefix: points.slice(0, end).join(''), offset_ms: (result.length + 1) * partialMs, final: end === points.length });
    if (end === points.length) return result;
  }
}

/** Last fully bounded mention. Never invent an agent for a name fragment or ambiguous alias. */
export function lastNamed(prefix, agents) {
  let best = -1, choice = 'keep_listening';
  const lower = prefix.toLocaleLowerCase('en-US');
  for (const agent of agents) for (const alias of agent.aliases) {
    const escaped = alias.toLocaleLowerCase('en-US').replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    const pattern = new RegExp('(^|[^\\p{L}\\p{N}_-])(' + escaped + ')(?=$|[^\\p{L}\\p{N}_-])', 'gu');
    for (const match of lower.matchAll(pattern)) {
      const index = match.index + match[1].length;
      if (index > best) { best = index; choice = agent.id; }
      else if (index === best && choice !== agent.id) choice = 'keep_listening';
    }
  }
  return choice;
}

export function routerInput(session, turn, prefix) {
  return {
    state: {
      partial_text: prefix,
      prior_context: turn.context.map(({ actor_id, text: content }) => ({ actor_id, content })),
      available_agents: session.agents.map(({ id, aliases, role }) => ({ id, aliases, role })),
    },
    criteria: Object.fromEntries([
      ...session.agents.map(({ id, role }) => [id, 'Let this agent answer next. Role: ' + role]),
      ['keep_listening', 'The partial is incomplete, ambiguous, or no listed agent should speak yet.'],
      ['interrupt', 'Stop a current speaker only when an explicit urgent interruption is requested.'],
    ]),
  };
}
