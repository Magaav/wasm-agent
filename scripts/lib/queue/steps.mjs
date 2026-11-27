#!/usr/bin/env node
// The four steps a landing is made of, each calling the mechanics that already exist.
//
// WHAT THIS FILE IS NOT: a second landing script. `~/Work/missions/land-quick.sh` already merges, regenerates,
// runs a branch's own rows and pushes last, and `land-one2.sh` already parks a compiled branch and times the
// phases. This module is the ADAPTER: it runs them, hands back a machine-readable result, and names every
// wait's cap (law 15) so the runner can turn a timeout into a verdict instead of a hang.
//
// Each step returns {ok, cause, detail} - cause is one of the queue's own words (conflict, own_rows_red,
// policy_refused, stale_sha, other), never prose, so a rejection is actionable without reading a log.
import {execFile} from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

// The caps. They are the v0 queue's own measured bounds (a compiled landing today is 279-492 s end to end),
// and every one of them turns into `rejected` with the cap named - a wait with no end is the failure law 15
// describes, and the one this file exists not to reproduce.
export const CAPS = {merge: 120_000, rows: 1_800_000, push: 120_000};

function run(cmd, args, {timeoutMs, env = {}} = {}) {
  return new Promise((resolve) => {
    const child = execFile(cmd, args, {timeout: timeoutMs, env: {...process.env, ...env}, maxBuffer: 8 * 1024 * 1024},
      (error, stdout, stderr) => {
        const timedOut = Boolean(error && error.killed);
        resolve({code: error ? (error.code ?? 1) : 0, stdout: stdout ?? '', stderr: stderr ?? '', timedOut});
      });
    child.on('error', () => resolve({code: 1, stdout: '', stderr: 'spawn failed', timedOut: false}));
  });
}


/// THE SHA THAT WAS READ IS THE SHA THAT LANDS (Fable 27/11, and v0 hit it today: serve branch was
/// rewritten between the tip check and the merge, so the lander merged bytes nobody submitted).
///
/// `land-quick.sh` takes a branch NAME. This function pins the request sha at a ref of its own and hands the
/// lander THAT ref - so a branch that moves after submit either lands the sha the queue read, or the lander
/// refuses (its own tip check fails) and the request is rejected stale_sha. Never the moved tip.
export function pinRefName({id, branch}) { return `change/q${id}-${String(branch || "branch").split("/").pop()}`; }

export async function pinRequest({repo, request}) {
  const ref = pinRefName({id: request.id, branch: request.branch});
  const out = await run("git", ["-C", repo, "update-ref", `refs/heads/${ref}`, request.sha], {timeoutMs: CAPS.merge});
  if (out.code !== 0) return {ok: false, ref, why: (out.stderr || out.stdout || "update-ref failed").trim()};
  const sha = await run("git", ["-C", repo, "rev-parse", `refs/heads/${ref}`], {timeoutMs: CAPS.merge});
  const got = (sha.stdout || "").trim();
  if (got !== request.sha) return {ok: false, ref, why: `the ref ${ref} is ${got}, the request read ${request.sha}`};
  return {ok: true, ref, sha: got};
}
/// The default executor: the mission tree's own lander, which merges in a worktree, runs the branch's own
/// rows, pushes last and prints its phases with `+Ns:` stamps.
export function landQuick({missionsDir, repo, dryRun = false}) {
  const script = path.join(missionsDir, 'land-quick.sh');
  return async ({request}) => {
    if (!fs.existsSync(script)) return {ok: false, cause: 'other', detail: `no ${script}`};
    // THE SHA THAT WAS READ IS THE SHA THAT LANDS. The lander is given a ref pinned at the request's sha,
    // never the branch name: a branch that moved after submit makes the lander refuse (stale_sha), and a
    // branch that moved and somehow still pointed here cannot make it land bytes nobody read.
    const pin = await pinRequest({repo, request});
    if (!pin.ok) return {ok: false, cause: 'stale_sha', detail: `could not pin ${request.sha.slice(0, 12)}: ${pin.why}`};
    const started = Date.now();
    const out = await run('bash', [script, pin.ref, ...(dryRun ? ['--dry-run'] : [])], {timeoutMs: CAPS.rows});
    const text = `${out.stdout}${out.stderr}`;
    const base = {seconds: Math.round((Date.now() - started) / 1000), tail: text.trim().split('\n').slice(-6).join('\n')};
    if (out.timedOut) return {ok: false, cause: 'other', detail: `land-quick.sh hit its ${CAPS.rows / 60000} min cap`, ...base};
    if (out.code === 0) return {ok: true, cause: null, detail: 'landed', ...base};
    const cause = /CONFLICT \(/.test(text) ? 'conflict'
      : /own tests are red|own rows are red|FAIL /.test(text) ? 'own_rows_red'
      : /REFUSED|refused/.test(text) ? 'policy_refused'
      : /TIP MOVED/.test(text) ? 'stale_sha'
      : 'other';
    const files = (text.match(/CONFLICT \([^)]*\): [^\n]* in (\S+)/g) || []).map((m) => m.split(' in ').pop());
    const rows = (text.match(/own tests are red:\s*([^\n]+)/) || [])[1] || '';
    return {ok: false, cause, detail: text.trim().split('\n').slice(-8).join('\n'), files, rows, ...base};
  };
}

/// A step that does nothing but say it ran. It exists for the rows (which must not push to a real
/// repository) and for a queue that is being brought up on a host with no lander yet.
export function noopStep(name) {
  return async () => ({ok: true, cause: null, detail: `${name}: nothing to do in this configuration`});
}

// WHERE THE BRANCH'S SHA IS. The runner's crash recovery asks main one question - is this sha in it? - and
// this is the one place that shell command lives.
export function mainContains(repo, sha) {
  return run('git', ['-C', repo, 'merge-base', '--is-ancestor', sha, 'origin/main'], {timeoutMs: CAPS.push})
    .then((out) => out.code === 0);
}
