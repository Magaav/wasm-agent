// End-to-end local-subagent test against a local mock model. No paid inference.
//
// The child runs on the runtime's own thread with a fresh interpreter, so this
// proves the real path: durable receipt, await, cancellation that lands on
// provider I/O, queue overflow, ownership and independent transcripts.
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');

const repo = path.resolve(__dirname, '..');
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-subagents-'));
const wa = path.resolve(process.argv[2] || path.join(repo, 'rust/target', 'release', process.platform === 'win32' ? 'wa.exe' : 'wa'));

let checks = 0;
function check(value, label) { assert.ok(value, label); checks++; }

(async () => {
  let child, provider;
  try {
    provider = http.createServer((req, res) => {
      let body = '';
      req.on('data', (chunk) => { body += chunk; });
      req.on('end', () => {
        const isStream = (() => { try { return JSON.parse(body).stream === true; } catch { return false; } })();
        const usage = { prompt_tokens: 12, completion_tokens: 3, total_tokens: 15 };
        const messages = (() => { try { return JSON.parse(body).messages || []; } catch { return []; } })();
        const text = JSON.stringify(messages);
        if (text.includes('SLOW')) {
          res.writeHead(200, { 'content-type': 'text/event-stream' });
          const timer = setInterval(() => {
            if (res.writableEnded) return;
            res.write('data: ' + JSON.stringify({ id: 'slow', choices: [{ delta: { content: '.' } }] }) + '\n\n');
          }, 150);
          res.on('close', () => clearInterval(timer));
          return;
        }
        if (text.includes('DENY') && !messages.some((message) => message.role === 'tool')) {
          // Ask for a tool the profile does not allow. The dispatch must refuse it.
          const call = { index: 0, id: 'deny-call', type: 'function', function: { name: 'bash', arguments: JSON.stringify({ command: 'echo forbidden' }) } };
          if (isStream) {
            res.writeHead(200, { 'content-type': 'text/event-stream' });
            res.end('data: ' + JSON.stringify({ id: 'mock', choices: [{ delta: { tool_calls: [call] }, finish_reason: 'tool_calls' }], usage }) + '\n\ndata: [DONE]\n\n');
          } else {
            res.writeHead(200, { 'content-type': 'application/json' });
            res.end(JSON.stringify({ id: 'mock', choices: [{ message: { role: 'assistant', content: null, tool_calls: [call] }, finish_reason: 'tool_calls' }], usage }));
          }
          return;
        }
        if (isStream) {
          res.writeHead(200, { 'content-type': 'text/event-stream' });
          res.end(
            'data: ' + JSON.stringify({ id: 'mock', choices: [{ delta: { content: 'child-answer-42' }, finish_reason: 'stop' }], usage }) + '\n\n' +
            'data: [DONE]\n\n');
          return;
        }
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ id: 'mock', choices: [{ message: { role: 'assistant', content: 'child-answer-42' }, finish_reason: 'stop' }], usage }));
      });
    });
    await new Promise((resolve) => provider.listen(0, '127.0.0.1', resolve));
    const modelPort = provider.address().port;

    // A record left running by another boot must read `unknown`, never replay.
    const staleDir = path.join(root, 'subagents', 'stale-child');
    fs.mkdirSync(staleDir, { recursive: true });
    fs.writeFileSync(path.join(staleDir, 'record.json'), JSON.stringify({
      id: 'stale-child', owner_user: 'alice', session_id: 's', profile: 'explore',
      state: 'running', settled: false, boot: 'foreign-boot', created_at: 1.0,
    }));

    const env = {
      ...process.env,
      WASM_AGENT_HOME: root,
      WASM_AGENT_SUBAGENT_ROOT: path.join(root, 'subagents'),
      WASM_AGENT_ALLOW_DEV_HOME: '1',
      WASM_AGENT_LUA_ROOT: repo,
      WASM_AGENT_LLM_BASE_URL: 'http://127.0.0.1:' + modelPort,
      WASM_AGENT_LLM_API_KEY: 'fixture-not-a-credential',
      WASM_AGENT_LLM_MODEL: 'fixture',
      WASM_AGENT_RELAY: '',
      WASM_AGENT_RENDEZVOUS: '',
      WA_SCRIPT: path.join(repo, 'scripts/test-subagents-integration.lua'),
    };
    const log = fs.openSync(path.join(root, 'wa.log'), 'a');
    child = spawn(wa, ['--db', path.join(root, 'memory.db')], { env, stdio: ['ignore', log, log], windowsHide: true });
    const code = await new Promise((resolve) => child.on('exit', resolve));
    const out = fs.readFileSync(path.join(root, 'wa.log'), 'utf8');
    check(code === 0, 'the integration script must exit 0, got ' + code + '\n' + out);
    check(out.includes('SUBAGENTS_INTEGRATION_OK'), 'the script must print its verdict\n' + out);
    for (const marker of ['ok-success', 'ok-idempotency', 'ok-isolation', 'ok-cancel', 'ok-overflow', 'ok-result', 'ok-tool-denial', 'ok-restart-unknown']) {
      check(out.includes('MARK ' + marker), 'missing marker ' + marker + '\n' + out);
    }
    // The child's durable record survives on disk with its terminal state.
    const subagentsRoot = path.join(root, 'subagents');
    const records = fs.existsSync(subagentsRoot) ? fs.readdirSync(subagentsRoot) : [];
    check(records.length > 0, 'a child record must be written under the runtime root');
    const completed = records
      .map((id) => path.join(subagentsRoot, id, 'record.json'))
      .filter((file) => fs.existsSync(file))
      .map((file) => JSON.parse(fs.readFileSync(file, 'utf8')))
      .find((record) => record.state === 'completed' && record.result && record.result.reply);
    check(completed && String(completed.result.reply).includes('child-answer'), 'a completed child record must keep its result');
    console.log(`subagents integration ok (${checks} checks; local mock model, no paid inference)\nevidence: ${root}`);
  } catch (error) {
    console.error(error.stack);
    console.error('evidence: ' + root);
    process.exitCode = 1;
  } finally {
    if (child && child.exitCode === null) child.kill();
    provider?.closeAllConnections();
    provider?.close();
  }
})();
