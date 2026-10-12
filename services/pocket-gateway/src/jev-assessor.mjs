// services/pocket-gateway/src/jev-assessor.mjs
//
// Live TypeSafe "Jev" assessor adapter for the opt-in assessed-reasoning seam (assessed-reasoning.mjs).
// It IS the `assess` dependency: given a bound (context, candidate), it asks Jev — one narrow Noul per
// segment — whether that segment is fully supported by ONLY the evidence it cites, and returns one
// verdict per segment. Jev returns typed probabilities, not generated text.
//
// Wire contract (TypeSafe System One, docs.typesafe.ai/api): POST https://api.typesafe.ai/v1/systemone,
//   Authorization: Bearer <key>; body { state, model, questions:{<id>:{type:'noul',instructions,criteria}} };
//   response { model, answers:{<id>:{type:'noul', noul:0..1}}, usage }. `noul` = P(condition holds).
//
// Seam contract (must match assessed-reasoning.mjs checkVerdict):
//   assess({ context, candidate, contextHash, candidateHash, signal }) ->
//     { contextHash, candidateHash, verdicts: [{ index, support, supportScore }] }  // exactly one per segment
//   support ∈ 'supported' | 'unsupported' | 'inconclusive'; supportScore ∈ [0,1].
//
// Discipline:
//  - The TypeSafe key stays SERVER-SIDE (env TYPESAFE_API_KEY), never in a box/room/.env/commit.
//  - Model pinned to jev-1.13.0 (Carter directive), never jev-latest.
//  - `noul` is an uncalibrated probability; it is returned as supportScore and NEVER rewritten to 1.0.
//    The seam independently enforces minSupportScore and required-citation coverage.
//  - Fail-closed: no key / HTTP error / missing answer -> throw or 'inconclusive', never a silent pass.
//  - No network in tests: inject `fetchImpl`. AbortSignal is honored.

const ENDPOINT = 'https://api.typesafe.ai/v1/systemone';
const DEFAULT_MODEL = 'jev-1.13.0';

const clamp01 = (n) => (Number.isFinite(n) ? Math.min(1, Math.max(0, n)) : null);

export function createTypeSafeJevAssessor({
  apiKey = process.env.TYPESAFE_API_KEY,
  model = DEFAULT_MODEL,
  endpoint = ENDPOINT,
  fetchImpl = globalThis.fetch,
  supportedAt = 0.8, // noul >= this -> 'supported' (align with the seam's minSupportScore)
  unsupportedAt = 0.2, // noul <= this -> 'unsupported'; strictly between -> 'inconclusive'
} = {}) {
  if (typeof fetchImpl !== 'function') throw new Error('jev-assessor requires a fetch implementation');
  if (!(supportedAt > unsupportedAt) || supportedAt > 1 || unsupportedAt < 0) throw new Error('invalid-thresholds');

  return async function assess({ context, candidate, contextHash, candidateHash, signal }) {
    if (!apiKey) throw new Error('missing-typesafe-api-key'); // fail closed -> seam marks 'unavailable'
    if (!Array.isArray(candidate) || !candidate.length) throw new Error('empty-candidate');

    const evidenceById = new Map((context?.evidence || []).map((e) => [e.id, e]));
    // Shared immutable state: the same bounded excerpts Gemma drafted from.
    const state = {
      evidence: (context?.evidence || []).map((e) => ({ id: e.id, agent: e.agentId, seq: e.sequence, excerpt: e.snippet })),
      statements: candidate.map((s, i) => ({ index: i, text: s.text, citedEvidenceIds: s.evidenceIds })),
    };

    // One narrow Noul per segment, asked together over the shared state (parallel, independent).
    const questions = {};
    candidate.forEach((s, i) => {
      const cited = s.evidenceIds.filter((id) => evidenceById.has(id));
      questions[`seg${i}`] = {
        type: 'noul',
        instructions: {
          task: 'Decide whether the statement is fully supported by ONLY the evidence excerpts it cites.',
          statementIndex: i,
          statement: s.text,
          citedEvidenceIds: cited,
          rule: 'A statement that asserts anything beyond its cited excerpts, or that contradicts them, is NOT supported. A citation that merely reports that an agent said or claimed something does not establish that the thing is true.',
        },
        criteria: {
          true: 'Every claim in the statement is directly backed by the cited excerpts.',
          false: 'The statement adds claims beyond, misreads, or contradicts its cited excerpts.',
        },
      };
    });

    const res = await fetchImpl(endpoint, {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: `Bearer ${apiKey}` },
      body: JSON.stringify({ state, model, questions }),
      signal,
    });
    if (!res || !res.ok) throw new Error(`jev-http-${res ? res.status : 'no-response'}`);
    const data = await res.json();
    const answers = (data && data.answers) || {};

    const verdicts = candidate.map((_s, i) => {
      const a = answers[`seg${i}`];
      const noul = clamp01(a && a.type === 'noul' ? a.noul : NaN);
      if (noul === null) return { index: i, support: 'inconclusive', supportScore: 0 }; // missing/invalid -> seam rejects
      const support = noul >= supportedAt ? 'supported' : noul <= unsupportedAt ? 'unsupported' : 'inconclusive';
      return { index: i, support, supportScore: noul };
    });

    return { contextHash, candidateHash, verdicts };
  };
}
