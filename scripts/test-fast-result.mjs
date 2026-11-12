#!/usr/bin/env node
// `scripts/fast-result.mjs` is what makes a red fast path attributable: every check by name, its
// verdict, the first error line it printed, and the environment the verdict belongs to.
//
// Measured 11/12 on wa-desktop: main was red on a clean node and four sessions each paid an extra full
// run to prove the failure was main's, because the runner printed `FAIL lua <script> (exit 1): <last
// line>` and nothing a script could read back, and nothing said which node/cargo/wasi-sdk produced it.
// This suite pins the contract those sessions needed:
//   * a check's name is the label the runner printed, and a failure keeps its FIRST error line (the
//     last line is often a summary of the failure, not its cause);
//   * a skip is its own status, never a pass, and it carries the reason it did not run;
//   * a row the machine could not run is marked `environment` and is never counted as a verdict on
//     the tree (the landing queue retries those instead of refusing a branch);
//   * the environment header travels with the verdict, and an absent tool says "absent" rather than
//     looking like an empty value;
//   * the summary's `ok` follows the runner's exit code, so a run that named no failure but exited
//     non-zero is not reported as green.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {buildResult, SCHEMA} from './fast-result.mjs';

const WORK = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-fast-result-'));
const started = Date.now();
let passed = 0;
function check(name, condition, detail = '') {
  if (!condition) {
    console.error(`FAIL ${name}${detail ? `: ${detail}` : ''}`);
    process.exitCode = 1;
    throw new Error(`check failed: ${name}`);
  }
  passed += 1;
  console.log(`ok ${name}`);
}

// A run shaped exactly like the one on this node: three passing rows, two failing rows (one of them a
// machine/fork failure), a skipped section, a named skip inside a passing row, and a full env header.
const result = buildResult({
  env: [
    'node\tv22.23.5', 'node_sqlite\tyes', 'cargo\tcargo 1.99.1 (5f94df478 2026-08-27)',
    'wasi_sdk\t34.0', 'lua\tLua 5.4.6', 'commit\te9188496', 'branch\tchange/main-green',
    'bin\t/home/wa/.local/bin/wa', 'bin_sha256\t375fb06374c5a8f1', 'go\tabsent', '',
  ].join('\n'),
  results: [
    ['pass', 'lua', 'scripts/test-hooks-component.lua', '0', '5832', '0', ''].join('\t'),
    ['pass', 'lua', 'scripts/test-done-gate.lua', '0', '412', '0', ''].join('\t'),
    ['fail', 'lua', 'scripts/test-codemode-component.lua', '1', '1693', '0',
      'lua error: scripts/test-codemode-component.lua:18: the fence is not in the guest tool table'].join('\t'),
    ['fail', 'rust', 'rust wa-host', '101', '9000', '0', 'panicked at rust/wa-host/tests/vault_cli.rs:110'].join('\t'),
    ['fail', 'lua', 'scripts/test-fork.lua', '125', '12', '1', 'cannot fork: Input/output error'].join('\t'),
    ['skip', 'rust', 'rust (all crates)', '0', '0', '0', 'cargo is not on PATH here'].join('\t'),
    ['pass', 'checks', 'prompt-docs', '0', '347', '0', ''].join('\t'),
  ].join('\n'),
  skips: ['scripts/test-hooks-component.lua	hooks seam: parity (this binary has no host.hooks capability)'].join('\n'),
  summary: ['ok\t0', 'exit_code\t1', 'elapsed_seconds\t66', 'verdict\tfast path FAILED (3 of 7 checks, 1 skipped, 66s)'].join('\n'),
});

// ---- 1. the checks, by name, with their status and their FIRST error line -------------------------
check('every row is a check under its own name',
  result.checks.length === 7 && result.checks[0].name === 'scripts/test-hooks-component.lua'
  && result.checks[3].name === 'rust wa-host', JSON.stringify(result.checks.map(c => c.name)));
check('a passing check has no error line', result.checks[0].status === 'pass' && result.checks[0].first_error === '');
check('a failing check carries the first error line the row printed',
  result.checks[2].status === 'fail'
  && result.checks[2].first_error.startsWith('lua error: scripts/test-codemode-component.lua:18'),
  result.checks[2].first_error);
check('a rust failure carries its panic line, not the last line of the log',
  result.checks[3].first_error.includes('panicked at'), result.checks[3].first_error);
check('the section is the runner\'s own', result.checks[2].section === 'lua' && result.checks[3].section === 'rust');

// ---- 2. a skip is never a pass, and it says why ---------------------------------------------------
const skipped = result.checks.find(c => c.status === 'skip');
check('a skipped section is its own status', Boolean(skipped) && skipped.name === 'rust (all crates)');
check('and it carries the reason it did not run', skipped.first_error === 'cargo is not on PATH here');
check('the counts separate pass, fail and skip',
  result.summary.passed === 3 && result.summary.failed === 3 && result.summary.skipped === 1,
  JSON.stringify(result.summary));

// ---- 3. the machine is not the tree ---------------------------------------------------------------
check('a fork failure is marked environment', result.checks[4].environment === true);
check('and an ordinary failure is not', result.checks[2].environment === false);

// ---- 4. the environment header travels with the verdict -------------------------------------------
check('the node version is in the result', result.env.node === 'v22.23.5');
check('node:sqlite availability is stated, not implied', result.env.node_sqlite === 'yes');
check('cargo, wasi-sdk and lua are stated', /1\.99\.1/.test(result.env.cargo) && result.env.wasi_sdk === '34.0'
  && /5\.4/.test(result.env.lua), JSON.stringify(result.env));
check('an absent tool says "absent" instead of an empty value', result.env.go === 'absent');
check('the binary that produced the verdict is named with its hash',
  result.env.bin.endsWith('/wa') && /^[0-9a-f]{16}/.test(result.env.bin_sha256));

// ---- 5. named skips inside passing rows are carried, not dropped ----------------------------------
check('a named skip is carried with its check and its reason',
  result.named_skips.length === 1 && result.named_skips[0].check === 'scripts/test-hooks-component.lua'
  && /parity/.test(result.named_skips[0].reason), JSON.stringify(result.named_skips));

// ---- 6. `ok` follows the runner's exit code -------------------------------------------------------
check('a run with failures is not ok', result.summary.ok === false);
check('the runner\'s own verdict line is kept', /fast path FAILED/.test(result.summary.verdict));
const green = buildResult({
  results: [['pass', 'lua', 'scripts/test-a.lua', '0', '10', '0', ''].join('\t')].join('\n'),
  env: 'node\tv22.23.5', summary: ['ok\t1', 'exit_code\t0'].join('\n'),
});
check('a green run is ok', green.summary.ok === true && green.summary.failed === 0);
const contradiction = buildResult({
  results: [['pass', 'lua', 'scripts/test-a.lua', '0', '10', '0', ''].join('\t')].join('\n'),
  env: 'node\tv22.23.5', summary: ['ok\t1', 'exit_code\t3'].join('\n'),
});
check('a non-zero exit is not green even with no named failure', contradiction.summary.ok === false,
  JSON.stringify(contradiction.summary));

// ---- 7. the CLI writes the artifact and says where it is ------------------------------------------
fs.writeFileSync(path.join(WORK, 'results.tsv'), [
  ['pass', 'lua', 'scripts/test-hooks-component.lua', '0', '5832', '0', ''].join('\t'),
  ['fail', 'lua', 'scripts/test-codemode-component.lua', '1', '1693', '0', 'error: the fence'].join('\t'),
].join('\n'));
fs.writeFileSync(path.join(WORK, 'env.tsv'), ['node\tv22.23.5', 'node_sqlite\tyes'].join('\n'));
fs.writeFileSync(path.join(WORK, 'summary.tsv'), ['ok\t0', 'exit_code\t1'].join('\n'));
fs.writeFileSync(path.join(WORK, 'skips.tsv'), ['scripts/test-x.lua\ta reason'].join('\n'));
const out = path.join(WORK, 'nested', 'result.json');
const run = spawnSync(process.execPath, [path.join(import.meta.dirname, 'fast-result.mjs'),
  '--results', path.join(WORK, 'results.tsv'), '--env', path.join(WORK, 'env.tsv'),
  '--skips', path.join(WORK, 'skips.tsv'), '--summary', path.join(WORK, 'summary.tsv'), '--out', out],
{encoding: 'utf8'});
check('the CLI exits 0 and writes the file', run.status === 0 && fs.existsSync(out), `${run.status}: ${run.stderr}`);
const written = JSON.parse(fs.readFileSync(out, 'utf8'));
check('the written result is the same shape', written.schema === SCHEMA && written.checks.length === 2
  && written.checks[1].status === 'fail' && written.checks[1].first_error === 'error: the fence',
  JSON.stringify(written.checks));
check('and it prints one line naming the artifact and the verdict',
  /fast result FAILED \(2 checks, 1 failed, 0 skipped\): /.test(run.stdout || ''), run.stdout);

// ---- 8. an absent file is an empty table, never a crash -------------------------------------------
const empty = buildResult({});
check('a runner that wrote nothing yields an empty, well-formed result',
  empty.checks.length === 0 && empty.summary.ok === false && empty.schema === SCHEMA);

console.log(`fast-result: ${passed} checks passed in ${Math.round((Date.now() - started) / 1000)}s`);
try { fs.rmSync(WORK, {recursive: true, force: true}); } catch { /* windows may still hold a lock */ }
