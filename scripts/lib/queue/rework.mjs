#!/usr/bin/env node
// A REJECTED LANDING GOES BACK TO ITS WORKER AS REWORK: machine-readable, enough to act on, and delivered
// the one way this factory already delivers a message to a session.
//
// THE PAYLOAD is the verdict's own `payload`: cause, branch, sha, files, rows (name + last line), and the
// one sentence a worker needs (`submit_again`). It is written as a FILE in the mission directory, because
// that is where a session already looks (v0 did this and it worked: `_orch/q-runner.sh` wrote
// `rework-q<id>.txt` beside the mission).
//
// THE ESCALATION is v0's own rule kept intact: three rejections for one mission is a person's problem, and
// the third writes ONE line into `_orch/ATTENTION` - the file the orchestrator already watches.
import fs from 'node:fs';
import path from 'node:path';

export const REVIEW_AGAIN = 'Fix it on your branch, then put READY <new sha> on line 1 of your ready file; the orchestrator resubmits it.';

export function renderRework({id, payload, mission}) {
  const p = payload || {};
  const lines = [
    `[landing queue, request #${id}] REJECTED: ${p.cause || 'other'}`,
    `mission ${mission || '-'} | branch ${p.branch || '-'} at ${p.sha || '-'}`,
  ];
  if (Array.isArray(p.files) && p.files.length) lines.push(`files: ${p.files.join(' ')}`);
  if (p.rows) lines.push(`rows: ${p.rows}`);
  if (p.detail) {
    lines.push('last lines:');
    for (const line of String(p.detail).split('\n').slice(-8)) lines.push(`  ${line}`);
  }
  lines.push(REVIEW_AGAIN);
  return `${lines.join('\n')}\n`;
}

/// Where a rejection lands on disk. One name, so the runner and a session agree.
export function reworkPath({missionsDir, mission, id}) {
  return path.join(missionsDir, mission || '_orphan', `rework-q${id}.txt`);
}

export function writeRework({missionsDir, mission, id, payload, fsImpl = fs}) {
  const file = reworkPath({missionsDir, mission, id});
  const dir = path.dirname(file);
  if (!fsImpl.existsSync(dir)) return {written: false, file, why: `mission directory ${dir} is not there`};
  fsImpl.writeFileSync(file, renderRework({id, payload, mission}));
  return {written: true, file};
}

/// v0's rule, unchanged: the THIRD rejection for a mission is the orchestrator's, and it says which request
/// caused it. The count is the journal's (verdicts with cause, per mission), not a counter in a file.
export function escalate({missionsDir, mission, id, cause, count, threshold = 3, fsImpl = fs}) {
  if (count < threshold) return {escalated: false, count};
  const line = `${new Date().toISOString().replace(/\.\d+Z$/, 'Z')} QUEUE: ${mission} has ${count} rejections (latest q#${id} ${cause}) -> the orchestrator\n`;
  fsImpl.appendFileSync(path.join(missionsDir, '_orch', 'ATTENTION'), line);
  return {escalated: true, count, line: line.trim()};
}
