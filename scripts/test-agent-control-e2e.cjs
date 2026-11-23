// End-to-end proof of agent control on ONE local node, with a mock provider: a master session splits a
// goal into three workers through the ONE API (POST /subagents -> lua/core/agent_control.lua), learns
// what happened through the event stream rather than by polling a model, collects two results as data,
// and cancels the third mid-run - and the cancelled run really ends.
//
// Nothing here touches the fleet: the node is a scratch home, the provider is a local HTTP server, and
// every process this file starts is killed by the file itself.
const fs = require('node:fs');
const os = require('node:os');
const net = require('node:net');
const path = require('node:path');
const http = require('node:http');
const assert = require('node:assert/strict');
const {spawn} = require('node:child_process');
const repo = path.resolve(__dirname, '..');
const wa = path.resolve(process.argv[2] || process.env.WA_BIN || '/home/victor/.local/bin/wa');
// The scratch root. os.tmpdir() on this node is the OPERATOR's own ~/.wasm-agent/tmp (docs/ONEROOT.md),
// so a fixture that took it would write its evidence inside the real node home - exactly what a test must
// never do. That is why /tmp used to be preferred, and the cost was measured on 23/11: one
// /tmp/wa-agent-control-e2e-* directory per run, EVEN WHEN THE ROW PASSED (eight of them on disk), in a
// 16 G tmpfs that filled up three times in one day (scripts/lib/tmp-floor.sh). The runner's own roots come
// first now - it sets WA_TEST_ROOT/GATE_ROOT/TMPDIR inside ONE work directory it deletes at the end
// (scripts/fast.sh) - then TMPDIR, then /tmp. The guard below still refuses any root inside the operator's
// store, whatever was named.
const operatorHome = path.join(os.homedir(), '.wasm-agent');
const preferred = process.env.WA_TEST_ROOT || process.env.GATE_ROOT || process.env.TMPDIR || os.tmpdir();
const keepScratch = process.env.WA_TEST_KEEP_SCRATCH === '1';
const root = fs.mkdtempSync(path.join(preferred, 'wa-agent-control-e2e-'));
if (root.startsWith(operatorHome + path.sep) || root === operatorHome) {
  throw Error('refused: the scratch root is inside the operator node home: ' + root);
}
const home = path.join(root, 'node');
fs.mkdirSync(path.join(home, '.wasm-agent', 'subagent-profiles'), {recursive: true});
let checks = 0, child, provider, hostLog;
const held = new Map(), answers = new Map();
const check = (value, label) => { assert.ok(value, label); checks++; };
const sleep = ms => new Promise(r => setTimeout(r, ms));
async function until(fn, label, timeout = 20000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) { if (await fn()) return; await sleep(50); }
  throw Error('deadline: ' + label);
}
async function listen(server) {
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
  return server.address().port;
}
async function freePort() {
  return new Promise(resolve => {
    const s = net.createServer();
    s.listen(0, '127.0.0.1', () => { const p = s.address().port; s.close(() => resolve(p)); });
  });
}

(async () => {
  try {
    provider = http.createServer((req, res) => {
      let body = '';
      req.on('data', chunk => body += chunk);
      req.on('end', () => {
        let input; try { input = JSON.parse(body); } catch { res.writeHead(400); res.end(); return; }
        const text = (input.messages || []).map(m => typeof m.content === 'string' ? m.content : JSON.stringify(m.content)).join('\n');
        const worker = text.match(/WORKER_[ABC]/)?.[0];
        if (worker) { held.set(worker, res); return; }
        const done = () => {
          if (res.destroyed || res.writableEnded) return;
          res.writeHead(200, {'content-type': 'text/event-stream'});
          res.end('data: ' + JSON.stringify({choices: [{delta: {content: 'MASTER_OK'}, finish_reason: 'stop'}],
            usage: {prompt_tokens: 10, completion_tokens: 2, total_tokens: 12}}) + '\n\ndata: [DONE]\n\n');
        };
        setTimeout(done, 50);
      });
    });
    const modelPort = await listen(provider);
    const port = await freePort();
    fs.writeFileSync(path.join(home, '.wasm-agent', 'subagent-profiles', 'proof-e2e.json'), JSON.stringify({
      schema_version: 1, id: 'proof-e2e', instructions: 'Answer the supplied bounded task.',
      allowed_tools: [], resources: {}, limits: {timeout_seconds: 60, max_output_bytes: 4096, max_tokens: 8000},
    }));
    const clean = Object.fromEntries(Object.entries(process.env)
      .filter(([k]) => !/^(WASM_AGENT_|WA_|OPENAI_|OPENCODE_|MISSION_)/.test(k)));
    const env = {...clean, HOME: root, WASM_AGENT_HOME: home, WASM_AGENT_LUA_ROOT: repo,
      WASM_AGENT_DB: path.join(home, 'memory.db'), WASM_AGENT_RENDEZVOUS: '', WASM_AGENT_RELAY: '',
      WASM_AGENT_MANAGED: '0', WASM_AGENT_LLM_BASE_URL: 'http://127.0.0.1:' + modelPort,
      WASM_AGENT_LLM_API_KEY: 'fixture-only', WASM_AGENT_LLM_MODEL: 'fixture',
      WASM_AGENT_SUBAGENT_CONCURRENCY: '3', WASM_AGENT_SUBAGENT_QUEUE_DEPTH: '4'};
    hostLog = fs.openSync(path.join(root, 'node.log'), 'a');
    child = spawn(wa, ['serve', '--port', String(port), '--client-port', '0', '--ui', path.join(repo, 'ui')],
      {cwd: root, env, stdio: ['ignore', hostLog, hostLog]});
    child.on('error', error => console.error(error));
    const base = 'http://127.0.0.1:' + port;
    const api = async (body) => {
      const response = await fetch(base + '/subagents', {method: 'POST', headers: {'content-type': 'application/json'},
        body: JSON.stringify(body), signal: AbortSignal.timeout(20000)});
      const text = await response.text();
      try { return JSON.parse(text); } catch { throw Error('subagents HTTP' + response.status + ': ' + text); }
    };
    await until(async () => {
      try { return (await fetch(base + '/health', {signal: AbortSignal.timeout(500)})).ok; } catch { return false; }
    }, 'node ready');

    // The master's session: a real parent in this ledger, so the API has an owner and a place to hang the
    // tree. It is created through the node's own chat surface, one turn with the mock provider.
    const parent = 'proof-master';
    const chat = await fetch(base + '/chat', {method: 'POST',
      // No session header: the session does not exist yet, and an unknown credential is 401 by design
      // (measured on the base). The thread name BECOMES the parent session the workers hang under.
      headers: {'content-type': 'application/json', accept: 'text/event-stream'},
      body: JSON.stringify({thread: parent, text: 'split this goal into three workers'}), signal: AbortSignal.timeout(15000)});
    const masterText = await chat.text();
    check(chat.status === 200 && masterText.includes('MASTER_OK'), 'the master session answered: ' + chat.status);

    // 1. The master splits the goal: three workers through the ONE API.
    const workers = [];
    for (const name of ['A', 'B', 'C']) {
      const started = await api({action: 'spawn', parent_session_id: parent, idempotency_key: 'e2e-' + name,
        brief: {prompt: 'WORKER_' + name + ' bounded task', profile: 'proof-e2e'}});
      check(started.id && !started.error, 'worker ' + name + ' admitted: ' + JSON.stringify(started));
      workers.push(started);
    }
    await until(() => held.size === 3, 'three worker inference requests started');
    check([...held.values()].every(r => !r.writableEnded), 'all three workers really run at once');

    // 2. The parent's tree, as one observation: state, rounds, age - what Fleet View draws and the status
    //    bar summarises in one line.
    const tree = await api({action: 'tree', parent_session_id: parent});
    check(tree.children.length === 3, 'the tree lists the three workers: ' + tree.children.length);
    check(tree.children.every(c => c.state === 'running'), 'each worker reads running');
    check(typeof tree.summary === 'string' && tree.summary.length > 0, 'the tree has a one-line summary');
    check(tree.children.every(c => typeof c.age_ms === 'number'), 'each worker carries an age');

    // 3. Events arrive without polling a model: the stream answers from the ledger, and a worker's first
    //    turn is a started event.
    const events = await api({action: 'events', parent_session_id: parent, after: 0});
    check(Array.isArray(events.events), 'the event stream answers with a list');
    check(events.events.some(e => e.kind === 'started' || e.kind === 'done'),
      'events carry named kinds: ' + JSON.stringify(events.events.map(e => e.kind)));

    // 4. One worker is cancelled MID-RUN and its run really ends.
    const victim = workers[2];
    const cancelled = await api({action: 'cancel', id: victim.id});
    check(cancelled.state === 'cancelled' || cancelled.state === 'cancelling',
      'cancel answers with a named state: ' + JSON.stringify(cancelled));
    await until(async () => {
      const status = await api({action: 'status', id: victim.id});
      return status.settled === true && status.state === 'cancelled';
    }, 'the cancelled worker really ended');
    const victimStatus = await api({action: 'status', id: victim.id});
    check(victimStatus.state === 'cancelled', 'the cancelled run ends cancelled, not running');
    const victimHeld = held.get('WORKER_C');
    await sleep(200);
    check(victimHeld.destroyed || victimHeld.writableEnded || victimHeld.socket?.destroyed,
      'the cancelled worker provider call was closed, not left open');

    // 5. The other two finish, and their results are collected AS DATA.
    for (const name of ['WORKER_A', 'WORKER_B']) {
      const response = held.get(name);
      if (response && !response.writableEnded) {
        response.writeHead(200, {'content-type': 'text/event-stream'});
        response.end('data: ' + JSON.stringify({choices: [{delta: {content: 'RESULT_' + name}, finish_reason: 'stop'}],
          usage: {prompt_tokens: 20, completion_tokens: 5, total_tokens: 25}}) + '\n\ndata: [DONE]\n\n');
      }
    }
    for (const worker of workers.slice(0, 2)) {
      let answer = null;
      await until(async () => {
        answer = await api({action: 'collect', id: worker.id});
        if (answer.error === 'child_running') return false;
        if (answer.error) throw Error('collect failed: ' + JSON.stringify(answer));
        return answer.state === 'completed';
      }, 'worker ' + worker.id + ' settles');
      check(answer.state === 'completed', 'a settled worker answers as data');
      if (typeof answer.reply !== 'string' || answer.reply.length === 0) {
        fs.writeFileSync(path.join(root, 'answer-' + worker.id + '.json'), JSON.stringify(answer, null, 2));
      }
      check(typeof answer.reply === 'string' && answer.reply.length > 0,
        'the answer carries its reply: ' + JSON.stringify(answer).slice(0, 600));
      check(Array.isArray(answer.commits) && Array.isArray(answer.failures) && Array.isArray(answer.files),
        'the answer carries commits, files and failures as data');
      check(typeof answer.rounds === 'number' && typeof answer.tokens === 'number', 'the answer carries its cost');
    }

    // 6. The event stream is resumable: a cursor returns only what is after it.
    const first = await api({action: 'events', parent_session_id: parent, after: 0});
    const cursor = first.next_seq || 0;
    const second = await api({action: 'events', parent_session_id: parent, after: cursor});
    check(second.events.every(e => e.seq > cursor), 'a cursor returns only later events');

    const evidence = {schema: 'wasm-agent.agent-control-proof/v1', checks, failed: 0,
      model: 'local-mock', nodes: 1, workers: workers.map(w => w.id)};
    fs.writeFileSync(path.join(root, 'verdict.json'), JSON.stringify(evidence, null, 2));
    console.log('agent-control e2e ok (' + checks + ' checks, one local node, mock provider)');
  } catch (error) {
    fs.writeFileSync(path.join(root, 'verdict.json'), JSON.stringify({schema: 'wasm-agent.agent-control-proof/v1',
      ok: false, checks, failed: 1, error: String(error)}, null, 2));
    console.error(error.stack); process.exitCode = 1;   // the finally below says where the evidence went
  } finally {
    for (const response of held.values()) response.destroy();
    if (child && child.exitCode === null) {
      child.kill();
      await Promise.race([new Promise(r => child.once('exit', r)), sleep(5000)]);
    }
    if (hostLog !== undefined) fs.closeSync(hostLog);
    provider?.closeAllConnections(); provider?.close();
    // THE SCRATCH GOES ON EXIT, PASS OR FAIL (item 2 of the tests-clean-their-tmp round). A failing row's
    // evidence is kept only where the RUNNER owns the directory - inside GATE_ROOT it copies a
    // "kept for diagnosis" tree out before deleting its own work dir - or when the operator asked for it
    // with WA_TEST_KEEP_SCRATCH=1. Anywhere else it is removed here: that is the difference between one
    // directory left per run and none.
    const insideRun = !!process.env.GATE_ROOT && root.startsWith(process.env.GATE_ROOT + path.sep);
    if (keepScratch || (process.exitCode && insideRun)) console.error('fixture kept for diagnosis: ' + root);
    else fs.rmSync(root, {recursive: true, force: true});
  }
})();
