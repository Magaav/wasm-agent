#!/usr/bin/env node
// Automatic-transcript watchdog: the transcript pipeline must never degrade silently.
//
// On 28/10 posting had stopped in 38 chats (unproven_mutation_chat_hold) and a long voice note had timed out
// 20 times, and nothing told anyone. This job reads the connector's journal (read-only) every few minutes and,
// when something is wrong, sends ONE message to the account owner's own chat through the operator-directed
// path (docs/WHATSAPP-OPERATOR-MANAGEMENT.md: prepare -> approve -> send, the `self` operator profile). Each
// problem is reported at most once per day; a problem that clears is forgotten, so a recurrence is reported.
//
// Settings (environment, all optional):
//   WA_WHATSAPP_STATE       connector state dir      (default ~/.local/state/wa-whatsapp)
//   WA_WHATSAPP_OPERATOR_DIR operator configs dir     (default ~/.config/wa-whatsapp)
//   WA_WATCHDOG_PROFILE     operator profile to send with (default: the one whose only chat is the account itself)
//   WA_WATCHDOG_DRY_RUN=1   report on stdout, send nothing
import { DatabaseSync } from 'node:sqlite';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const home = os.homedir();
const stateDir = process.env.WA_WHATSAPP_STATE || path.join(home, '.local/state/wa-whatsapp');
const operatorDir = process.env.WA_WHATSAPP_OPERATOR_DIR || path.join(home, '.config/wa-whatsapp');
const memoryFile = path.join(stateDir, 'transcript-watchdog.json');
const now = Math.floor(Date.now() / 1000);
const DAY = 86400;

export const LIMITS = { disconnectedSeconds: 900, pendingAttempts: 5, pendingSeconds: 3600, unpostedSeconds: 1800 };

// Pure: the problems in a journal snapshot, each with a stable key and one Portuguese line.
export function findProblems(snapshot, previousHeld, at = now) {
  const problems = [];
  const { lastConnected, lastDisconnected, pending, held, unposted, config } = snapshot;
  if (config && config.requested_on === false) return problems; // switched off on purpose
  if (lastDisconnected && (!lastConnected || lastDisconnected > lastConnected) && at - lastDisconnected > LIMITS.disconnectedSeconds) {
    problems.push({ key: `disconnected:${lastDisconnected}`, line: `Conector desconectado do WhatsApp há ${Math.round((at - lastDisconnected) / 60)} min.` });
  }
  for (const audio of pending) {
    if (audio.attempts >= LIMITS.pendingAttempts || (audio.sent && at - audio.sent > LIMITS.pendingSeconds)) {
      problems.push({ key: `pending:${audio.id}`, line: `Áudio preso sem transcrição em ${audio.chat}: ${audio.attempts} tentativas (${audio.reason || 'sem motivo'}), há ${Math.round((at - (audio.sent || at)) / 60)} min.` });
    }
  }
  const before = new Set(previousHeld || []);
  const added = held.filter((chat) => !before.has(chat));
  if (previousHeld && added.length) {
    problems.push({ key: `held:${added.sort().join(',')}`, line: `${added.length} conversa(s) entraram em hold de postagem (mensagem apagada sem autor provado): ${added.slice(0, 5).join(', ')}${added.length > 5 ? '…' : ''}. Total em hold: ${held.length}.` });
  }
  for (const audio of unposted) {
    if (audio.sent && at - audio.sent > LIMITS.unpostedSeconds) {
      problems.push({ key: `unposted:${audio.id}`, line: `Transcrição pronta e não postada há ${Math.round((at - audio.sent) / 60)} min em ${audio.chat} (conversa sem hold).` });
    }
  }
  return problems;
}

function snapshot() {
  const db = new DatabaseSync(path.join(stateDir, 'journal.db'), { readOnly: true });
  const one = (sql, ...args) => db.prepare(sql).get(...args);
  const all = (sql, ...args) => db.prepare(sql).all(...args);
  const config = JSON.parse((one('SELECT value FROM config LIMIT 1') || {}).value || '{}');
  const at = (kind) => (one('SELECT max(at) AS at FROM events WHERE kind=?', kind) || {}).at || 0;
  const held = all('SELECT chat FROM chat_holds').map((row) => row.chat);
  const heldSet = new Set(held);
  const pending = all(`SELECT a.id, a.chat, a.attempts, a.reason, m.sent FROM audio a JOIN messages m USING(account,generation,chat,id)
    WHERE a.state='pending'`);
  const unposted = config.transcript_posting ? all(`SELECT a.id, a.chat, m.sent FROM audio a JOIN messages m USING(account,generation,chat,id)
    WHERE a.state='transcribed' AND coalesce(a.reason,'')='' AND m.sent >= ?
      AND NOT EXISTS (SELECT 1 FROM outbox o WHERE o.account=a.account AND o.generation=a.generation AND o.chat=a.chat AND o.source=a.id)`,
    Number(config.activated_at || 0)).filter((row) => !heldSet.has(row.chat)) : [];
  db.close();
  return { config, lastConnected: at('connected'), lastDisconnected: at('disconnected'), pending, held, unposted };
}

// The operator profile that writes only to the account's own chat.
function selfProfile(account) {
  if (process.env.WA_WATCHDOG_PROFILE) return path.join(operatorDir, `operator-management-${process.env.WA_WATCHDOG_PROFILE}.json`);
  for (const name of fs.readdirSync(operatorDir)) {
    if (!/^operator-management-.*\.json$/.test(name)) continue;
    const config = JSON.parse(fs.readFileSync(path.join(operatorDir, name), 'utf8'));
    if (Array.isArray(config.conversations) && config.conversations.length === 1 && config.conversations[0] === account) {
      return path.join(operatorDir, name);
    }
  }
  return null;
}

function operator(action, profile, request) {
  const file = path.join(operatorDir, 'requests', `watchdog-${action}-${process.pid}-${Date.now()}.json`);
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  fs.writeFileSync(file, JSON.stringify(request), { mode: 0o600 });
  const script = path.join(path.dirname(new URL(import.meta.url).pathname), 'whatsapp-operator.mjs');
  const out = execFileSync(process.execPath, [script, action, '--authority-file', profile, '--request-file', file], { encoding: 'utf8', timeout: 60000 });
  return JSON.parse(out);
}

function send(account, text) {
  const profile = selfProfile(account);
  if (!profile) throw Error('watchdog_self_profile_missing: no operator profile scoped to the account itself');
  const prepared = operator('prepare', profile, { conversation_id: account, body: text });
  const intent = prepared.intent || {};
  if (!intent.intent_id || !intent.approval_digest) throw Error('watchdog_prepare_without_intent');
  operator('approve', profile, { conversation_id: account, body: intent.body, intent_id: intent.intent_id, approval_digest: intent.approval_digest });
  const sent = operator('send', profile, { conversation_id: account, intent_id: intent.intent_id });
  return { intent_id: intent.intent_id, state: (sent.intent || {}).state };
}

export function main() {
  const memory = fs.existsSync(memoryFile) ? JSON.parse(fs.readFileSync(memoryFile, 'utf8')) : { reported: {}, held: null };
  const snap = snapshot();
  const problems = findProblems(snap, memory.held);
  const fresh = problems.filter((problem) => !memory.reported[problem.key] || now - memory.reported[problem.key] > DAY);
  let delivery = null;
  if (fresh.length && process.env.WA_WATCHDOG_DRY_RUN !== '1') {
    const text = ['Vigia das transcrições automáticas: algo precisa de atenção', '', ...fresh.map((p) => `• ${p.line}`)].join('\n');
    delivery = send(snap.config.account, text);
  }
  // Forget what cleared (so a recurrence is reported again); remember what was just reported.
  const current = new Set(problems.map((p) => p.key));
  const reported = Object.fromEntries(Object.entries(memory.reported).filter(([key]) => current.has(key)));
  if (delivery || process.env.WA_WATCHDOG_DRY_RUN === '1') for (const p of fresh) reported[p.key] = now;
  fs.writeFileSync(memoryFile, JSON.stringify({ reported, held: snap.held, at: now }), { mode: 0o600 });
  const result = { ok: true, problems: problems.length, reported: delivery ? fresh.length : 0, held: snap.held.length, pending: snap.pending.length, delivery };
  console.log(JSON.stringify(result));
  return result;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  try { main(); } catch (error) { console.log(JSON.stringify({ ok: false, error: String(error.message || error) })); process.exitCode = 1; }
}
