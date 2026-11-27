#!/usr/bin/env node
// The path policy decides, from DATA, which landings stop for a person.
//
// WHAT THIS CAN FAIL ON:
//   * a glob that matches more than it says (`scripts/*.sh` matching `scripts/lib/deploy.sh`) - the rule
//     would then stop landings nobody reviewed and the first response would be to widen it into uselessness;
//   * a hash that does not move when the policy file changes - an approval made under one policy would
//     cover landings taken under another;
//   * a `never` path that is only a `review` path;
//   * the real policy file drifting from the shape this module reads.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {globToRegExp, loadPolicy, policyHash, evaluate, policyPath} from './lib/queue/policy.mjs';

let checks = 0;
const fail = (message) => { console.error(`FAIL test-queue-policy: ${message}`); process.exit(1); };
const ok = (condition, message) => { if (!condition) fail(message); checks += 1; };
const eq = (actual, expected, message) => ok(Object.is(actual, expected), `${message} (got ${JSON.stringify(actual)}, wanted ${JSON.stringify(expected)})`);

const work = fs.mkdtempSync(path.join(process.env.TMPDIR || os.tmpdir(), 'wa-queue-policy-'));
process.on('exit', () => { try { fs.rmSync(work, {recursive: true, force: true}); } catch { /* best effort */ } });

// ---- 1. the glob semantics, one by one ----------------------------------------------------------------
const m = (glob, file) => globToRegExp(glob).test(file);
ok(m('scripts/deploy.sh', 'scripts/deploy.sh'), 'a literal path matches itself');
ok(!m('scripts/deploy.sh', 'scripts/deploy.sh.bak'), 'and not a longer name');
ok(m('scripts/*.sh', 'scripts/deploy.sh'), '* matches inside one directory');
ok(!m('scripts/*.sh', 'scripts/lib/deploy.sh'), '* does NOT cross a directory - that is what ** is for');
ok(m('scripts/**', 'scripts/lib/deploy.sh'), '** crosses directories');
ok(m('deploy/**', 'deploy/unit/x.service'), '** at the end matches the whole subtree');
ok(!m('deploy/**', 'deploys/x'), 'a prefix without a separator is not the directory');
ok(m('**/*.key', 'vault/keys/a.key'), '**/ at the start matches at any depth');
ok(m('rust/wa-tls/**', 'rust/wa-tls/src/anchor.rs'), 'a crate subtree');

// ---- 2. the repo's own policy file, read the way the queue reads it ------------------------------------
const repo = path.join(path.dirname(new URL(import.meta.url).pathname), '..');
const file = policyPath(repo);
ok(fs.existsSync(file), `the repo has ${file}`);
const policy = loadPolicy(file);
ok(policy.review.length >= 8, 'the policy names the paths that install a node, hold a key, move the host');

const deploy = evaluate(policy, ['scripts/deploy.sh', 'docs/HOST.md']);
eq(deploy.needsReview, true, 'a landing that touches scripts/deploy.sh needs a person');
eq(deploy.review.length, 1, 'and names exactly the file that matched');
ok(/install/.test(deploy.review[0].why), 'with the reason the policy gives');
const tls = evaluate(policy, ['rust/wa-tls/src/anchor.rs']);
eq(tls.needsReview, true, 'a trust anchor is reviewed');
const docs = evaluate(policy, ['docs/HOST.md', 'lua/core/status.lua']);
eq(docs.needsReview, false, 'a docs and Lua change is not');
eq(docs.refuses, false, 'and nothing about it is refused');
const orchestrator = evaluate(policy, ['_orch/x.sh']);
eq(orchestrator.refuses, true, 'an _orch path is never a landing');
const both = evaluate(policy, ['policies/landing-policy.json']);
eq(both.needsReview, true, 'changing the policy is itself a review');

// ---- 3. the hash moves with the file, and only with the content ---------------------------------------
const hashA = policyHash(file);
ok(/^[0-9a-f]{64}$/.test(hashA), 'the hash is a sha256');
const copy = path.join(work, 'p.json');
fs.copyFileSync(file, copy);
eq(policyHash(copy), hashA, 'a byte-identical copy hashes the same');
const edited = JSON.parse(fs.readFileSync(file, 'utf8'));
edited.review.push({glob: 'scripts/whatever.sh', why: 'a new rule'});
fs.writeFileSync(copy, JSON.stringify(edited, null, 2));
ok(policyHash(copy) !== hashA, 'adding a rule changes the hash');
const reordered = {...policy, schema: policy.schema};
fs.writeFileSync(copy, JSON.stringify(reordered));
eq(policyHash(copy), hashA, 'key order and whitespace are normalised, so formatting is not a policy change');

console.log(`queue policy ok (${checks} checks)`);
