// The known-failures baseline: what a tree already fails, by test name, and whether a candidate is
// WORSE than that.
//
// Measured on wasm_the_first, 2026-11-10: main's fast path was red with twelve Lua checks that fail
// for reasons predating any change (the installed node's component set is behind the tree: graph,
// codemode and features compare pinned contracts). The queue refused every landing whose checks did
// not exit 0, so each of five sessions improvised its own judge - a subset of the suite, a "scoped
// phase-1 check", a by-name matcher against a pristine tree - and each landing paid 6-15 minutes
// re-running a pristine baseline.
//
// Two of those improvisations are folded into this file, which is now the only implementation:
//   * the footer session's by-name matcher (landing #15 -> a1bed507): a failure the base tree also
//     has is tolerated, one it does not have is new; a fork/spawn failure is the machine, never a
//     verdict, and gets one serial retry;
//   * session 08c59fbc's `wa-fast-baseline.sh`: also refuse when MORE checks fail than on the base,
//     and fail outright when a non-Lua section (rust, prompt-docs, instructions, landing-queue) fails,
//     because that is never pre-existing in the same way - a crate that will not compile is not an
//     environment fact.
//
// The rule the queue acts on: a candidate passes when it fails nothing the base tree did not already
// fail, and fails no section the base tree passed. A test that stopped failing is reported as fixed on
// main, never as a failure - the base moves while a landing waits in the queue.
//
// The log is `scripts/fast.sh`'s output, whose contract is stated here once:
//   FAIL lua <script> (exit <n>[, environment]) : <last line>   one row of the Lua suite
//   FAIL rust <crate> (exit <n>) : <detail>                     one crate's unit tests
//   FAIL <name> (exit <n>) : <detail>                           a contract check (prompt-docs, ...)
//   fast path ok (<n> checks, ...) | fast path FAILED (<n> of <m> checks, ...)
//   fast: lua <p>/<t> passed (...)
//   fast: ENVIRONMENT <label> ...                                a row the machine could not run
// A check command that names no failing test is not compared by name (see `judgeRun`, `unproven`).

/** Sections whose failure is never a pre-existing environment fact: a crate that will not compile is
 *  a fact about the tree. A baseline that also failed one does not license the next tree to fail it. */
export const STRICT_SECTIONS = new Set(['rust', 'prompt-docs', 'instructions', 'direct-workflow', 'landing-queue', 'crlf', 'naming', 'capability-dispatch']);

const FAILURE = /^FAIL\s+(?:(\w[\w-]*)\s+)?(\S+)\s+\(exit\s+(\d+)(,[^)]*)?\)\s*:?\s*(.*)$/;

/** Every failing check in a run, by name, plus the run's own summary lines.
 *
 *  `name` is the whole label a FAIL line carries, `lua scripts/test-x.lua` / `rust wa-term` /
 *  `prompt-docs`; `section` is its first word when that word is a known section, `checks` otherwise.
 *  A name is the unit the baseline is compared by, so it must be exactly what the runner printed.
 *
 *  `ok` needs both: the runner's own verdict line (when it prints one) and the exit code. Exit 0 with
 *  a FAIL line is a contradiction, and is reported as failed - a runner that prints neither a verdict
 *  nor a FAIL line is `unknown`, and the judge refuses to compare it by name. */
export function parseCheckLog(text, {exitCode = null} = {}) {
  const clean = String(text ?? '').replace(/\0/g, '');
  const failures = [];
  let okVerdict = null;
  let summary = null;
  let failedChecks = null;
  let totalChecks = null;
  let luaPassed = null;
  let luaTotal = null;
  const environmentNotes = [];
  for (const line of clean.split(/\r?\n/)) {
    if (line.startsWith('fast: ENVIRONMENT ')) { environmentNotes.push(line.trim()); continue; }
    const summaryMatch = /^fast path (ok|FAILED) \((\d+)(?: of (\d+))?\s+checks/.exec(line);
    if (summaryMatch) {
      okVerdict = summaryMatch[1] === 'ok';
      summary = line.trim();
      failedChecks = okVerdict ? 0 : Number(summaryMatch[2]);
      totalChecks = summaryMatch[3] ? Number(summaryMatch[3]) : Number(summaryMatch[2]);
      continue;
    }
    const lua = /^fast: lua (\d+)\/(\d+) passed/.exec(line);
    if (lua) { luaPassed = Number(lua[1]); luaTotal = Number(lua[2]); continue; }
    if (!line.startsWith('FAIL ')) continue;
    const match = FAILURE.exec(line);
    if (!match) {
      const label = line.slice(5).trim().slice(0, 200);
      failures.push({section: sectionOf(label), name: label, exit: null, environment: false, detail: line.slice(0, 400)});
      continue;
    }
    const [, first, second, exit, flags, detail] = match;
    // `FAIL lua <script> (exit n)` and `FAIL rust <crate> (exit n)` carry a section and a name;
    // `FAIL prompt-docs (exit 1)` carries only its label.
    const label = second ? `${first} ${second}` : first;
    failures.push({
      section: sectionOf(label), name: label, exit: Number(exit),
      environment: /,\s*environment/.test(flags || ''), detail: String(detail || '').slice(0, 300),
    });
  }
  // An exit code is the runner's own verdict when it prints no summary line of its own: a check
  // command that exits 0 and names no failure HAS passed (a green run is not "unknown"), and one that
  // exits non-zero without naming anything is a failure the judge refuses to compare by name. A
  // summary line that contradicts the exit code ("FAILED" with exit 0) is a failure either way.
  const verdict = failures.length > 0 || okVerdict === false
    ? 'failed'
    : (exitCode === null
      ? (okVerdict === true ? 'ok' : 'unknown')
      : (exitCode === 0 ? 'ok' : 'failed'));
  return {
    ok: verdict === 'ok',
    verdict,
    exit_code: exitCode,
    summary,
    failed_checks: failedChecks === null ? failures.length : failedChecks,
    total_checks: totalChecks,
    lua: {passed: luaPassed, total: luaTotal},
    failures,
    // An exit code that says "only the machine failed" (scripts/fast.sh exits 3 for that) or a row the
    // runner marked, both mean the same thing to the judge: no verdict on the code.
    environment_only_verdict: exitCode === 3,
    environment_notes: environmentNotes,
    named: failures.length > 0,
  };
}

const STRICT_HEAD = new Set([...STRICT_SECTIONS]);

function sectionOf(label) {
  const head = String(label).split(/\s+/)[0] || '';
  return head === 'lua' || STRICT_HEAD.has(head) ? head : 'checks';
}

/** The record the queue stores for one (command, main commit, machine): the names, the counts, and
 *  which of them were the machine rather than the tree. */
export function baselineRecord({run, command = '', commit = '', digest = '', host = '', source = 'pristine', at = Math.floor(Date.now() / 1000)}) {
  return {
    schema: 'wasm-agent-check-baseline/1',
    command, commit, digest, host, source, at,
    ok: run.ok,
    verdict: run.verdict,
    failed_checks: run.failed_checks,
    total_checks: run.total_checks,
    lua: run.lua,
    names: [...new Set(run.failures.map(failure => failure.name))].sort(),
    environment_names: [...new Set(run.failures.filter(failure => failure.environment).map(failure => failure.name))].sort(),
    strict_names: [...new Set(run.failures.filter(failure => STRICT_SECTIONS.has(failure.section)).map(failure => failure.name))].sort(),
    named: run.named || run.ok,
    summary: run.summary || '',
  };
}

/** Whether a candidate run is WORSE than the baseline. The four answers the queue acts on:
 *
 *  pass        - nothing fails that the base tree did not fail, and no section got worse;
 *  environment - the only NEW failures are ones the runner classified as the machine, so the answer is
 *                "retry", never "this code is bad" (one serial retry, then `environment_blocked`);
 *  worse       - a new failing name, a passing name now failing, more failing checks, or a strict
 *                section that failed;
 *  unproven    - the runs name no failing test, so a name-by-name comparison would be a guess.
 */
export function judgeRun({baseline, run}) {
  if (run.ok) return {verdict: 'pass', why: 'the checks passed', new_failures: [], fixed: [], tolerated: [], environment: [], more: false};
  const candidateNames = [...new Set(run.failures.map(failure => failure.name))].sort();
  const strictNow = [...new Set(run.failures.filter(failure => STRICT_SECTIONS.has(failure.section)).map(failure => failure.name))].sort();
  if (!baseline) {
    return {verdict: 'unproven', why: 'there is no baseline to compare this run with', new_failures: candidateNames, fixed: [], tolerated: [], environment: [], more: false, strict: strictNow};
  }
  if (!baseline.named || !run.named) {
    return {verdict: 'unproven', why: 'the check command names no failing test, so a by-name comparison would be a guess', new_failures: candidateNames, fixed: [], tolerated: [], environment: [], more: false, strict: strictNow};
  }
  const baselineNames = new Set(baseline.names || []);
  const environmentNames = new Set(baseline.environment_names || []);
  const newFailures = candidateNames.filter(name => !baselineNames.has(name));
  const fixed = [...baselineNames].filter(name => !candidateNames.includes(name)).sort();
  const tolerated = candidateNames.filter(name => baselineNames.has(name));
  const environment = newFailures.filter(name => {
    const failure = run.failures.find(entry => entry.name === name);
    return failure && failure.environment;
  });
  const strictRegressions = strictNow.filter(name => !(baseline.strict_names || []).includes(name));
  const more = Number(run.failed_checks) > Number(baseline.failed_checks);
  const base = {new_failures: newFailures, fixed, tolerated, environment, more, strict: strictRegressions, baseline_environment: [...environmentNames]};
  if (baseline.ok) {
    // The base tree was green: ANY failure is a regression, except one the runner says the machine
    // caused - that is a retry, and only then a named "could not run".
    if (environment.length === newFailures.length) return {verdict: 'environment', why: `the base tree passed and the only failures are the machine (${environment.join(', ')})`, ...base};
    return {verdict: 'worse', why: `the base tree passed and this tree fails ${newFailures.join(', ')}`, ...base};
  }
  if (strictRegressions.length) return {verdict: 'worse', why: `a section the base tree passed now fails: ${strictRegressions.join(', ')}`, ...base};
  if (newFailures.length === 0) {
    if (more) return {verdict: 'worse', why: `${run.failed_checks} checks fail against ${baseline.failed_checks} on the base, with no new name to explain it`, ...base};
    return {verdict: 'pass', why: `only the ${tolerated.length} failure(s) the base tree already has${fixed.length ? `, and ${fixed.length} fixed on main (${fixed.join(', ')})` : ''}`, ...base};
  }
  if (environment.length === newFailures.length) {
    return {verdict: 'environment', why: `the ${newFailures.length} new failure(s) are the machine, not the tree: ${environment.join(', ')}`, ...base};
  }
  const real = newFailures.filter(name => !environment.includes(name));
  return {verdict: 'worse', why: `${real.length} new failing check(s): ${real.join(', ')}${environment.length ? ` (and ${environment.length} the machine could not run: ${environment.join(', ')})` : ''}`, ...base};
}

/** A run's failures as one stable text block, for a proof log or a refusal message. */
export function describeRun(run, limit = 12) {
  const lines = [];
  for (const failure of run.failures.slice(0, limit)) lines.push(`  ${failure.name} (exit ${failure.exit}${failure.environment ? ', environment' : ''})`);
  if (run.failures.length > limit) lines.push(`  ... +${run.failures.length - limit} more`);
  return lines.join('\n');
}
