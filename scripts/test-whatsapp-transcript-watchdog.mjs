// The watchdog's judgement, without a journal: which snapshots are problems, and which are not.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
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

// Delivery since 14/11: a file and a failing run, never a WhatsApp message. The second send path
// (`whatsapp_operator`) is retired, and the one surface has no door for a job - so an alert that wrote
// nothing, or that claimed to have sent something, would be the silent success AGENTS.md forbids.
test('an alert is written and reported as undelivered, with the one sentence', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'watchdog-alert-'));
  process.env.WA_WHATSAPP_STATE = dir;
  const mod = await import(`./whatsapp-transcript-watchdog.mjs?alert=${path.basename(dir)}`);
  const delivery = mod.deliver('5511999999999@s.whatsapp.net', 'alert text', [{ key: 'pending:X' }], 1_800_000_000);
  assert.equal(delivery.ok, false);
  assert.equal(delivery.error, 'alert_not_delivered_to_whatsapp');
  assert.equal(delivery.note, 'retired: use mcp_whatsapp_send; turn on /approve to review drafts first');
  assert.equal(delivery.where, path.join(dir, 'transcript-watchdog-alert.json'));
  const written = JSON.parse(fs.readFileSync(delivery.where, 'utf8'));
  assert.deepEqual(written.problems, ['pending:X']);
  assert.equal(written.account, '5511999999999@s.whatsapp.net');
  assert.match(written.text, /alert text/);
  assert.equal(written.at, 1_800_000_000);
  fs.rmSync(dir, { recursive: true, force: true });
});
