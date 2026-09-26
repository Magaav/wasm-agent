#!/usr/bin/env node
// Controlled, opt-in paid-model benchmark for source-discovery/edit workflows.
// Every solver gets a detached checkout of the same commit and the same tools/model.
// Only profile instructions differ. Solvers overlap; independent verification is serialized
// afterwards so competing Cargo builds cannot decide the winner.
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawn, spawnSync } = require('node:child_process');
const activeChildren = new Set();

function arg(name, fallback = '') {
  const at = process.argv.indexOf('--' + name);
  return at >= 0 && process.argv[at + 1] ? process.argv[at + 1] : fallback;
}
function requiredRealConsent() {
  if (arg('provider', 'mock') === 'real' && arg('confirm-paid', '') !== 'yes') {
    throw new Error('real provider requires --confirm-paid yes');
  }
}
function safeLabel(value) { return String(value).replace(/[^a-zA-Z0-9_.-]+/g, '-'); }
function run(command, args, options = {}) {
  return spawnSync(command, args, { cwd: options.cwd, env: options.env || process.env,
    encoding: 'utf8', timeout: options.timeout || 120000, windowsHide: true, maxBuffer: 16 * 1024 * 1024 });
}
function spawnCaptured(command, args, cwd, env, stdoutPath, stderrPath) {
  const stdout = fs.openSync(stdoutPath, 'w');
  const stderr = fs.openSync(stderrPath, 'w');
  const started = Date.now();
  const child = spawn(command, args, { cwd, env, windowsHide: true, stdio: ['ignore', stdout, stderr] });
  activeChildren.add(child);
  return new Promise((resolve) => {
    child.on('error', (error) => {
      fs.appendFileSync(stderrPath, `spawn failed: ${error.message}\n`);
    });
    child.on('close', (code, signal) => {
      activeChildren.delete(child);
      fs.closeSync(stdout); fs.closeSync(stderr);
      resolve({ code, signal, elapsed_ms: Date.now() - started });
    });
  });
}
function readJson(file, fallback) { try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return fallback; } }

requiredRealConsent();
const harness = path.resolve(__dirname, '..');
const gitRoot = run('git', ['rev-parse', '--show-toplevel'], { cwd: harness });
if (gitRoot.status !== 0) throw new Error(gitRoot.stderr || 'not in a git repository');
const repo = path.resolve(gitRoot.stdout.trim());
const base = arg('base', 'bad2cdc');
const provider = arg('provider', 'mock');
const wasmProvider = arg('wasm-provider', 'opencode-go');
const model = arg('model', 'deepseek-v4.1-flash');
const luaRoot = path.resolve(arg('lua-root', repo));
const subscriptionModels = ['gpt-6-luna', 'gpt-6-sol', 'gpt-6-astra'];
if (wasmProvider === 'openai-sub' && !subscriptionModels.includes(model)) {
  throw new Error(`model ${model} is not in the openai-sub catalog`);
}
const repetitions = Math.max(1, Math.min(10, Number(arg('n', '1')) || 1));
const binary = path.resolve(arg('wa', path.join(harness, 'rust', 'target', 'release', process.platform === 'win32' ? 'wa.exe' : 'wa')));
if (!fs.existsSync(binary)) throw new Error(`wa binary not found: ${binary}`);
const stamp = new Date().toISOString().replace(/[:.]/g, '-');
const root = path.resolve(arg('output-dir', path.join(os.homedir(), '.wasm-agent', 'benchmarks', `edit-workflow-${stamp}`)));
const trees = path.join(root, 'worktrees');
fs.mkdirSync(trees, { recursive: true });
function interrupt(signal) {
  fs.writeFileSync(path.join(root, 'interrupted.txt'), `${signal} at ${new Date().toISOString()}\n`);
  for (const child of activeChildren) {
    if (!child.pid) continue;
    if (process.platform === 'win32') {
      const stopped = spawnSync('taskkill', ['/PID', String(child.pid), '/T', '/F'],
        { windowsHide: true, timeout: 10000, encoding: 'utf8' });
      if (stopped.status !== 0) child.kill();
    } else {
      child.kill('SIGTERM');
    }
  }
  process.exit(signal === 'SIGINT' ? 130 : 143);
}
process.once('SIGINT', () => interrupt('SIGINT'));
process.once('SIGTERM', () => interrupt('SIGTERM'));

const resolved = run('git', ['rev-parse', `${base}^{commit}`], { cwd: repo });
if (resolved.status !== 0) throw new Error(resolved.stderr || `unknown base ${base}`);
const baseCommit = resolved.stdout.trim();
const harnessFiles = [
  'scripts/experiment-edit-workflow.cjs', 'scripts/experiment-tool-choice.cjs',
  'scripts/experiment-tool-choice.lua', 'scripts/lib/experiment-edit-verify.cjs',
  'scripts/lib/experiment-verify.lua',
];
const harnessHashes = Object.fromEntries(harnessFiles.map((relative) => [relative,
  crypto.createHash('sha256').update(fs.readFileSync(path.join(harness, relative))).digest('hex')]));
const arms = [
  { id: 'control', profile: 'exp-edit-control', review: 'exp-review-graph' },
  { id: 'source-first', profile: 'exp-edit-source-first', review: 'exp-review-graph' },
  { id: 'graph-first', profile: 'exp-edit-graph-first', review: 'exp-review-source' },
];
const attempts = [];
for (let runIndex = 1; runIndex <= repetitions; runIndex += 1) {
  for (const arm of arms) {
    const id = `${arm.id}-${runIndex}`;
    const worktree = path.join(trees, id);
    const added = run('git', ['worktree', 'add', '--detach', worktree, baseCommit], { cwd: repo, timeout: 120000 });
    if (added.status !== 0) throw new Error(`worktree ${id}: ${added.stderr || added.stdout}`);
    attempts.push({ ...arm, id, run: runIndex, worktree, dir: path.join(root, id) });
  }
}
fs.writeFileSync(path.join(root, 'manifest.json'), JSON.stringify({
  schema: 'wasm-agent.edit-workflow-experiment/v1', created_at: new Date().toISOString(),
  base_requested: base, base_commit: baseCommit, provider, wasm_provider: wasmProvider,
  model, lua_root: luaRoot, reasoning: process.env.WASM_AGENT_REASONING || null, repetitions,
  harness_commit: run('git', ['rev-parse', 'HEAD'], { cwd: harness }).stdout.trim(),
  harness_files_sha256: harnessHashes,
  binary_sha256: crypto.createHash('sha256').update(fs.readFileSync(binary)).digest('hex'),
  arms: arms.map(({ id, profile, review }) => ({ id, profile, review })),
}, null, 2));

(async () => {
  // Start the complete wave before awaiting any child. Each driver has its own node,
  // home, graph DB, ledger and source checkout.
  const solverRuns = attempts.map(async (attempt) => {
    fs.mkdirSync(attempt.dir, { recursive: true });
    const ledger = path.join(attempt.dir, 'solver-ledger.json');
    const args = [path.join(harness, 'scripts', 'experiment-tool-choice.cjs'), binary,
      '--repo-root', attempt.worktree, '--arm', attempt.id, '--task', 'whatsapp-controls',
      '--n', '1', '--profile', attempt.profile, '--provider', provider,
      '--wasm-provider', wasmProvider, '--model', model, '--lua-root', luaRoot,
      '--index', '1', '--label', `solver-${attempt.id}`, '--timeout_ms', '1500000', '--output', ledger];
    attempt.solver = await spawnCaptured(process.execPath, args, harness, process.env,
      path.join(attempt.dir, 'solver.stdout.log'), path.join(attempt.dir, 'solver.stderr.log'));
    attempt.ledger = readJson(ledger, []);
  });
  await Promise.all(solverRuns);

  // Capture exactly what each model left before injecting verifier code.
  for (const attempt of attempts) {
    const head = run('git', ['rev-parse', 'HEAD'], { cwd: attempt.worktree });
    attempt.head = head.stdout.trim();
    attempt.head_unchanged = head.status === 0 && attempt.head === baseCommit;
    const patch = run('git', ['diff', '--binary', '--no-ext-diff'], { cwd: attempt.worktree });
    fs.writeFileSync(path.join(attempt.dir, 'candidate.patch'), patch.stdout || '');
    const untracked = run('git', ['ls-files', '--others', '--exclude-standard'], { cwd: attempt.worktree });
    attempt.untracked = String(untracked.stdout || '').split(/\r?\n/).filter(Boolean);
    for (const relative of attempt.untracked) {
      const source = path.join(attempt.worktree, relative);
      const destination = path.join(attempt.dir, 'untracked', relative);
      const stat = fs.statSync(source);
      if (!stat.isFile() || stat.size > 1024 * 1024) continue;
      fs.mkdirSync(path.dirname(destination), { recursive: true });
      fs.copyFileSync(source, destination);
    }
  }

  // One verifier at a time. Rotate order by repetition so a systematic warm-machine
  // advantage is not always assigned to the same arm; every verifier still has its own target dir.
  const verifyOrder = [...attempts].sort((a, b) => {
    const ai = arms.findIndex((x) => x.id === a.id.split(/-\d+$/)[0]);
    const bi = arms.findIndex((x) => x.id === b.id.split(/-\d+$/)[0]);
    return (a.run - b.run) || (((ai + a.run - 1) % arms.length) - ((bi + b.run - 1) % arms.length));
  });
  for (const attempt of verifyOrder) {
    const output = path.join(attempt.dir, 'verification.json');
    const verification = run(process.execPath, [path.join(harness, 'scripts', 'lib', 'experiment-edit-verify.cjs'),
      '--repo', attempt.worktree, '--output', output, '--target-dir', path.join(attempt.dir, 'cargo-target')],
      { cwd: harness, timeout: 1500000 });
    fs.writeFileSync(path.join(attempt.dir, 'verification.stdout.log'), verification.stdout || '');
    fs.writeFileSync(path.join(attempt.dir, 'verification.stderr.log'), verification.stderr || '');
    attempt.verification = readJson(output, { passed: false, error: 'verification_result_missing' });
  }

  // Fresh, read-only shadows review every candidate concurrently. Their instructions are
  // deliberately opposite the solver treatment where possible.
  for (const attempt of attempts) {
    const reviewPatch = path.join(attempt.worktree, '.wa-experiment-review.patch');
    const trackedPatch = fs.readFileSync(path.join(attempt.dir, 'candidate.patch'), 'utf8');
    fs.writeFileSync(reviewPatch,
      `${trackedPatch}\nUntracked candidate files:\n${attempt.untracked.join('\n')}\n`);
    attempt.review_patch = reviewPatch;
  }
  const reviews = attempts.map(async (attempt) => {
    const ledger = path.join(attempt.dir, 'review-ledger.json');
    const args = [path.join(harness, 'scripts', 'experiment-tool-choice.cjs'), binary,
      '--repo-root', attempt.worktree, '--arm', `review-${attempt.id}`, '--task', 'whatsapp-controls-review',
      '--n', '1', '--profile', attempt.review, '--provider', provider,
      '--wasm-provider', wasmProvider, '--model', model, '--lua-root', luaRoot,
      '--index', '1', '--label', `review-${attempt.id}`, '--timeout_ms', '900000', '--output', ledger];
    attempt.review_run = await spawnCaptured(process.execPath, args, harness, process.env,
      path.join(attempt.dir, 'review.stdout.log'), path.join(attempt.dir, 'review.stderr.log'));
    attempt.review_ledger = readJson(ledger, []);
  });
  try {
    await Promise.all(reviews);
  } finally {
    for (const attempt of attempts) fs.rmSync(attempt.review_patch, { force: true });
  }

  const summary = attempts.map((attempt) => {
    const row = attempt.ledger[0] || {};
    const measured = row.measured || {};
    const inference = measured.inference || {};
    const calls = row.tools || [];
    const count = (name) => calls.filter((call) => call.name === name).length;
    return {
      arm: attempt.id.replace(/-\d+$/, ''), run: attempt.run,
      worktree: attempt.worktree, head_unchanged: attempt.head_unchanged,
      solver_process_code: attempt.solver.code, solver_wall_ms: attempt.solver.elapsed_ms,
      child_state: row.state || null, child_elapsed_ms: row.elapsed_ms || null,
      model_calls: inference.calls || 0, model_ms: inference.ms || 0,
      tool_ms: measured.tool_ms || 0,
      prompt_tokens: inference.prompt || 0, output_tokens: inference.output || 0,
      unpriced_calls: inference.unpriced || 0,
      cost_usd: Number(inference.unpriced || 0) > 0 || !inference.calls ? null : (inference.cost || 0),
      tool_calls: calls.length, tool_failures: (row.errors || []).length,
      graph_calls: count('graph'), read_calls: count('read') + count('read_many'),
      bash_calls: count('bash'), edit_calls: count('edit'), first_tool: row.first_tool || null,
      verifier_passed: attempt.verification.passed === true,
      verified_completion: attempt.verification.passed === true && attempt.head_unchanged
        && attempt.solver.code === 0 && row.state === 'completed',
      failed_checks: (attempt.verification.checks || []).filter((item) => !item.ok).map((item) => item.name),
      review_profile: attempt.review,
      review_reply: (((attempt.review_ledger || [])[0] || {}).reply || '').slice(0, 16000),
      review_errors: ((((attempt.review_ledger || [])[0] || {}).errors) || []).length,
      review_process_code: attempt.review_run.code,
      review_wall_ms: attempt.review_run.elapsed_ms,
      review_model_ms: (((attempt.review_ledger || [])[0] || {}).measured || {}).inference?.ms || 0,
      review_prompt_tokens: (((attempt.review_ledger || [])[0] || {}).measured || {}).inference?.prompt || 0,
      review_output_tokens: (((attempt.review_ledger || [])[0] || {}).measured || {}).inference?.output || 0,
      untracked: attempt.untracked,
    };
  });
  const effective = attempts.map((attempt) => (attempt.ledger[0] || {}).effective || {});
  const comparable = Boolean(effective.length > 0 && effective[0].model && effective[0].schema_hash
    && effective[0].settings && effective[0].tools
    && effective.every((item) => item.model && item.schema_hash && item.settings && item.tools
      && item.model === effective[0].model
      && JSON.stringify(item.settings || {}) === JSON.stringify(effective[0].settings || {})
      && item.schema_hash === effective[0].schema_hash
      && JSON.stringify(item.tools || []) === JSON.stringify(effective[0].tools || [])));
  const byArm = arms.map((arm) => {
    const rows = summary.filter((row) => row.arm === arm.id);
    const verified = rows.filter((row) => row.verified_completion).length;
    const sum = (key) => rows.reduce((total, row) => total + Number(row[key] || 0), 0);
    const costKnown = rows.every((row) => row.cost_usd !== null);
    return {
      arm: arm.id, attempts: rows.length, verified,
      solver_wall_ms: sum('solver_wall_ms'), model_ms: sum('model_ms'), tool_ms: sum('tool_ms'),
      prompt_tokens: sum('prompt_tokens'), output_tokens: sum('output_tokens'),
      cost_usd: costKnown ? sum('cost_usd') : null,
      wall_ms_per_verified: verified ? sum('solver_wall_ms') / verified : null,
      tokens_per_verified: verified ? (sum('prompt_tokens') + sum('output_tokens')) / verified : null,
      cost_usd_per_verified: costKnown && verified ? sum('cost_usd') / verified : null,
    };
  });
  const report = {
    schema: 'wasm-agent.edit-workflow-experiment/v1', base_commit: baseCommit,
    provider, wasm_provider: wasmProvider, model,
    reasoning: process.env.WASM_AGENT_REASONING || null, lua_root: luaRoot,
    repetitions, comparable_tool_model_surface: comparable,
    note: repetitions < 3
      ? 'Pilot only: fewer than three attempts per arm cannot choose a default.'
      : 'One repository fixture still cannot choose a global default; compare with organic tasks.',
    summary, by_arm: byArm,
  };
  fs.writeFileSync(path.join(root, 'report.json'), JSON.stringify(report, null, 2));
  console.log(JSON.stringify(report, null, 2));
  console.log(`artifacts: ${root}`);
  process.exit(summary.every((row) => row.verified_completion) && comparable ? 0 : 2);
})().catch((error) => {
  fs.writeFileSync(path.join(root, 'fatal.txt'), error.stack || String(error));
  console.error(error.stack || error);
  console.error(`retained artifacts: ${root}`);
  process.exit(1);
});
