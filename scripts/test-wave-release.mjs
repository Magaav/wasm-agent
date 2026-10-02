#!/usr/bin/env node
// A release is the gate's ONLY home, and this pins that - including the refusals.
//
// What it pins, in the order `wave-release.mjs` decides it: that a revision `origin/main` does not
// contain is refused rather than released; that a tree with no receipt is `no_release` and NOT a
// release, and that it creates no tag; that a junk receipt left in the repository's Git metadata
// cannot fake one (the verifier, not the driver's word, is what decides); that the tag name is the
// sortable one this script promises; and that an argument that would merge something is refused,
// because a release certifies a revision and merges nothing.
//
// Hermetic: a temp repository with a local `origin/main` ref, no network, no gate run and no model.
// The verified path is not fabricated here - `findFullProof` requires runner bytes, a hashed gate log
// and a host attestation, and `scripts/test-full-gate-proof.mjs` is the fixture for that verifier. A
// real release on a real tree is a release, not a test.
//
// Usage:  node scripts/test-wave-release.mjs      (about 2 s)
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {release, releaseTag, parseArgs} from './wave-release.mjs';

const SCRIPT = path.join(path.dirname(fileURLToPath(import.meta.url)), 'wave-release.mjs');
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-wave-release-'));
let checks = 0, failed = 0;
const ok = (condition, label, detail) => {
  checks += 1;
  if (condition) console.log(`  ok   ${label}`);
  else { failed += 1; console.log(`  FAIL ${label}${detail ? ` - ${detail}` : ''}`); }
};
function git(cwd, ...args) {
  const result = spawnSync('git', ['-c', 'user.name=fixture', '-c', 'user.email=fixture@example.invalid', ...args],
    {cwd, encoding: 'utf8', windowsHide: true});
  if (result.status !== 0) throw Error(`git ${args.join(' ')}: ${(result.stderr || result.stdout).trim()}`);
  return result.stdout.trim();
}
function cli(args, environment = {}) {
  const result = spawnSync(process.execPath, [SCRIPT, ...args], {cwd: root, encoding: 'utf8', windowsHide: true, env: {...process.env, ...environment}});
  let json = null;
  try { json = JSON.parse(result.stdout.trim()); } catch { /* a usage refusal is JSON too */ }
  return {status: result.status, json, stderr: result.stderr};
}

try {
  const repo = path.join(root, 'repo');
  fs.mkdirSync(repo, {recursive: true});
  git(root, 'init', '-q', '--initial-branch=main', repo);
  fs.writeFileSync(path.join(repo, 'a.txt'), 'base\n');
  git(repo, 'add', '-A'); git(repo, 'commit', '-q', '-m', 'fixture: base');
  const mainSha = git(repo, 'rev-parse', 'HEAD');
  // A local remote-tracking ref: the ancestor rule is about the trunk, not about the network.
  git(repo, 'update-ref', 'refs/remotes/origin/main', mainSha);
  git(repo, 'switch', '-q', '-c', 'change/side');
  fs.writeFileSync(path.join(repo, 'side.txt'), 'side\n');
  git(repo, 'add', '-A'); git(repo, 'commit', '-q', '-m', 'feat(side): a commit main does not have');
  const sideSha = git(repo, 'rev-parse', 'HEAD');
  git(repo, 'switch', '-q', 'main');

  // 1. No receipt for this tree, and that is `no_release` - never a release, and no tag.
  const none = release({repo, sha: 'origin/main', wave: 'fixture', checkOnly: true, tag: true});
  ok(none.verdict === 'no_release', 'no receipt for the tree is no_release', none.verdict);
  ok(none.release_verified !== true, 'no_release does not claim release_verified');
  ok(none.tree === git(repo, 'rev-parse', 'HEAD^{tree}'), 'the release names the exact tree it checked');
  ok(git(repo, 'tag', '-l') === '', 'no receipt created no tag');

  // 2. A junk receipt in the Git metadata cannot fake one.
  fs.writeFileSync(path.join(repo, '.git', 'wa-finish-gate.json'), JSON.stringify({verdict: 'pass', tree: none.tree, gate: {exit: 0}}) + '\n');
  const junk = release({repo, sha: 'origin/main', checkOnly: true, tag: true});
  ok(junk.verdict === 'no_release', 'a hand-written receipt is refused by the verifier', junk.reason);
  ok(git(repo, 'tag', '-l') === '', 'a refused release created no tag');
  fs.rmSync(path.join(repo, '.git', 'wa-finish-gate.json'), {force: true});

  // 3. A revision the trunk does not contain is refused, not released.
  const side = release({repo, sha: sideSha, checkOnly: true, tag: true});
  ok(side.verdict === 'refused', 'a revision outside origin/main is refused', side.reason);
  ok(/not an ancestor/.test(String(side.reason)), 'the refusal names the ancestor rule', side.reason);
  ok(git(repo, 'tag', '-l') === '', 'a refused revision created no tag');

  // 4. The CLI says the same thing, with the exit codes the header promises.
  const cliNone = cli(['--repo', repo, '--sha', 'origin/main', '--check-only', '--wave', 'fixture']);
  ok(cliNone.status === 3, 'check-only without a receipt exits 3', `status=${cliNone.status}`);
  ok(cliNone.json?.verdict === 'no_release' && cliNone.json?.release_verified === false, 'the CLI output states no_release and release_verified false', JSON.stringify(cliNone.json));
  ok(cliNone.json?.lane === 'wave-release' && cliNone.json?.check_only === true, 'the CLI output is one identified JSON object');
  const cliSide = cli(['--repo', repo, '--sha', sideSha, '--check-only']);
  ok(cliSide.status === 2, 'a non-candidate revision exits 2', `status=${cliSide.status}`);
  const cliMerge = cli(['--repo', repo, 'some-sha-to-merge']);
  ok(cliMerge.status === 4, 'a bare revision argument is a usage error, not a merge', `status=${cliMerge.status}`);
  ok(cliMerge.json?.verdict === 'refused', 'the usage error is a named refusal');
  const cliBad = cli(['--repo', repo, '--gate-mode', 'none']);
  ok(cliBad.status === 4, 'an unknown option is refused', `status=${cliBad.status}`);

  // 5. The tag name is the sortable one the header promises.
  const tag = releaseTag(new Date('2026-10-02T03:41:07Z'), 'abcdef0123456789');
  ok(tag === 'release/202610020341-abcdef012345', 'the tag is release/<utc>-<short sha>', tag);
  ok(parseArgs(['--repo', '.', '--wave', 'w']).sha === 'origin/main', 'the default revision is origin/main');
  ok(parseArgs([]).tag === true && parseArgs(['--no-tag']).tag === false, 'tagging is on by default and can be turned off');

  console.log(`\nwave release: ${checks - failed} of ${checks} checks passed${failed ? `, ${failed} FAILED` : ''}`);
  process.exitCode = failed ? 1 : 0;
} finally {
  fs.rmSync(root, {recursive: true, force: true});
}
