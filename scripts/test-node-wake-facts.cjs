// The node reports its OWN wake state: /health's `wakes`, on a real scratch node.
//
// THE ROW (Fable 24/11, from the live stall). This laptop's node delivered ZERO self-wakes for 2.5 hours
// (15:15Z -> 17:55Z). The tick raised "no such column: run_id" before its claim loop, /health answered "ok" the
// whole time, and the loopback self-wake canary stayed green - because that canary runs a CHILD node with a
// fresh ledger and never sees the live node's tick. Nothing anywhere said the loop was dead.
//
//   (a) healthy: a due wake is scheduled through the model's own `wake` tool, the node dispatches it, and
//       /health reports `wakes.known`, `last_tick.outcome === "ok"`, nothing left due, and a dispatch time.
//   (b) broken:  a column the tick reads is dropped from the node's OWN ledger (the shape of the stall: a
//       column the code reads and the ledger does not have). A due wake is then left waiting, and /health must
//       name `selfloop_tick_failed` BY NAME with that column in the error, keep the row dispatchable, and show
//       the oldest dispatchable age GROWING while nothing is delivered.
//
// Red on the code before the change: there is no `wakes` field at all, so (a) fails on its first assertion.
//
// Nothing here touches the operator's node. The home is scratch and refuses to be ~/.wasm-agent (the four
// refusals of scripts/lib/scratch-home.sh, restated below), the vault variables go with the env filter, the
// provider is a local stub, and no live fleet is called.
const fs = require('fs'), path = require('path'), assert = require('assert/strict');
const { spawnSync } = require('child_process');
// THE HARNESS IS SHARED (scripts/lib/scratch-node.cjs): the scratch-home refusals, the tree's own binary, a stub
// provider and a real node. scripts/test-health-wakes-rule.cjs uses the same one, so the two rows cannot disagree
// about what a scratch node is.
const H = require('./lib/scratch-node.cjs');

const root = H.repoRoot();
const sleep = H.sleep;
const until = H.until;


const BIN = H.resolveBinary();
// WA_WAKE_FACTS_KEEP=1 keeps this run's node, ledger and /health bodies: the bodies are what the rule the
// readers run is judged on, and a rule quoted in a report is worth nothing against a fixture somebody
// wrote by hand.
const keep = process.env.WA_WAKE_FACTS_KEEP === '1';
const home = fs.mkdtempSync(path.join(H.scratchRoot(), 'wa-wake-facts-'));
H.guardHome(home);
const db = path.join(home, 'node.db');
const evidence = (line) => console.log('  ' + line);

let node = null, mock = null;
// The extra nodes this row starts (each cold-start scenario gets its own home, so one scenario cannot be judged
// on another's ledger). They are closed in the same `finally` as the main one.
const extras = [];
let wakeTurns = 0;

/// The shipped judge on one body. The node is a SEPARATE process, so a synchronous spawn here cannot deadlock it.
function judgeBody(body, env) {
  const result = spawnSync('bash', ['-c', '. "$1/scripts/lib/health-wakes.sh"; wa_health_wakes_verdict', '_', root], {
    input: JSON.stringify(body), encoding: 'utf8', env: { ...process.env, ...(env || {}) },
  });
  return { rc: result.status, lines: String(result.stdout || '').split('\n').map((l) => l.trim()).filter(Boolean) };
}

/// ARM ONE ROW THAT CAME DUE TEN MINUTES AGO, through the product's own `schedule` and its own test clock: the row
/// is the node's, only its time is moved - which is exactly the state an install leaves behind (rows that came due
/// while the node was down). The session is real, so the row can really be dispatched.
function armOldDueRow(homeDir, dbPath) {
  const script = path.join(homeDir, 'arm-old-row.lua');
  fs.writeFileSync(script, [
    "local json = dofile('lua/vendor/json.lua')",
    "local function decode(raw) if type(raw) == 'string' then return json.decode(raw) end return raw end",
    "local selfloop = dofile('lua/core/selfloop.lua')",
    'selfloop.setup()',
    "local rows = decode(host.sql_query('SELECT id FROM sessions ORDER BY rowid DESC LIMIT 1', '[]'))",
    "if not rows or #rows == 0 then print('sessions=0'); os.exit(1) end",
    'local sid = tostring(rows[1].id)',
    'local now = tonumber(host.now())',
    // A REAL ROW OF THE PRODUCT'S OWN TABLE (the columns it requires, the session the node made, a reason the tick
    // recognises), aged ten minutes: `selfloop.schedule` refuses from a -\-db process (it is routed to the component),
    // so the fixture writes the row the scheduler would have written while the node was down.
    "local id = 'cold-start-row-' .. tostring(math.floor(now))",
    "local wrote = decode(host.sql_exec([=[INSERT INTO self_wakes (id, owner, session_id, status, reason, prompt, due_at, created_at, updated_at, attempts) VALUES (?, 'master', ?, 'pending', 'cold-start-row', '', ?, ?, ?, 0)]=], json.encode({ id, sid, now - 600, now - 600, now - 600 })))",
    "if wrote and wrote.error then print('insert_error=' .. tostring(wrote.error)); os.exit(1) end",
    "print('session=' .. sid .. ' wake=' .. id)",
    "local got = decode(host.sql_query('SELECT status, due_at FROM self_wakes WHERE id=?', json.encode({id})))[1]",
    "print('status=' .. tostring(got and got.status) .. ' due_age_s=' .. tostring(got and math.floor(now - tonumber(got.due_at))))",
  ].join('\n') + '\n');
  const result = spawnSync(BIN, ['--db', dbPath], {
    cwd: homeDir, encoding: 'utf8', env: H.nodeEnv(homeDir, mock.address().port, { WA_SCRIPT: script }),
  });
  if (result.status !== 0) throw new Error('the old due row could not be armed: ' + String(result.stderr || result.stdout).slice(0, 600));
  evidence('armed: ' + String(result.stdout).trim().replace(/\n/g, ' | '));
  assert.match(String(result.stdout), /due_age_s=(59\d|60\d)/, 'the row is not ten minutes old: ' + result.stdout);
  return String(result.stdout);
}

/// Take a column out of a scratch ledger through the product's own sql host (the fixture the facts row uses).
function dropColumnIn(homeDir, dbPath, column) {
  const script = path.join(homeDir, 'drop-' + column + '.lua');
  fs.writeFileSync(script, [
    "local json = dofile('lua/vendor/json.lua')",
    "local function decode(raw) if type(raw) == 'string' then return json.decode(raw) end return raw end",
    "local selfloop = dofile('lua/core/selfloop.lua')",
    'selfloop.setup()',
    "local answer = decode(host.sql_exec('ALTER TABLE self_wakes DROP COLUMN " + column + "', '[]'))",
    "print('drop=" + column + "=' .. tostring(answer and answer.error or 'ok'))",
  ].join('\n') + '\n');
  const result = spawnSync(BIN, ['--db', dbPath], {
    cwd: homeDir, encoding: 'utf8', env: H.nodeEnv(homeDir, mock.address().port, { WA_SCRIPT: script }),
  });
  if (result.status !== 0) throw new Error('the column ' + column + ' could not be dropped: ' + String(result.stderr || result.stdout).slice(0, 500));
  evidence('dropped: ' + String(result.stdout).trim());
}

/// A cold node whose ledger carries a row that came due during its downtime: the reader verify-install.sh runs must
/// WAIT for the first tick and pass, never a red in between - and with the column the tick reads dropped, the same
/// cold start must name selfloop_tick_failed inside the bound.
async function coldStart({ name, broken }) {
  const homeDir = fs.mkdtempSync(path.join(H.scratchRoot(), 'wa-wake-' + name + '-'));
  H.guardHome(homeDir);
  const dbPath = path.join(homeDir, 'node.db');
  let cold = await H.startNode({ bin: BIN, home: homeDir, db: dbPath, providerPort: mock.address().port });
  extras.push(cold);
  const chat = await cold.get('/chat', { text: 'hello', thread: 'cold-start' });
  assert(!chat.error, 'the session-creating turn failed: ' + JSON.stringify(chat).slice(0, 300));
  await cold.close();
  extras.pop();
  // ARM THE ROW FIRST, THEN TAKE THE COLUMN: the arm itself writes the ledger, and a column taken first could
  // (rightly) refuse the write that creates the state this scenario is about.
  armOldDueRow(homeDir, dbPath);
  if (broken) dropColumnIn(homeDir, dbPath, broken);

  const restartAt = Date.now();
  cold = await H.startNode({ bin: BIN, home: homeDir, db: dbPath, providerPort: mock.address().port });
  extras.push(cold);
  // JUDGED FROM THE FIRST ANSWER IT GIVES: every verdict until it settles is recorded, so "never a red in between"
  // is a measurement and not a claim.
  const seen = [];
  let settled = null;
  for (;;) {
    const body = await cold.health();
    const verdict = judgeBody(body);
    seen.push(verdict.rc);
    if (verdict.rc === 1 || verdict.rc === 2) { settled = verdict; break; }
    if (verdict.rc === 0) { settled = verdict; break; }
    if (Date.now() - restartAt > 20000) throw new Error('the cold node never settled: ' + JSON.stringify(seen));
    await sleep(250);
  }
  // AND THE SHIPPED READER, on the same cold node: the function verify-install.sh calls, with its bound.
  const reader = spawnSync('bash', ['-c', '. "$1/scripts/lib/health-wakes.sh"; wa_health_wakes_wait "$2" 10', '_', root, String(cold.port)], { encoding: 'utf8' });
  const readerElapsed = Date.now() - restartAt;
  return { homeDir, dbPath, node: cold, seen, settled, reader, readerElapsed, port: cold.port };
}
let scheduledAt = 0;
// One tool call per instruction: the agent's own guard stops a turn that repeats the same call with no new
// observation, and a stub that always answers "call wake" is exactly that loop.
const armed = new Set();


// A stub provider: the turn that asks for a wake gets the `wake` tool call, a wake turn is counted, and
// everything else is answered. No account, no paid inference, no network beyond 127.0.0.1.
// The stub's answers: the turn that asks for a wake gets the `wake` tool call, a wake turn is counted, and
// everything else is answered. No account, no paid inference, no network beyond 127.0.0.1.
function mockAnswer(body) {
  const last = String(body.messages?.filter((m) => m.role === 'user').at(-1)?.content || '');
  if (last.includes('[self-wake')) {
    wakeTurns++;
    return { message: { role: 'assistant', content: 'wake turn' }, finish: 'stop' };
  }
  const due = last.match(/schedule a wake due (now|in (\d+) seconds?)/);
  if (due && !armed.has(last)) {
    armed.add(last);
    const seconds = due[2] ? Number(due[2]) : 0;
    scheduledAt = Math.floor(Date.now() / 1000);
    return { finish: 'tool_calls', message: {
      role: 'assistant', content: '',
      tool_calls: [{ id: 'wake-' + seconds, type: 'function',
        function: { name: 'wake', arguments: JSON.stringify({ reason: 'wake-facts-row', in_seconds: seconds }) } }],
    } };
  }
  return { message: { role: 'assistant', content: 'finished' }, finish: 'stop' };
}

(async () => {
  try {
    mock = await H.startMock(mockAnswer);
    node = await H.startNode({ bin: BIN, home, db, providerPort: mock.address().port });
    const get = node.get;
    const health = node.health;
    const capture = async (name) => { if (keep) fs.writeFileSync(path.join(home, 'health-' + name + '.json'), JSON.stringify(await health())); };
    const wakes = async () => (await health()).wakes;


    // ---- (a) HEALTHY: a due wake scheduled by the model's own tool, dispatched by the node's own tick -------
    const first = await get('/chat', { text: 'schedule a wake due now', thread: 'wake-facts' });
    assert(!first.error, 'the scheduling turn failed: ' + JSON.stringify(first).slice(0, 400));
    assert.equal(await until(async () => wakeTurns >= 1, 'the wake turn never ran', 60000), true, 'no wake turn');

    const healthy = await until(async () => {
      const w = await wakes();
      if (!w || w.known !== true) return null;
      if (w.last_tick?.outcome !== 'ok') return null;
      if (!(w.due === 0) || !(w.dispatchable === 0)) return null;
      if (!w.last_dispatch_at) return null;
      return w;
    }, 'a healthy node never reported a dispatched wake: ' + JSON.stringify(await wakes()), 90000);
    assert.equal(healthy.last_tick.outcome, 'ok', 'last tick outcome on a healthy node: ' + JSON.stringify(healthy));
    assert(Number(healthy.last_tick.at) > 0, 'last_tick.at was not a time: ' + JSON.stringify(healthy.last_tick));
    assert(Math.abs(Number(healthy.last_tick.at) - Math.floor(Date.now() / 1000)) < 120,
      'last_tick.at is not recent: ' + JSON.stringify(healthy.last_tick));
    assert(Number(healthy.last_dispatch_at) >= scheduledAt - 1,
      'the dispatch predates this test\'s own schedule: ' + JSON.stringify(healthy));
    assert.equal(Number(healthy.due), 0, 'a dispatched one-shot wake stayed due: ' + JSON.stringify(healthy));
    assert.equal(Number(healthy.dispatchable), 0, 'a dispatched wake stayed dispatchable: ' + JSON.stringify(healthy));
    await capture('healthy');
    evidence('healthy: last_tick ok at ' + healthy.last_tick.at + ', dispatched at ' + healthy.last_dispatch_at
      + ', due ' + healthy.due + ', dispatchable ' + healthy.dispatchable + ', published_age_ms ' + healthy.published_age_ms);

    // ---- (b) BROKEN: a column the tick reads is dropped, as the ledger in the stall did ------------------
    // The row is armed BEFORE the column goes, because arming it is a write that names the column; it is due a
    // few seconds later, which is exactly when the tick tries to claim it and cannot.
    const armed = await get('/chat', { text: 'schedule a wake due in 5 seconds', thread: 'wake-facts' });
    assert(!armed.error, 'the second scheduling turn failed: ' + JSON.stringify(armed).slice(0, 400));

    const drop = path.join(home, 'drop-boot.lua');
    fs.writeFileSync(drop, [
      "local json = dofile('lua/vendor/json.lua')",
      "local function decode(raw) if type(raw) == 'string' then return json.decode(raw) end return raw end",
      "local selfloop = dofile('lua/core/selfloop.lua')",
      'selfloop.setup()',
      "local before = decode(host.sql_query('PRAGMA table_info(self_wakes)', '[]'))",
      "local named = false",
      "for _, row in ipairs(before) do if tostring(row.name) == 'boot' then named = true end end",
      "print('columns_before=' .. #before .. ' boot=' .. tostring(named))",
      "local answer = decode(host.sql_exec('ALTER TABLE self_wakes DROP COLUMN boot', '[]'))",
      "print('drop=' .. tostring(answer and answer.error or 'ok'))",
      "local after = decode(host.sql_query('PRAGMA table_info(self_wakes)', '[]'))",
      "local names = {}",
      "for _, row in ipairs(after) do names[#names + 1] = tostring(row.name) end",
      "local gone = true",
      "for _, name in ipairs(names) do if name == 'boot' then gone = false end end",
      "print('columns_after=' .. #after .. ' boot_gone=' .. tostring(gone))",
      'if not gone then os.exit(1) end',
    ].join('\n') + '\n');
    const dropped = spawnSync(BIN, ['--db', db], {
      cwd: home, encoding: 'utf8', env: H.nodeEnv(home, mock.address().port, { WA_SCRIPT: drop }),
    });
    console.log(dropped.stdout.trim());
    if (dropped.status !== 0) throw Error('the ledger column could not be dropped: ' + dropped.stderr.slice(0, 600));
    assert(/boot_gone=true/.test(dropped.stdout), 'the column the tick reads is still there: ' + dropped.stdout);

    const droppedAt = Date.now();
    const broken = await until(async () => {
      const w = await wakes();
      if (!w || w.known !== true) return null;
      if (w.last_tick?.outcome !== 'selfloop_tick_failed') return null;
      if (!(Number(w.dispatchable) >= 1)) return null;
      return w;
    }, 'the broken node never named selfloop_tick_failed: ' + JSON.stringify(await wakes()), 40000);
    // TWO TICKS, NOT TWO MINUTES: the node's tick is 2 s, so a row that becomes due is claimed or reported by
    // the next one. The wait above starts at the drop and the row is due 5 s after it was armed, so anything
    // past ~8 s would mean the state is read from somewhere slower than the loop that produces it.
    const noticedMs = Date.now() - droppedAt;
    assert(noticedMs < 12000, 'the failure took ' + noticedMs + ' ms to appear in /health');
    assert.equal(broken.last_tick.outcome, 'selfloop_tick_failed', 'outcome: ' + JSON.stringify(broken));
    assert(String(broken.last_tick.error).includes('no such column: boot'),
      'the failure does not name the column it raised on: ' + JSON.stringify(broken.last_tick));
    const before = Number(broken.oldest_dispatchable_age_s);
    assert(Number.isFinite(before), 'no oldest dispatchable age while a row waits: ' + JSON.stringify(broken));
    evidence('broken: outcome ' + broken.last_tick.outcome + ' (' + broken.last_tick.error + '), dispatchable '
      + broken.dispatchable + ', oldest age ' + before + 's, named ' + noticedMs + ' ms after the column went');

    const turns = wakeTurns;
    await sleep(6000);
    const later = await wakes();
    assert.equal(later.last_tick.outcome, 'selfloop_tick_failed',
      'the failure did not persist across ticks: ' + JSON.stringify(later.last_tick));
    assert(Number(later.oldest_dispatchable_age_s) >= before + 3,
      'the oldest dispatchable age did not grow with the wall clock while nothing was delivered: '
      + before + ' -> ' + JSON.stringify(later.oldest_dispatchable_age_s));
    assert.equal(wakeTurns, turns, 'a wake was delivered while the tick was broken');
    const alive = await health();
    assert(alive.ok !== undefined, '/health stopped answering while the tick was broken');
    await capture('broken');
    evidence('broken: still due and growing, oldest age ' + later.oldest_dispatchable_age_s + 's, published_age_ms '
      + later.published_age_ms + ', /health ok=' + alive.ok + ' (the node looks alive: that is the blindness)');

    // ---- (c) A COLD START WITH A ROW THAT CAME DUE DURING THE INSTALL ------------------------------------
    // THE FALSE RED THIS FIXES: right after a restart the old stall rule is TRUE of a normal node - rows that came
    // due while the node was down are minutes old, the lane is idle, and the first tick has not dispatched yet - so
    // an install would have failed a good build. The rule now counts a row's age from THIS process's first tick,
    // and the reader waits for that tick instead of judging its absence.
    const cold = await coldStart({ name: 'cold' });
    cold.seen.forEach((rc) => assert(rc === 0 || rc === 3,
      'a red appeared during a good cold start: verdicts ' + JSON.stringify(cold.seen)));
    assert.equal(cold.settled.rc, 0, 'the cold node never went green: ' + JSON.stringify(cold.settled.lines));
    assert.match(cold.settled.lines[0], /0 dispatchable/, 'the ten-minute-old row was not dispatched: ' + cold.settled.lines[0]);
    assert.equal(cold.reader.status, 0, "verify-install's reader failed a good cold start: " + JSON.stringify(cold.reader.stdout));
    evidence('cold start: verdicts ' + JSON.stringify(cold.seen) + ' then ' + cold.settled.lines[0]);
    evidence('cold start: the shipped reader said "' + String(cold.reader.stdout).trim() + '" ' + cold.readerElapsed + ' ms after the restart');

    // ---- (d) THE SAME COLD START WITH THE COLUMN THE TICK READS GONE: RED, BY NAME, INSIDE THE BOUND ----
    const brokenCold = await coldStart({ name: 'cold-broken', broken: 'boot' });
    assert.equal(brokenCold.settled.rc, 1, 'a cold start whose tick cannot run was not red: ' + JSON.stringify(brokenCold.settled));
    assert.match(brokenCold.settled.lines.join(' '), /RED selfloop_tick_failed: .*no such column: boot/,
      'the cold red does not name the column the tick raised on: ' + JSON.stringify(brokenCold.settled.lines));
    assert.equal(brokenCold.reader.status, 1, "verify-install's reader passed a node whose tick cannot run: " + JSON.stringify(brokenCold.reader.stdout));
    assert.match(String(brokenCold.reader.stdout), /RED selfloop_tick_failed: .*no such column: boot/,
      'the reader did not name the red: ' + String(brokenCold.reader.stdout));
    assert(brokenCold.readerElapsed < 14000, 'the red took longer than the bound: ' + brokenCold.readerElapsed + ' ms');
    evidence('cold start with boot dropped: ' + JSON.stringify(brokenCold.seen) + ' then ' + brokenCold.settled.lines[0]);

    console.log('node wake facts ok (a real scratch node reports its own tick: healthy dispatch named ok, and a '
      + 'dropped column named selfloop_tick_failed with the oldest dispatchable age growing, no paid turn)');
  } finally {
    for (const extra of extras) await extra.close();
    if (node) await node.close();
    if (mock) { mock.closeAllConnections(); await new Promise((r) => mock.close(r)); }
    if (process.exitCode || keep) console.log('evidence: ' + home);
    else fs.rmSync(home, { recursive: true, force: true });
  }
})().catch((e) => { console.error(e); process.exitCode = 1; });
