// The lab driver for the tool-choice experiment.
//
//   node scripts/experiment-tool-choice.cjs --arm control --task long-lived --n 3 --provider real
//
// It writes the arm's profile files into a throwaway home, points a fresh node at a
// provider, runs scripts/experiment-tool-choice.lua through the real host, and prints
// the ledger the rig produced. It is not a test and asserts nothing about behaviour -
// it is the instrument. The verdict is the table.
//
// Cost discipline is explicit: every arm profile carries max_tokens and a wall-clock
// bound, so a runaway child stops with a named error instead of a bill. max_cost_usd is
// deliberately not set, because it requires known rates and refuses the start otherwise.
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const { spawn } = require('node:child_process');

const repo = path.resolve(__dirname, '..');
const wa = path.resolve(process.argv[2] && !process.argv[2].startsWith('--') ? process.argv[2]
  : path.join(repo, 'rust/target/release', process.platform === 'win32' ? 'wa.exe' : 'wa'));

function arg(name, fallback) {
  const at = process.argv.indexOf('--' + name);
  return at >= 0 && process.argv[at + 1] ? process.argv[at + 1] : fallback;
}

const arm = arg('arm', 'control');
const task = arg('task', 'long-lived');
const runs = Number(arg('n', '3'));
const profile = arg('profile', arm === 'op' ? 'exp-op' : 'exp-control');
const provider = arg('provider', 'mock');
const model = arg('model', 'deepseek-v4.1-flash');
const label = arg('label', `${arm}-${task}`);

// The profiles are the controlled variable. `exp-control` mirrors the shipped `worker`
// profile exactly (bash, no operation); `exp-op` differs by one tool, which is the
// whole experiment. A read-only arm exists for the navigation question.
const READ_ONLY = ['read', 'read_many', 'grep', 'ls', 'diagnose'];
const PROFILES = {
  'exp-control': {
    schema_version: 1, id: 'exp-control', operator_authorized: true,
    description: 'Experiment control: the shipped worker surface, which has bash but no operation.',
    instructions: 'Do exactly the bounded task you were given, verify it, then stop and report what you did.',
    allowed_tools: [...READ_ONLY, 'write', 'edit', 'bash'], resources: {},
    limits: { max_depth: 0, timeout_seconds: 240, max_output_bytes: 65536, max_tokens: 60000 },
  },
  'exp-op': {
    schema_version: 1, id: 'exp-op', operator_authorized: true,
    description: 'Experiment arm: the worker surface plus the supervised operation tool.',
    instructions: 'Do exactly the bounded task you were given, verify it, then stop and report what you did.',
    allowed_tools: [...READ_ONLY, 'write', 'edit', 'bash', 'operation'], resources: {},
    limits: { max_depth: 0, timeout_seconds: 240, max_output_bytes: 65536, max_tokens: 60000 },
  },
  'exp-explore': {
    schema_version: 1, id: 'exp-explore', operator_authorized: false,
    description: 'Experiment arm: read-only investigation with the code graph.',
    instructions: 'Investigate read-only and report exact file paths and line references.',
    allowed_tools: [...READ_ONLY, 'graph'], resources: {},
    limits: { max_depth: 0, timeout_seconds: 240, max_output_bytes: 65536, max_tokens: 60000 },
  },
  'exp-explore-nograph': {
    schema_version: 1, id: 'exp-explore-nograph', operator_authorized: false,
    description: 'Experiment control: the same read-only investigation without the code graph.',
    instructions: 'Investigate read-only and report exact file paths and line references.',
    allowed_tools: [...READ_ONLY], resources: {},
    limits: { max_depth: 0, timeout_seconds: 240, max_output_bytes: 65536, max_tokens: 60000 },
  },
};

const home = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-experiment-'));
const profilesDir = path.join(home, '.wasm-agent', 'subagent-profiles');
fs.mkdirSync(profilesDir, { recursive: true });
for (const [id, body] of Object.entries(PROFILES)) {
  fs.writeFileSync(path.join(profilesDir, id + '.json'), JSON.stringify(body, null, 2));
}

// The node's own credential source: the same file the running node resolves its provider
// from. Read here, never printed, never written outside the child's environment.
function credential() {
  const auth = JSON.parse(fs.readFileSync(path.join(os.homedir(), '.pi', 'agent', 'auth.json'), 'utf8'));
  return auth['opencode-go'] && auth['opencode-go'].key;
}

async function startProvider() {
  if (provider === 'real') {
    return { base_url: 'https://opencode.ai/zen/go/v1', key: credential(), close: () => {} };
  }
  // A mock that answers immediately: it exists to prove the rig, not to behave.
  let calls = 0;
  const server = http.createServer((req, res) => {
    let body = '';
    req.on('data', (chunk) => { body += chunk; });
    req.on('end', () => {
      calls += 1;
      const usage = { prompt_tokens: 120, completion_tokens: 8, total_tokens: 128 };
      const content = 'MOCK: the task is done.';
      const stream = (() => { try { return JSON.parse(body).stream === true; } catch { return false; } })();
      if (stream) {
        res.writeHead(200, { 'content-type': 'text/event-stream' });
        res.end('data: ' + JSON.stringify({ id: 'mock', choices: [{ delta: { content }, finish_reason: 'stop' }], usage }) + '\n\ndata: [DONE]\n\n');
      } else {
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ id: 'mock', choices: [{ message: { role: 'assistant', content }, finish_reason: 'stop' }], usage }));
      }
    });
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  return { base_url: 'http://127.0.0.1:' + server.address().port, key: 'experiment-not-a-credential',
    close: () => { server.closeAllConnections(); server.close(); } };
}

(async () => {
  const upstream = await startProvider();
  const env = {
    ...process.env,
    WASM_AGENT_HOME: home,
    WASM_AGENT_ALLOW_DEV_HOME: '1',
    WASM_AGENT_LUA_ROOT: repo,
    WASM_AGENT_LLM_BASE_URL: upstream.base_url,
    WASM_AGENT_LLM_API_KEY: upstream.key,
    WASM_AGENT_LLM_MODEL: model,
    WASM_AGENT_RELAY: '',
    WASM_AGENT_RENDEZVOUS: '',
    WASM_AGENT_SUBAGENT_CONCURRENCY: '8',
    WA_SCRIPT: path.join(repo, 'scripts/experiment-tool-choice.lua'),
    WA_EXPERIMENT_ARM: arm, WA_EXPERIMENT_TASK: task,
    WA_EXPERIMENT_N: String(runs), WA_EXPERIMENT_PROFILE: profile,
    WA_EXPERIMENT_DIR: home.replace(/\\/g, '/'),
    WA_EXPERIMENT_INDEX: arg('index', '0'),
  };
  const child = spawn(wa, ['--db', path.join(home, 'memory.db')], { cwd: repo, env, windowsHide: true });
  let out = '';
  const rows = [];
  const done = new Promise((resolve) => {
    const scan = (chunk) => {
      out += chunk;
      const lines = out.split('\n');
      out = lines.pop();
      for (const line of lines) {
        if (line.startsWith('LEDGER ')) { try { rows.push(JSON.parse(line.slice(7))); } catch { /* keep the raw line in the log */ } }
        if (line.startsWith('INDEX ')) console.log('index: ' + line.slice(6));
        if (line.startsWith('EXPERIMENT_DONE')) resolve();
      }
    };
    child.stdout.on('data', scan);
    child.stderr.on('data', scan);
    child.on('exit', resolve);
  });
  const timer = setTimeout(() => child.kill(), Number(arg('timeout_ms', '900000')));
  await done;
  clearTimeout(timer);

  // Liveness is the F1 outcome: the process had to outlive the child, so the file it
  // writes must still be growing *after* the child settled.
  const sizeOf = (file) => { try { return fs.statSync(file).size; } catch { return -1; } };
  const before = rows.map((row) => row.file && sizeOf(row.file));
  await new Promise((resolve) => setTimeout(resolve, 4000));
  rows.forEach((row, index) => {
    if (!row.file) return;
    const after = sizeOf(row.file);
    row.file_bytes_after_settle = before[index];
    row.file_bytes_later = after;
    row.alive_after_settle = before[index] >= 0 && after > before[index];
  });

  if (child.exitCode === null) child.kill();
  upstream.close();

  const dir = path.join(home, 'experiments', label);
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, 'ledger.json'), JSON.stringify(rows, null, 2));

  const count = (row) => (row.tools || []).filter((call) => call.name === 'operation').length;
  console.log(`\n=== ${label} (arm=${arm} task=${task} profile=${profile} provider=${provider} n=${runs}) ===`);
  console.log('run  state      first_tool   calls  operation  tokens  reasoning  alive  errors');
  for (const row of rows) {
    const usage = row.usage || {};
    const tokens = Number(row.tokens_total || 0)
      || (Number(usage.prompt_tokens || usage.prompt || 0) + Number(usage.completion_tokens || usage.output || 0)) || 0;
    console.log([
      String(row.run || '?').padEnd(4),
      String(row.state || row.error || '?').padEnd(10),
      String(row.first_tool || '-').padEnd(12),
      String((row.tools || []).length).padEnd(6),
      String(count(row)).padEnd(10),
      String(tokens).padEnd(7),
      String(row.reasoning_chars || 0).padEnd(10),
      String(row.alive_after_settle === undefined ? '-' : row.alive_after_settle).padEnd(6),
      String((row.errors || []).length),
    ].join('  '));
  }
  console.log(`ledger: ${path.join(dir, 'ledger.json')}`);
  for (const row of rows) {
    if (row.error || row.fatal) console.log('  ! ' + JSON.stringify(row.error || row.fatal));
    for (const error of row.errors || []) console.log('  ! ' + error.slice(0, 140));
  }
  if (!rows.length) console.log('no ledger rows; node output tail:\n' + out.slice(-2000));
  process.exit(0);
})().catch((error) => { console.error(error.stack); process.exit(1); });
