#!/usr/bin/env node
// The fast path's machine-readable result: one JSON object naming every check the run made, its
// verdict, the first error line it printed, and the environment the verdict belongs to.
//
//   node scripts/fast-result.mjs --results <rows.tsv> --env <env.tsv> [--skips <skips.tsv>]
//                                [--summary <summary.tsv>] --out <file> [--title <text>]
//
// Why this exists (11/12): on a machine whose main is red, four sessions each paid an extra full fast
// run to prove that a failing row was main's own failure and not their change. Nothing recorded WHICH
// checks failed - the log carried `FAIL lua <script> (exit 1): <last line>` and no machine could read
// it back, and the runner could not say which node, cargo or wasi-sdk produced the verdict. So a
// reader had to re-run the suite by hand to separate "the tree broke this" from "this machine fails
// this row already". The landing queue's baseline (scripts/lib/landing-baseline.mjs) reads the LOG by
// name; this file is the same facts in a shape a script can consume without parsing prose, and the
// environment header travels with them so a failure can be attributed to a machine.
//
// The row format is scripts/fast.sh's own, tab-separated, one row per check:
//    status  section  name  exit  ms  environment  first_error
// `status` is pass, fail or skip. For a skip, `first_error` carries the reason the check did not run
// (a skip is never a pass). `environment` is 1 when the row failed because the machine could not
// start a process (scripts/lib/fast-environment.sh), which the landing queue treats as retry-later
// rather than as a verdict on the tree.
//
// The env file is key/value per line, as the runner measured it: node, node_sqlite, cargo, wasi_sdk,
// lua, root, commit, branch, bin, bin_sha256. An absent tool is the string "absent", never an empty
// value: "" and "not installed" must not look the same to a reader.
import fs from 'node:fs';
import path from 'node:path';

export const SCHEMA = 1;

function rows(text) {
  return String(text ?? '')
    .split(/\r?\n/)
    .filter(line => line.trim() !== '')
    .map(line => line.split('\t'));
}

/** Build the result object from the runner's three tab-separated tables. Pure: no clock, no files. */
export function buildResult({results = '', env = '', summary = '', skips = ''} = {}) {
  const environment = {};
  for (const [key, value] of rows(env)) if (key) environment[key.replace(/:$/, '')] = value ?? '';
  const totals = {};
  for (const [key, value] of rows(summary)) if (key) totals[key.replace(/:$/, '')] = value ?? '';
  const checks = rows(results).map(([status, section, name, exit, ms, machine, firstError] = []) => ({
    name: name ?? '',
    section: section || 'checks',
    status: status === 'pass' || status === 'skip' ? status : 'fail',
    exit: exit === undefined || exit === '' ? null : Number(exit),
    ms: ms === undefined || ms === '' ? null : Number(ms),
    // A row the machine could not run: named, never silently a failure of the tree.
    environment: machine === '1',
    first_error: firstError || '',
  }));
  const named = rows(skips)
    .filter(([check]) => check)
    .map(([check, reason]) => ({check, reason: reason || ''}));
  const failed = checks.filter(check => check.status === 'fail').length;
  const skipped = checks.filter(check => check.status === 'skip').length;
  // `ok` needs both: no failing row, and the runner's own exit code saying 0. A runner that wrote no
  // summary at all is UNKNOWN, and unknown is not green - the same rule `parseCheckLog` applies to a
  // log with no verdict (scripts/lib/landing-baseline.mjs).
  const ok = failed === 0 && totals.ok !== '0' && String(totals.exit_code ?? '') === '0';
  return {
    schema: SCHEMA,
    runner: 'scripts/fast.sh',
    generated_at: new Date().toISOString(),
    env: environment,
    summary: {
      checks: checks.length,
      passed: checks.filter(check => check.status === 'pass').length,
      failed,
      skipped,
      ok,
      // The runner's own words ("fast: lua 173/175 passed", "1 named skip inside a passing row") and
      // its exit code, so a consumer never has to infer the verdict from the row counts alone.
      verdict: totals.verdict || '',
      exit_code: totals.exit_code === undefined || totals.exit_code === '' ? null : Number(totals.exit_code),
      elapsed_seconds: totals.elapsed_seconds === undefined || totals.elapsed_seconds === ''
        ? null : Number(totals.elapsed_seconds),
    },
    // Holes inside passing rows: a suite that could not run half of itself says so on its own stdout
    // (`SKIP <test>: <reason>`), and a green row with thirty skips is not the same fact as a green row.
    named_skips: named,
    checks,
  };
}

function readIfPresent(file) {
  if (!file) return '';
  try { return fs.readFileSync(file, 'utf8'); } catch { return ''; }
}

function main(argv) {
  const options = {};
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (!arg.startsWith('--')) throw new Error(`unexpected argument '${arg}'`);
    options[arg.slice(2)] = argv[++i];
  }
  if (!options.out) throw new Error('usage: fast-result.mjs --results <tsv> --env <tsv> [--skips <tsv>] [--summary <tsv>] --out <file>');
  const result = buildResult({
    results: readIfPresent(options.results),
    env: readIfPresent(options.env),
    skips: readIfPresent(options.skips),
    summary: readIfPresent(options.summary),
  });
  fs.mkdirSync(path.dirname(path.resolve(options.out)), {recursive: true});
  fs.writeFileSync(options.out, `${JSON.stringify(result, null, 2)}\n`, 'utf8');
  // One line on stdout, so a caller that only reads the log knows where the artifact is.
  process.stdout.write(`fast result ${result.summary.ok ? 'ok' : 'FAILED'} (${result.summary.checks} checks, `
    + `${result.summary.failed} failed, ${result.summary.skipped} skipped): ${options.out}\n`);
  return result;
}

// Importable (the test does) and runnable (the runner does).
if (process.argv[1] && path.resolve(process.argv[1]) === path.resolve(new URL(import.meta.url).pathname)) {
  try { main(process.argv.slice(2)); } catch (error) {
    console.error(`fast-result: ${error.message}`);
    process.exitCode = 2;
  }
}
