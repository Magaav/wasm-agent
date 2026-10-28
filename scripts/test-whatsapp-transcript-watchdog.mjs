// The watchdog's judgement, without a journal: which snapshots are problems, and which are not.
import test from 'node:test';
import assert from 'node:assert/strict';
import { findProblems, LIMITS } from './whatsapp-transcript-watchdog.mjs';
const at = 1_800_000_000;
const quiet = { config: { requested_on: true }, lastConnected: at - 10, lastDisconnected: at - 100, pending: [], held: ['a@g.us'], unposted: [] };

test('a healthy connector reports nothing', () => {
  assert.deepEqual(findProblems(quiet, ['a@g.us'], at), []);
});
test('a long disconnection is reported, a short one is not', () => {
  assert.equal(findProblems({ ...quiet, lastConnected: at - 5000, lastDisconnected: at - LIMITS.disconnectedSeconds - 60 }, ['a@g.us'], at).length, 1);
  assert.equal(findProblems({ ...quiet, lastConnected: at - 300, lastDisconnected: at - 60 }, ['a@g.us'], at).length, 0);
});
test('an audio stuck by attempts or by age is reported once per id', () => {
  const stuck = { ...quiet, pending: [{ id: 'X', chat: 'c', attempts: 20, reason: 'worker_timeout', sent: at - 600 }, { id: 'Y', chat: 'c', attempts: 1, sent: at - 60 }] };
  const problems = findProblems(stuck, ['a@g.us'], at);
  assert.deepEqual(problems.map((p) => p.key), ['pending:X']);
  assert.match(problems[0].line, /20 tentativas/);
});
test('new holds are reported against the previous run, never on the first run', () => {
  const more = { ...quiet, held: ['a@g.us', 'b@g.us'] };
  assert.equal(findProblems(more, null, at).length, 0, 'first run is the baseline');
  const problems = findProblems(more, ['a@g.us'], at);
  assert.equal(problems.length, 1);
  assert.match(problems[0].line, /1 conversa\(s\).*b@g\.us.*Total em hold: 2/);
});
test('a transcript not posted in a free chat is reported after the limit', () => {
  const late = { ...quiet, unposted: [{ id: 'Z', chat: 'd', sent: at - LIMITS.unpostedSeconds - 1 }] };
  assert.equal(findProblems(late, ['a@g.us'], at)[0].key, 'unposted:Z');
});
test('a connector switched off on purpose is not a problem', () => {
  assert.deepEqual(findProblems({ ...quiet, config: { requested_on: false }, lastDisconnected: at - 99999 }, ['a@g.us'], at), []);
});
