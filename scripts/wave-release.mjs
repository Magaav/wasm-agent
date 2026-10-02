#!/usr/bin/env node
// A wave release: the one place the full gate runs, and the name a verified tree gets.
//
// Why this exists. The gate used to be the price of every landing and of every deploy, and it was
// priced wrong in both places: a landing is one reviewed change among many, and a deploy is how the
// operator sees that change now. Paying ~15 minutes of the serial resource at each of those points
// made the fabric wait on a suite that was, most of the time, re-proving code it had already passed -
// and a landing whose tree changed had to pay it again anyway (docs/FACTORY.md, "The merge lane").
//
// So the gate moved to the event that actually needs it: a RELEASE. A release is a checkpoint the
// operator asks for, or one that closes a wave, and its product is evidence bound to one exact tree:
// a complete `bash scripts/test.sh` run, its exit, its skip count, its log hash, and the commit and
// tree it tested. `release_verified: true` in this script's output is the only thing in the repository
// that claims a tree was gated - an evolution landing reports `release_verified: false` by design
// (scripts/merge-lane.mjs).
//
//   node scripts/wave-release.mjs --repo <path> [--sha <rev>] [--wave <name>] [--json <file>]
//                                [--check-only] [--no-tag]
//
// What it does, in order, and every step refuses by name:
//
//   1. resolves the revision (default `origin/main`) and its TREE, and refuses a revision that is not
//      an ancestor of `origin/main` - a release certifies main, not a side branch;
//   2. runs the gate on that exact tree through the existing driver
//      (`skills/parallel-evolution/scripts/finish.mjs gate <repo> <sha>`), which records the receipt in
//      the repository's Git metadata - `--check-only` skips this and verifies whatever receipt exists;
//   3. re-verifies the receipt against that exact tree with `scripts/lib/full-gate-proof.mjs`, so a
//      receipt for another tree, a tampered log or a failed run is `no_release`, never a release;
//   4. names it: a local annotated tag `release/<utc>-<short sha>`, carrying the wave name, the tree,
//      the skip count and the receipt path. The tag is NOT pushed - a release is a local fact until
//      someone publishes it, and `git push origin <tag>` is printed rather than run.
//
// Exit codes: 0 released; 3 no_release (the gate did not pass, or no receipt verifies for that tree);
//             4 usage/repository error; 2 refused (the revision is not a release candidate).
import fs from 'node:fs';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {findFullProof} from './lib/full-gate-proof.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '..');
const GATE_COMMAND = 'bash scripts/test.sh';

function git(cwd, ...args) {
  const result = spawnSync('git', args, {cwd, encoding: 'utf8', windowsHide: true, maxBuffer: 32 * 1024 * 1024});
  if (result.status !== 0) throw Error(`git ${args.join(' ')}: ${(result.stderr || result.stdout || '').trim()}`);
  return result.stdout.trim();
}

export function parseArgs(argv, cwd = process.cwd()) {
  const options = {repo: cwd, sha: 'origin/main', wave: null, json: null, checkOnly: false, tag: true};
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (['--repo', '--sha', '--wave', '--json'].includes(arg)) {
      const value = argv[index + 1];
      if (value === undefined) throw Error(`${arg} needs a value`);
      index += 1;
      if (arg === '--repo') options.repo = value;
      else if (arg === '--sha') options.sha = value;
      else if (arg === '--wave') options.wave = value;
      else options.json = value;
    } else if (arg === '--check-only') options.checkOnly = true;
    else if (arg === '--no-tag') options.tag = false;
    else if (arg.startsWith('-')) throw Error(`unknown option ${arg}`);
    else throw Error(`unexpected argument ${arg} (a release certifies a revision, it does not merge one)`);
  }
  if (options.sha.startsWith('-')) throw Error('invalid --sha');
  return options;
}

// `release/20261002-0341-9ffec79242d6` - sortable by time, and it names the tree it verified.
export function releaseTag(at, sha) {
  const iso = at.toISOString().replace(/[-:T]/g, '').slice(0, 12);
  return `release/${iso}-${sha.slice(0, 12)}`;
}

export function release({repo, sha, wave, checkOnly, tag, at = new Date()}) {
  const revision = git(repo, 'rev-parse', `${sha}^{commit}`);
  const tree = git(repo, 'rev-parse', `${revision}^{tree}`);
  // A release certifies the trunk. A revision main does not contain is not a release candidate, and
  // saying so is cheaper than publishing a tag nobody can reproduce.
  const base = spawnSync('git', ['merge-base', '--is-ancestor', revision, 'origin/main'], {cwd: repo, windowsHide: true});
  if (base.status !== 0) return {verdict: 'refused', reason: `${sha} (${revision.slice(0, 12)}) is not an ancestor of origin/main`, revision, tree};

  let gate = {command: GATE_COMMAND, ran: false, exit: null, ms: null, skipped: null, log: null, detail: null};
  if (!checkOnly) {
    const driver = path.join(repo, 'skills', 'parallel-evolution', 'scripts', 'finish.mjs');
    if (!fs.existsSync(driver)) return {verdict: 'refused', reason: `no gate driver at ${driver}`, revision, tree};
    const started = Date.now();
    const run = spawnSync(process.execPath, [driver, 'gate', repo, revision], {cwd: repo, encoding: 'utf8', windowsHide: true, timeout: 3 * 60 * 60 * 1000});
    gate = {...gate, ran: true, exit: run.status === null ? 'timeout_or_spawn_error' : run.status, ms: Date.now() - started,
      detail: run.error ? run.error.message : null, stdout_tail: `${run.stdout || ''}`.trim().split('\n').slice(-3).join(' | ')};
    if (run.status !== 0) {
      return {verdict: 'no_release', reason: `the gate did not exit 0 on ${tree} (exit ${gate.exit})`, revision, tree, gate};
    }
  }

  // The receipt is the point, so it is re-verified against THIS tree rather than trusted because the
  // driver said it wrote it: an identical-tree receipt for another tree proves nothing here.
  const proof = findFullProof(repo, tree);
  if (!proof.verified) {
    return {verdict: 'no_release', reason: proof.reason, revision, tree, gate};
  }
  gate = {...gate, skipped: proof.skipped, ms: gate.ms ?? proof.gate_ms, log: proof.log, log_sha256: proof.log_sha256,
    verdict_line: proof.verdict_line, receipt: proof.receipt, recorded_ms: proof.gate_ms};

  const name = releaseTag(at, revision);
  let tagResult = {created: false, name: null, pushed: false};
  if (tag) {
    const message = `wave release${wave ? ` (${wave})` : ''}: ${tree}\n\n`
      + `commit: ${revision}\ngate: ${GATE_COMMAND}, exit 0, ${proof.skipped ?? '?'} skipped, ${proof.gate_ms} ms\n`
      + `log: ${proof.log} (sha256 ${proof.log_sha256})\nreceipt: ${proof.receipt}\n`;
    const created = spawnSync('git', ['tag', '-a', name, '-m', message, revision], {cwd: repo, encoding: 'utf8', windowsHide: true});
    if (created.status !== 0) return {verdict: 'no_release', reason: `the tree verified, but the release tag could not be written: ${(created.stderr || '').trim()}`, revision, tree, gate};
    tagResult = {created: true, name, pushed: false, push: `git -C ${repo} push origin ${name}`};
  }
  return {verdict: 'released', revision, tree, gate, tag: tagResult, release_verified: true};
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  let exitCode = 4;
  try {
    const options = parseArgs(process.argv.slice(2));
    const repo = path.resolve(options.repo);
    const result = release({repo, sha: options.sha, wave: options.wave, checkOnly: options.checkOnly, tag: options.tag});
    const payload = {schema: 1, lane: 'wave-release', wave: options.wave, check_only: options.checkOnly,
      repo, ...result, release_verified: result.release_verified === true,
      note: 'a release is the gate\'s only home: evolution landings and deploys are deliberately not gated (scripts/merge-lane.mjs, scripts/deploy.sh)'};
    exitCode = result.verdict === 'released' ? 0 : result.verdict === 'refused' ? 2 : 3;
    if (options.json) fs.writeFileSync(path.resolve(options.json), `${JSON.stringify(payload, null, 2)}\n`);
    process.stdout.write(`${JSON.stringify(payload)}\n`);
  } catch (error) {
    exitCode = error.exit || 4;
    process.stdout.write(`${JSON.stringify({schema: 1, lane: 'wave-release', verdict: 'refused', exit_code: exitCode, error: error.message})}\n`);
  }
  process.exitCode = exitCode;
}
