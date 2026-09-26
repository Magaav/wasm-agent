#!/usr/bin/env node
// Matched, disposable coding-agent pilot. Only traceDir survives.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import net from 'node:net';
import crypto from 'node:crypto';
import { spawn, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { DUMMY_KEY } from './agent-benchmark-proxy.mjs';

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const checkOnly = process.argv.includes('--check');
const fixtureArgument = process.argv.slice(2).find(arg => arg !== '--check');
const fixturePath = fixtureArgument && path.resolve(fixtureArgument);
if (!fixturePath || !fs.existsSync(fixturePath)) {
  console.error('usage: node scripts/agent-benchmark.mjs [--check] <fixture.json>');
  process.exit(2);
}
const fixture = JSON.parse(fs.readFileSync(fixturePath, 'utf8'));
if (!/^[a-z0-9-]+$/.test(fixture.id || '') ||
    !/^[0-9a-f]{40}$/.test(fixture.source || '') ||
    !/^[0-9a-f]{40}$/.test(fixture.knownFix || '') ||
    !Number.isInteger(fixture.timeLimitSeconds) || fixture.timeLimitSeconds < 60 ||
    fixture.timeLimitSeconds > 1800 || !fixture.prompt || !fixture.model ||
    !fixture.provider || !fixture.image || fixture.oracle !== 'scripts/test-ui.ps1' ||
    !/^[a-zA-Z0-9._/-]+$/.test(fixture.provider) ||
    !/^[a-zA-Z0-9._/-]+$/.test(fixture.model) ||
    !/^[a-zA-Z0-9._-]+$/.test(fixture.reasoning || '') ||
    (fixture.graphTreatment !== undefined &&
      (typeof fixture.graphTreatment !== 'string' || !fixture.graphTreatment.trim() ||
        fixture.graphTreatment.length > 4000)) ||
    (fixture.sharedInstructions !== undefined &&
      (typeof fixture.sharedInstructions !== 'string' ||
        fixture.sharedInstructions.length > 4000))) {
  throw new Error('invalid benchmark fixture');
}
const labels = fixture.graphTreatment ? ['pi', 'wasm', 'wasm-graph'] : ['pi', 'wasm'];

function command(exe, args, options = {}) {
  const run = spawnSync(exe, args, { cwd: repo, encoding: 'utf8', timeout: 30000, ...options });
  if (run.error || run.status !== 0) {
    throw new Error(`${exe} ${args[0]} failed: ${(run.error?.message || run.stderr || run.stdout || `exit ${run.status}`).trim()}`);
  }
  return run.stdout.trim();
}

function keyFromEnvironment() {
  if (process.env.OPENCODE_API_KEY) return process.env.OPENCODE_API_KEY;
  if (process.env.WASM_AGENT_LLM_API_KEY) return process.env.WASM_AGENT_LLM_API_KEY;
  const envPath = path.join(os.homedir(), '.wasm-agent', 'env');
  if (!fs.existsSync(envPath)) return null;
  const line = fs.readFileSync(envPath, 'utf8').split(/\r?\n/)
    .find(x => /^WASM_AGENT_LLM_API_KEY=/.test(x));
  return line ? line.slice(line.indexOf('=') + 1).replace(/^['"]|['"]$/g, '') : null;
}

function archive(ref, destination, selection = []) {
  fs.mkdirSync(destination, { recursive: true });
  const tar = path.join(path.dirname(destination), `source-${crypto.randomUUID()}.tar`);
  try {
    command('git', ['archive', '--format=tar', `--output=${tar}`, ref, ...selection]);
    command('tar', ['-xf', tar, '-C', destination]);
  } finally {
    fs.rmSync(tar, { force: true });
  }
}

function workspace(label, scratch) {
  const dir = path.join(scratch, `work-${label}`);
  archive(fixture.source, dir);
  command('git', ['init', '-q', '-b', 'benchmark'], { cwd: dir });
  command('git', ['config', 'user.name', 'Benchmark'], { cwd: dir });
  command('git', ['config', 'user.email', 'benchmark@localhost'], { cwd: dir });
  command('git', ['add', '-A'], { cwd: dir });
  command('git', ['commit', '-qm', 'pinned source snapshot'], { cwd: dir });
  return { dir, tree: command('git', ['rev-parse', 'HEAD^{tree}'], { cwd: dir }),
    base: command('git', ['rev-parse', 'HEAD'], { cwd: dir }) };
}

async function freePort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.once('error', reject);
    server.listen(0, '127.0.0.1', () => {
      const port = server.address().port;
      server.close(() => resolve(port));
    });
  });
}

async function grade(label, sourceDir, scratch, traceDir) {
  const gradeDir = path.join(scratch, `grade-${label}`);
  archive(fixture.knownFix, gradeDir, [fixture.oracle]);
  fs.cpSync(path.join(sourceDir, 'ui'), path.join(gradeDir, 'ui'), { recursive: true });
  const port = await freePort();
  let clientPort = await freePort();
  while (clientPort === port) clientPort = await freePort();
  const exe = process.platform === 'win32' ? 'powershell' : 'pwsh';
  const output = spawnSync(exe, ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
    path.join(gradeDir, 'scripts', 'test-ui.ps1'), '-Port', String(port),
    '-ClientPort', String(clientPort)], { cwd: gradeDir, encoding: 'utf8',
    timeout: 120000, env: { ...process.env, OPENCODE_API_KEY: '', WASM_AGENT_LLM_API_KEY: '' } });
  const log = `${output.stdout || ''}${output.stderr || ''}${output.error?.message || ''}`;
  fs.writeFileSync(path.join(traceDir, `${label}.oracle.log`), log);
  return { pass: output.status === 0 && /\bok\s+UI structure:/.test(log),
    exit: output.status, error: output.error?.message || null };
}

function benchmarkNetwork(id, token) {
  const name = `wa-bench-${id}`;
  const proxy = `${name}-proxy`;
  command('docker', ['network', 'create', '--internal', name]);
  const script = path.join(repo, 'scripts', 'agent-benchmark-proxy.mjs');
  command('docker', ['run', '-d', '--rm', '--name', proxy, '--network', name,
    '--network-alias', 'model-proxy',
    '--read-only', '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges',
    '--env', 'BENCHMARK_PROXY_API_KEY',
    '--env', `BENCHMARK_PROXY_MAX_SECONDS=${fixture.timeLimitSeconds + 180}`,
    '--mount', `type=bind,source=${script},target=/proxy.mjs,readonly`,
    'node:22-bookworm', 'node', '/proxy.mjs'], {
    env: { ...process.env, BENCHMARK_PROXY_API_KEY: token },
  });
  command('docker', ['network', 'connect', 'bridge', proxy]);
  const inspected = JSON.parse(command('docker', ['inspect', proxy]))[0];
  const ip = inspected.NetworkSettings.Networks[name]?.IPAddress;
  if (!ip) throw new Error('model forwarder has no internal address');
  return { name, proxy, ip };
}

function probeNetwork(network) {
  const script = `Promise.allSettled([
    fetch('http://model-proxy:8080/zen/go/v1/models',{
      headers:{authorization:'Bearer ${DUMMY_KEY}'},signal:AbortSignal.timeout(5000)}),
    fetch('https://raw.githubusercontent.com/Magaav/wasm-agent/main/ui/app.js',
      {signal:AbortSignal.timeout(5000)})
  ]).then(([model,github])=>{
    console.log(JSON.stringify({modelReachable:model.status==='fulfilled',
      modelAuthorized:model.status==='fulfilled' && model.value.status!==401,
      githubReachable:github.status==='fulfilled'}));
  })`;
  const output = command('docker', ['run', '--rm', '--network', network.name,
    'node:22-bookworm', 'node', '-e', script]);
  const result = JSON.parse(output);
  if (!result.modelReachable || !result.modelAuthorized || result.githubReachable) {
    throw new Error('benchmark network fence failed its model/GitHub probe');
  }
  return result;
}

function dockerArgs(label, work, trace, name, network) {
  const args = ['run', '--rm', '--name', name, '--network', network.name,
    '--workdir', '/work', '--read-only',
    '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges', '--pids-limit', '128',
    '--memory', '3g', '--cpus', '2', '--tmpfs', '/tmp:rw,nosuid,nodev,size=512m',
    '--mount', `type=bind,source=${work},target=/work`,
    '--mount', `type=bind,source=${trace},target=/trace`,
    '--env', 'HOME=/tmp/home', '--env', 'GIT_CONFIG_COUNT=1',
    '--env', 'GIT_CONFIG_KEY_0=safe.directory', '--env', 'GIT_CONFIG_VALUE_0=/work'];
  if (label === 'pi') {
    args.push('--env', `OPENCODE_API_KEY=${DUMMY_KEY}`,
      '--env', 'PI_CODING_AGENT_DIR=/tmp/home/.pi/agent');
  } else {
    args.push('--env', `WASM_AGENT_LLM_API_KEY=${DUMMY_KEY}`,
      '--env', 'WASM_AGENT_HOME=/tmp/home',
      '--env', 'WASM_AGENT_LLM_BASE_URL=http://model-proxy:8080/zen/go/v1',
      '--env', `WASM_AGENT_LLM_MODEL=${fixture.model}`,
      '--env', `WASM_AGENT_REASONING=${fixture.reasoning}`,
      '--env', 'WASM_AGENT_MANAGED=0');
  }
  const script = label === 'pi'
    ? `mkdir -p /tmp/home/.pi/agent /trace/session && cp /trace/pi-models.json /tmp/home/.pi/agent/models.json && exec timeout -k 2s ${fixture.timeLimitSeconds}s pi -p --mode json --no-extensions --no-skills --no-prompt-templates --no-themes --approve --provider ${fixture.provider} --model ${fixture.model} --thinking ${fixture.reasoning} --session-dir /trace/session -- "$(cat /trace/prompt.txt)"`
    : `mkdir -p /tmp/home && exec timeout -k 2s ${fixture.timeLimitSeconds}s wa --db /trace/wa.db chat "$(cat /trace/prompt.txt)"`;
  args.push(fixture.image, 'sh', '-lc', script);
  return args;
}

async function runArm(label, work, trace, id, network) {
  const name = `wa-bench-${id}-${label}`;
  fs.mkdirSync(trace, { recursive: true });
  fs.writeFileSync(path.join(trace, 'prompt.txt'), fixture.prompt +
    (fixture.sharedInstructions || '') +
    (label === 'wasm-graph' ? fixture.graphTreatment : ''));
  if (label === 'pi') fs.writeFileSync(path.join(trace, 'pi-models.json'), JSON.stringify({
    providers: { [fixture.provider]: {
      baseUrl: 'http://model-proxy:8080/zen/go/v1', apiKey: DUMMY_KEY,
    } },
  }));
  const out = fs.createWriteStream(path.join(trace, 'stdout.log'));
  const err = fs.createWriteStream(path.join(trace, 'stderr.log'));
  const started = Date.now();
  const env = { ...process.env };
  delete env.OPENCODE_API_KEY;
  delete env.WASM_AGENT_LLM_API_KEY;
  delete env.BENCHMARK_PROXY_API_KEY;
  let timedOut = false;
  const child = spawn('docker', dockerArgs(label, work, trace, name, network), { env, stdio: ['ignore', 'pipe', 'pipe'] });
  child.stdout.pipe(out);
  child.stderr.pipe(err);
  const timer = setTimeout(() => {
    timedOut = true;
    spawnSync('docker', ['stop', '--time', '2', name], { timeout: 15000, encoding: 'utf8' });
    child.kill();
  }, fixture.timeLimitSeconds * 1000);
  const exit = await new Promise(resolve => {
    child.once('error', error => resolve({ code: null, error: error.message }));
    child.once('close', code => resolve({ code, error: null }));
  });
  clearTimeout(timer);
  await Promise.all([new Promise(resolve => out.end(resolve)), new Promise(resolve => err.end(resolve))]);
  spawnSync('docker', ['rm', '--force', name], { timeout: 15000, encoding: 'utf8' });
  const remaining = command('docker', ['ps', '-a', '--filter', `name=^/${name}$`, '--format', '{{.Names}}']);
  return { exit: exit.code, error: exit.error, timedOut, elapsedMs: Date.now() - started,
    containerRemoved: remaining === '', containerName: name };
}

function captureDiff(work, base, trace) {
  command('git', ['add', '-N', '.'], { cwd: work });
  const diff = spawnSync('git', ['diff', '--binary', base], { cwd: work, timeout: 30000 });
  if (diff.error || diff.status !== 0) throw new Error(`cannot capture ${work} diff`);
  fs.writeFileSync(path.join(trace, 'patch.diff'), diff.stdout);
  fs.writeFileSync(path.join(trace, 'git-status.txt'),
    command('git', ['status', '--short'], { cwd: work }) + '\n');
  return { patchBytes: diff.stdout.length };
}

function removeScratch(scratch) {
  const resolved = path.resolve(scratch);
  if (path.dirname(resolved) !== path.resolve(os.tmpdir()) ||
      !/^wa-agent-benchmark-[a-zA-Z0-9]+$/.test(path.basename(resolved))) {
    throw new Error(`unsafe scratch cleanup target: ${resolved}`);
  }
  fs.rmSync(resolved, { recursive: true, force: true });
}

function purgeSecretLeaks(root, token) {
  const removed = [];
  function visit(dir) {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const target = path.join(dir, entry.name);
      if (entry.isDirectory()) visit(target);
      else if (entry.isFile() && fs.readFileSync(target).includes(Buffer.from(token))) {
        fs.unlinkSync(target);
        removed.push(path.relative(root, target));
      }
    }
  }
  visit(root);
  return removed;
}

async function main() {
  command('git', ['cat-file', '-e', `${fixture.source}^{commit}`]);
  command('git', ['cat-file', '-e', `${fixture.knownFix}^{commit}`]);
  if (!checkOnly) command('docker', ['image', 'inspect', fixture.image]);
  const token = checkOnly ? null : keyFromEnvironment();
  if (!checkOnly && !token) throw new Error('OPENCODE_API_KEY is required for this paid trial');
  const id = crypto.randomBytes(5).toString('hex');
  const traceRoot = path.join(os.tmpdir(), `wa-agent-benchmark-traces-${fixture.id}-${id}`);
  const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-agent-benchmark-'));
  fs.mkdirSync(traceRoot);
  const report = { fixture: fixture.id, source: fixture.source, knownFix: fixture.knownFix,
    model: `${fixture.provider}/${fixture.model}`, reasoning: fixture.reasoning,
    limitSeconds: fixture.timeLimitSeconds, promptSha256: crypto.createHash('sha256').update(fixture.prompt).digest('hex'),
    sharedInstructionsSha256: fixture.sharedInstructions &&
      crypto.createHash('sha256').update(fixture.sharedInstructions).digest('hex'),
    graphTreatmentSha256: fixture.graphTreatment &&
      crypto.createHash('sha256').update(fixture.graphTreatment).digest('hex'),
    image: fixture.image, startedAt: new Date().toISOString(), controls: {}, arms: {} };
  let cleanupSafe = true;
  try {
    const baseline = path.join(scratch, 'control-base');
    const fixed = path.join(scratch, 'control-fixed');
    archive(fixture.source, baseline, ['ui']);
    archive(fixture.knownFix, fixed, ['ui']);
    report.controls.baseline = await grade('baseline', baseline, scratch, traceRoot);
    report.controls.knownFix = await grade('known-fix', fixed, scratch, traceRoot);
    if (report.controls.baseline.pass || !report.controls.knownFix.pass) {
      throw new Error('oracle preflight failed: baseline must fail and known repair must pass');
    }
    if (checkOnly) return;
    const workspaces = Object.fromEntries(labels.map(label => [label, workspace(label, scratch)]));
    if (labels.some(label => workspaces[label].tree !== workspaces.pi.tree)) {
      throw new Error('agent starting trees differ');
    }
    report.startTree = workspaces.pi.tree;
    const network = benchmarkNetwork(id, token);
    report.network = { internal: true, fixedDestination: 'opencode.ai:443 via model-proxy:8080',
      probe: probeNetwork(network) };
    const attempts = await Promise.allSettled(labels.map(label =>
      runArm(label, workspaces[label].dir, path.join(traceRoot, label), id, network)));
    if (attempts.some(x => x.status === 'rejected')) {
      throw new Error('an agent container failed to settle: ' +
        attempts.filter(x => x.status === 'rejected').map(x => x.reason.message).join('; '));
    }
    for (const [index, label] of labels.entries()) {
      const run = attempts[index].value;
      const work = workspaces[label];
      report.arms[label] = { ...run,
        ...captureDiff(work.dir, work.base, path.join(traceRoot, label)),
        oracle: await grade(label, work.dir, scratch, traceRoot) };
    }
    cleanupSafe = attempts.every(x => x.value.containerRemoved);
  } catch (error) {
    report.error = error.message;
    throw error;
  } finally {
    if (token) {
      try {
        const leaked = purgeSecretLeaks(traceRoot, token);
        if (leaked.length) {
          report.credentialLeakFilesPurged = leaked;
          report.error = 'real model credential appeared in retained traces; affected files removed';
          process.exitCode = 1;
        }
      } catch (error) {
        report.error = `credential scan failed: ${error.message}`;
        process.exitCode = 1;
      }
    }
    if (!checkOnly) {
      cleanupSafe = true;
      for (const label of labels) {
        const name = `wa-bench-${id}-${label}`;
        spawnSync('docker', ['rm', '--force', name], { timeout: 15000, encoding: 'utf8' });
        const check = spawnSync('docker', ['ps', '-a', '--filter', `name=^/${name}$`,
          '--format', '{{.Names}}'], { timeout: 15000, encoding: 'utf8' });
        if (check.error || check.status !== 0 || check.stdout.trim()) cleanupSafe = false;
      }
      spawnSync('docker', ['rm', '--force', `wa-bench-${id}-proxy`],
        { timeout: 15000, encoding: 'utf8' });
      const proxyCheck = spawnSync('docker', ['ps', '-a', '--filter',
        `name=^/wa-bench-${id}-proxy$`, '--format', '{{.Names}}'],
        { timeout: 15000, encoding: 'utf8' });
      if (proxyCheck.error || proxyCheck.status !== 0 || proxyCheck.stdout.trim()) cleanupSafe = false;
      spawnSync('docker', ['network', 'rm', `wa-bench-${id}`],
        { timeout: 15000, encoding: 'utf8' });
      const networkCheck = spawnSync('docker', ['network', 'inspect', `wa-bench-${id}`],
        { timeout: 15000, encoding: 'utf8' });
      if (networkCheck.status === 0 || networkCheck.error) cleanupSafe = false;
    }
    report.finishedAt = new Date().toISOString();
    report.cleanup = { containersRemoved: cleanupSafe, scratchRemoved: false };
    if (cleanupSafe) {
      removeScratch(scratch);
      report.cleanup.scratchRemoved = true;
    } else {
      report.cleanup.scratchPath = scratch;
    }
    fs.writeFileSync(path.join(traceRoot, 'report.json'), JSON.stringify(report, null, 2) + '\n');
    if (!checkOnly && labels.every(label => report.arms[label])) {
      const python = process.platform === 'win32' ? 'python' : 'python3';
      const summary = spawnSync(python,
        [path.join(repo, 'scripts', 'agent-benchmark-report.py'), traceRoot, fixturePath],
        { encoding: 'utf8', timeout: 30000 });
      if (summary.status === 0) {
        fs.writeFileSync(path.join(traceRoot, 'summary.json'), summary.stdout);
      } else {
        fs.writeFileSync(path.join(traceRoot, 'summary.error.txt'),
          summary.error?.message || summary.stderr || `exit ${summary.status}`);
      }
    }
    console.log(JSON.stringify({ traceRoot, report }, null, 2));
  }
}

main().catch(error => { console.error(`benchmark failed: ${error.message}`); process.exitCode = 1; });
