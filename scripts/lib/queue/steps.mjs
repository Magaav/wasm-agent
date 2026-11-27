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

// A CHILD GETS A GIT WITHOUT A WORKSPACE. `land-quick.sh` exports GIT_DIR/GIT_WORK_TREE for its own tree,
// and `git -C <dir>` does NOT override them: a runner started from such a shell would answer every
// question about the wrong repository (this is what turned the queue-pin row red inside the queue at q#42
// while it was green by hand). The three variables are removed here, once, for every child.
// Computed per call, not once at load: a caller may set a variable (a fixture does) after this module is
// imported, and a snapshot taken at load time would silently drop it.
function cleanGitEnv() {
  const env = {...process.env};
  for (const key of ['GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE', 'GIT_OBJECT_DIRECTORY', 'GIT_ALTERNATE_OBJECT_DIRECTORIES']) delete env[key];
  return env;
}

function run(cmd, args, {timeoutMs, env = {}} = {}) {
  return new Promise((resolve) => {
    const child = execFile(cmd, args, {timeout: timeoutMs, env: {...cleanGitEnv(), ...env}, maxBuffer: 8 * 1024 * 1024},
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
/// THE PIN KEEPS THE BRANCH FAMILY (Fable 27/11, after v0 stopped q#23 as a foreign commit): land-quick
/// compares the FIRST TWO dash-words of the branch name with the Agent: trailer of each non-merge commit,
/// so a pin named `change/q<id>-<leaf>` reads as family `q<id>-<leaf>` and every landing stops foreign.
/// The id goes on the END: `change/<leaf>-q<id>` keeps the family, and is still unique per request.
export function pinRefName({id, branch}) {
  const leaf = String(branch || "branch").split("/").pop();
  return `change/${leaf}-q${id}`;
}

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
/// WHERE THE PIN IS WRITTEN. `land-quick.sh` merges and pushes from ITS OWN tree (`R=$HOME/wasm-agent/checkout`,
/// line 20) by branch NAME, so a ref pinned only in the runner s clone is "no branch" for the lander - the swap
/// steps cloned `~/wasm-agent/q-clone`, which is an independent repository and shares no refs with it. The pin
/// therefore belongs in the lander s tree: `landerRepo` (default: the lander s own default), and `repo` stays the
/// runner s own clone, used only for the resume question "is this sha on main?".
export function landQuick({missionsDir, repo, landerRepo = null, dryRun = false}) {
  const pinRepo = landerRepo || path.join(process.env.HOME || "", "wasm-agent", "checkout");
  const script = path.join(missionsDir, 'land-quick.sh');
  return async ({request}) => {
    if (!fs.existsSync(script)) return {ok: false, cause: 'other', detail: `no ${script}`};
    // THE SHA THAT WAS READ IS THE SHA THAT LANDS. The lander is given a ref pinned at the request's sha,
    // never the branch name: a branch that moved after submit makes the lander refuse (stale_sha), and a
    // branch that moved and somehow still pointed here cannot make it land bytes nobody read.
    const pin = await pinRequest({repo: pinRepo, request});
    if (!pin.ok) return {ok: false, cause: 'stale_sha', detail: `could not pin ${request.sha.slice(0, 12)}: ${pin.why}`};
    const started = Date.now();
    // NO LAPTOP INSTALL BY DEFAULT (Victor 27/11): the queue pushes and publishes; an install runs only when
    // the request itself asks for one. LQ_NO_INSTALL=1 is the lander s own switch for that (22/11).
    const asksInstall = request.kind === "install" || Number(request.install || 0) === 1;
    // SPAWNED WITH THE DECISION, never inheriting it: the v0 runner exports LQ_NO_INSTALL=1 for EVERY
    // landing, so an empty env here would let that leak in and a request that NAMES an install would still
    // be told not to install (this is what made the queue-pin row red inside the queue and green by hand,
    // q#48 and q#50). Empty means allowed for the lander, which tests `${LQ_NO_INSTALL:-}` = 1.
    const env = asksInstall ? { LQ_NO_INSTALL: '' } : { LQ_NO_INSTALL: '1' };
    const out = await run('bash', [script, pin.ref, ...(dryRun ? ['--dry-run'] : [])], {timeoutMs: CAPS.rows, env});
    const text = `${out.stdout}${out.stderr}`;
    const base = {seconds: Math.round((Date.now() - started) / 1000), tail: text.trim().split('\n').slice(-6).join('\n')};
    if (out.timedOut) return {ok: false, cause: 'other', detail: `land-quick.sh hit its ${CAPS.rows / 60000} min cap`, ...base};
    if (out.code === 0) return {ok: true, cause: null, detail: 'landed', installPending: false, ...base};
    // PUSHED, THEN SOMETHING FAILED AFTER IT. The landing HAPPENED (main moved) and what is left is an
    // install that did not run; calling that "rejected" would send a worker back to redo a landing that is
    // on main, which is what v0 got wrong twice on 27/11. main is the only authority: if the sha is in it,
    // the verdict is landed with install_pending, and the failure text is carried for whoever runs the
    // install.
    const landedAnyway = await mainContains(pinRepo, pin.sha);
    if (landedAnyway) return {ok: true, cause: null, detail: 'landed; install pending', installPending: true, installError: text.trim().split("\n").slice(-3).join(" "), installAsked: asksInstall, ...base};
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
