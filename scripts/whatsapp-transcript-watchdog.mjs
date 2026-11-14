#!/usr/bin/env node
// Automatic-transcript watchdog: the transcript pipeline must never degrade silently.
//
// On 28/10 posting had stopped in 38 chats (unproven_mutation_chat_hold) and a long voice note had timed out
// 20 times, and nothing told anyone. This job reads the connector's journal (read-only) every few minutes and
// reports what is wrong; each problem is reported at most once per day, and a problem that clears is
// forgotten, so a recurrence is reported again.
//
// DELIVERY, since 14/11: the alert is WRITTEN and never sent from here. It used to message the account
// owner's own chat through the operator route (prepare -> approve -> send, docs/WHATSAPP-OPERATOR-MANAGEMENT.md),
// whose transport was the Go connector's `/operator/*` HTTP API - removed 11/11, so the send could only
// fail. That route is retired: WhatsApp has ONE send surface, `mcp_whatsapp_send`, with the operator's
// `/approve` gate in front of it, and an unattended job has no door to it (a send is the node's Lua
// capability, not a shell command). Reaching around the gate is what the retirement removed, so the alert
// goes to a durable file, to stdout, and out as a non-zero exit - which is what makes a job's failure
// visible in the node's own history. Nothing is silent and nothing leaves the machine.
//
// Settings (environment, all optional):
//   WA_WHATSAPP_STATE       connector state dir      (default ~/.local/state/wa-whatsapp)
//   WA_WATCHDOG_DRY_RUN=1   report on stdout, write no alert and remember nothing
import { DatabaseSync } from 'node:sqlite';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const home = os.homedir();
const stateDir = process.env.WA_WHATSAPP_STATE || path.join(home, '.local/state/wa-whatsapp');
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
  const lastConnected = at('connected'), lastDisconnected = at('disconnected');
  db.close();
  return { config, lastConnected, lastDisconnected, pending, held, unposted };
}

// The alert's own file. One path, fixed, beside the watchdog's memory: an operator or a model can read
// the current alert without a WhatsApp message having been sent, and a dry run writes nothing.
export const alertFile = path.join(stateDir, 'transcript-watchdog-alert.json');

// Report, never send: the one WhatsApp surface is behind the operator's `/approve` gate and has no door
// for a job. The answer says so in the same words the retired name answers with, so a reader who finds
// this file is told where a message would come from now.
export function deliver(account, text, problems, at = now) {
  fs.writeFileSync(alertFile, JSON.stringify({ at, account, text, problems: problems.map((p) => p.key) }, null, 1), { mode: 0o600 });
  return { ok: false, error: 'alert_not_delivered_to_whatsapp', where: alertFile,
    note: 'retired: use mcp_whatsapp_send; turn on /approve to review drafts first' };
}

export function main() {
  const memory = fs.existsSync(memoryFile) ? JSON.parse(fs.readFileSync(memoryFile, 'utf8')) : { reported: {}, held: null };
  const snap = snapshot();
  const problems = findProblems(snap, memory.held);
  const fresh = problems.filter((problem) => !memory.reported[problem.key] || now - memory.reported[problem.key] > DAY);
  let delivery = null;
  if (fresh.length && process.env.WA_WATCHDOG_DRY_RUN !== '1') {
    const text = ['Vigia das transcrições automáticas: algo precisa de atenção', '', ...fresh.map((p) => `• ${p.line}`)].join('\n');
    delivery = deliver(snap.config.account, text, fresh);
  }
  // Forget what cleared (so a recurrence is reported again); remember what was DELIVERED, and only that:
  // an alert nobody received must not mute the next run.
  const current = new Set(problems.map((p) => p.key));
  const reported = Object.fromEntries(Object.entries(memory.reported).filter(([key]) => current.has(key)));
  if (delivery && delivery.ok) for (const p of fresh) reported[p.key] = now;
  // A dry run reports and remembers nothing, so it never mutes the first real alert.
  if (process.env.WA_WATCHDOG_DRY_RUN !== '1') fs.writeFileSync(memoryFile, JSON.stringify({ reported, held: snap.held, at: now }), { mode: 0o600 });
  // An undelivered alert is a failing run, with its lines in the evidence: the alternative is a green job
  // that told nobody (`AGENTS.md`: no silent success).
  const undelivered = delivery !== null && delivery.ok === false;
  const result = { ok: !undelivered, problems: problems.length, reported: delivery && delivery.ok ? fresh.length : 0,
    held: snap.held.length, pending: snap.pending.length, delivery,
    lines: process.env.WA_WATCHDOG_DRY_RUN === '1' || undelivered ? fresh.map((p) => p.line) : undefined };
  console.log(JSON.stringify(result));
  if (undelivered) process.exitCode = 1;
  return result;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  try { main(); } catch (error) { console.log(JSON.stringify({ ok: false, error: String(error.message || error) })); process.exitCode = 1; }
}
