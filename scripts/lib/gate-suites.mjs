#!/usr/bin/env node
// Summarise the per-suite records the gate's shims wrote, and declare what each suite can collide on.
//
// TWO KINDS OF EVIDENCE, KEPT APART. The timing half is measured: one JSON line per suite invocation,
// wall time from the wrapper and CPU from the sampler over the suite's own process tree (a LOWER BOUND -
// a child that lives between two 500 ms samples contributes only what was seen). The collision half is
// read out of each suite's own source and cites the lines it read; where the source shows nothing and
// isolation is therefore NOT established, the declaration says `undetermined` rather than guessing. That
// is the suite a later scheduling proposal must not parallelise on a hunch.
//
// Usage: node scripts/lib/gate-suites.cjs summarize <records.jsonl> <out.json> [repo-root]
import fs from 'node:fs';
import path from 'node:path';

// What a suite can collide on, each with the pattern that is evidence FOR it. A miss is not evidence of
// absence: it is why a clean scan reports `undetermined` and not `isolated`.
const PATTERNS = [
  {kind: 'fixed-port', re: /(?:--port|\bport\b|\bPORT\b)[^\n]{0,24}?\b\d{4,5}\b|listen\(\s*\d{4,5}|localhost:\d{4,5}/i},
  {kind: 'temp-dir', re: /os\.tmpdir\(\)|mkdtemp|mktemp|\/tmp\/|Split-Path\$?\s*\$?env:TEMP|GetTempPath/},
  {kind: 'node-state-dir', re: /WASM_AGENT_HOME|\.wasm-agent|WA_GATE_LANE_DIR/},
  {kind: 'network-or-model', re: /fetch\(|https?:\/\/|OPENAI|ANTHROPIC|LLM_BASE_URL|LLM_API_KEY|\bssh\b|Invoke-WebRequest/i},
  {kind: 'filesystem-mutation', re: /rm -rf|rmSync|unlinkSync|rmdir|remove_dir_all|Remove-Item|fs\.rm\(/},
  {kind: 'process-spawn', re: /spawnSync|spawn\(|execFile|child_process|Start-Process|&\s*\$bin/i},
  {kind: 'gate-lane-state', re: /gate-lane|GATE_LANE/},
  {kind: 'git-state', re: /git\s+['"](?:commit|push|fetch|worktree|branch|merge)|git\('(?:commit|push|fetch|worktree|branch|merge)'/},
];
const CLEAN = 'no fixed port, shared temp dir, node state directory, network or model call, process spawn, '
  + 'gate-lane state or git write found in its source; isolation otherwise UNVERIFIED';

function sourceFile(repo, name) {
  const base = name.replace(/^lua:/, '').replace(/^psi:/, '');
  for (const dir of ['scripts', 'tests', 'skills/parallel-evolution/scripts', '.']) {
    const candidate = path.join(repo, dir, base);
    if (base && fs.existsSync(candidate) && fs.statSync(candidate).isFile()) return candidate;
  }
  return null;
}

function scan(file) {
  if (!file) return {file: null, kinds: [], clean: CLEAN, undetermined: true};
  let text = '';
  try { text = fs.readFileSync(file, 'utf8'); } catch { return {file: null, kinds: [], clean: CLEAN, undetermined: true}; }
  const lines = text.split(/\r?\n/);
  const kinds = [];
  for (const {kind, re} of PATTERNS) {
    const evidence = [];
    for (let index = 0; index < lines.length && evidence.length < 3; index += 1) {
      if (re.test(lines[index])) evidence.push(`${path.basename(file)}:${index + 1}: ${lines[index].trim().slice(0, 120)}`);
    }
    if (evidence.length) kinds.push({kind, evidence});
  }
  return {file, kinds, clean: kinds.length ? null : CLEAN, undetermined: kinds.length === 0};
}

export function summarize(recordsPath, outPath, repo) {
  const records = fs.readFileSync(recordsPath, 'utf8').split('\n').filter(Boolean).map(line => {
    try { return JSON.parse(line); } catch { return null; }
  }).filter(Boolean);
  const byName = new Map();
  for (const record of records) {
    const entry = byName.get(record.name) || {name: record.name, runs: 0, wall_ms: 0, cpu_ms: 0, cpu_missing: 0,
      exits: [], file: null, sampled: false};
    entry.runs += 1;
    entry.wall_ms += Number(record.wall_ms || 0);
    if (Number.isFinite(record.cpu_ms)) entry.cpu_ms += record.cpu_ms; else entry.cpu_missing += 1;
    entry.sampled = entry.sampled || Boolean(record.sampled);
    if (entry.exits.length < 12) entry.exits.push(record.exit);
    byName.set(record.name, entry);
  }
  const suites = [...byName.values()].map(entry => {
    const cpu = entry.cpu_missing === entry.runs ? null : entry.cpu_ms;
    const ratio = cpu === null || !entry.wall_ms ? null : Number((cpu / entry.wall_ms).toFixed(3));
    return {...entry, cpu_ms: cpu, cpu_ratio: ratio,
      bound: ratio === null ? 'undetermined' : ratio >= 0.5 ? 'compute' : 'wait'};
  }).sort((left, right) => right.wall_ms - left.wall_ms);
  const top = suites.slice(0, 5);
  const declarations = [];
  for (const suite of suites) {
    if (suite.name.startsWith('lua:')) suite.file = sourceFile(repo, suite.name);
    else suite.file = sourceFile(repo, suite.name);
    const declared = scan(suite.file);
    suite.collision = {kinds: declared.kinds, clean: declared.clean, undetermined: declared.undetermined,
      declared_from: declared.file ? path.relative(repo, declared.file).replace(/\\/g, '/') : 'no source found (a suite built on the fly, or the binary itself)'};
    declarations.push({name: suite.name, runs: suite.runs, wall_ms: suite.wall_ms, cpu_ms: suite.cpu_ms,
      cpu_ratio: suite.cpu_ratio, bound: suite.bound, ...suite.collision});
  }
  const totalWall = suites.reduce((sum, suite) => sum + suite.wall_ms, 0);
  const totalCpu = suites.reduce((sum, suite) => sum + (suite.cpu_ms || 0), 0);
  const undetermined = declarations.filter(item => item.undetermined).length;
  const result = {schema: 1, gate: 'scripts/test.sh',
    measured: 'per-suite wall time from the wrapper; CPU charged inside the suite\'s own process tree by '
      + 'scripts/lib/gate-lane-sample.ps1 walking parent links from the suite pid every 500 ms, summed as '
      + 'user + kernel ticks - a LOWER BOUND, because a process that starts and exits between two samples '
      + 'contributes only what was seen while it ran',
    measured_by: 'scripts/lib/gate-suite.mjs via the shims in scripts/lib/gate-shims',
    declaration_basis: 'read out of each suite\'s own source, with the lines that were read; a clean scan '
      + 'is NOT proof of isolation and is reported as undetermined',
    suite_invocations: records.length, distinct_suites: suites.length,
    total_wall_ms: totalWall, total_cpu_ms: totalCpu, cpu_lower_bound: true,
    undetermined_isolation: undetermined,
    top5_by_wall: top.map(suite => ({name: suite.name, runs: suite.runs, wall_ms: suite.wall_ms, cpu_ms: suite.cpu_ms,
      cpu_ratio: suite.cpu_ratio, bound: suite.bound, collision_kinds: suite.collision ? null : null})),
    top5: top.map(suite => ({name: suite.name, runs: suite.runs, wall_ms: suite.wall_ms, cpu_ms: suite.cpu_ms,
      cpu_ratio: suite.cpu_ratio, bound: suite.bound,
      collisions: (suite.collision?.kinds || []).map(item => ({kind: item.kind, evidence: item.evidence})),
      isolation: suite.collision?.clean || 'declared above', isolation_undetermined: Boolean(suite.collision?.undetermined)})),
    suites: declarations};
  fs.writeFileSync(outPath, `${JSON.stringify(result, null, 1)}\n`);
  return result;
}

if (process.argv[1] && path.resolve(process.argv[1]) === path.resolve(new URL(import.meta.url).pathname.slice(process.platform === 'win32' ? 1 : 0))) {
  const [, , mode, recordsPath, outPath, repo = process.cwd()] = process.argv;
  if (mode !== 'summarize') { process.stderr.write('usage: gate-suites.cjs summarize <records.jsonl> <out.json> [repo]\n'); process.exit(64); }
  const result = summarize(recordsPath, outPath, repo);
  process.stdout.write(`gate suites: ${result.distinct_suites} suites, ${result.suite_invocations} invocations,`
    + ` ${(result.total_wall_ms / 1000).toFixed(1)} s wall, ${(result.total_cpu_ms / 1000).toFixed(1)} s CPU (lower bound),`
    + ` ${result.undetermined_isolation} with undetermined isolation\n`);
  process.stdout.write('  ' + 'suite'.padEnd(38) + 'runs'.padStart(5) + 'wall_s'.padStart(9)
    + 'cpu_s'.padStart(9) + '  bound\n');
  for (const row of result.top5) {
    process.stdout.write('  ' + String(row.name).slice(0, 37).padEnd(38) + String(row.runs).padStart(5)
      + (row.wall_ms / 1000).toFixed(1).padStart(9)
      + (row.cpu_ms === null ? 'n/a' : (row.cpu_ms / 1000).toFixed(1)).padStart(9)
      + `  ${row.bound}${row.isolation_undetermined ? ' (isolation undetermined)' : ''}\n`);
  }
}
