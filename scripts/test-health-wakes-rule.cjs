// THE SELF-WAKE RULE, row by row, on a REAL scratch node (r8c item G, approved 24/11).
//
// The rule says a node's own wake state is RED by name when any of these holds, and every reader of
// /health.wakes runs the SAME judge (scripts/lib/health-wakes.sh; the product watchdog has the same rule in
// rust/wa-watchdog/src/health.rs, tested against these bodies):
//
//   wakes_unknown          the node cannot say what its wake state is (known != true, or no wakes at all),
//                          or a field the rule reads is MISSING (the line names the field), or
//                          node_state.state is a name the rule does not know
//   selfloop_tick_failed   the last tick raised, and the line carries the error it raised
//   self_wake_stalled      a due, unheld row is older than the bound with NO TURN RUNNING - and its age is
//                          counted from this process's first tick, so a row that came due during an install
//                          is not a stall in the seconds after the restart
//   wakes_not_publishing   the facts have not been republished past the bound
//
// AND ONE VERDICT THAT IS NOT A RED: WAITING (rc 3) - no tick has published since this node started. An
// install judges exactly there, so verify-install.sh WAITS (bounded) instead of failing a good install; what
// it finds after the bound is judged, and a node that never publishes is an UNKNOWN, which is a failure.
//
// WHY THIS ROW IS NOT A COPY OF THE RULE: it spawns a real node, puts that node into each state, and asks the
// SHIPPED judge - `scripts/lib/health-wakes.sh` for the shell readers, and `scripts/verify-install.sh` (the
// post-install check) end to end - what it says. A row that re-implemented the rule in JavaScript would pass
// while the shipped judge was wrong.
//
// The states, and how each is reached on a live node:
//   GREEN                 a wake was scheduled and dispatched by the node's own tick (nothing is red)
//   selfloop_tick_failed  a column the tick reads (`boot`) dropped from the node's own ledger
//   self_wake_stalled     the same broken node, with the stall bound set to 3 s so the row takes seconds
//                         instead of the shipped 120 s: the same judge, the same body, the same idle lane
//   wakes_unknown         a column `wake_facts` reads (`attempts`) dropped: the node says it cannot say
//   wakes_not_publishing  A REAL BODY WITH ONE FIELD AGED, and the row says so: a working node republishes
//                         every 2 s, so the only way to make its answer 41 s old is to age the answer. The rule
//                         is judged on the real body's every other field (known, outcome, dispatchable, lane).
//
// Run by scripts/test.sh beside the facts row. It refuses to run on the operator's store and touches no live
// node: scratch HOME, WASM_AGENT_HOME/DATA/DB, its own ports, a stub provider, the vault variables cleared.
const fs = require('fs'), path = require('path'), assert = require('assert/strict');
const http = require('http');
const { spawnSync, spawn } = require('child_process');
const H = require('./lib/scratch-node.cjs');

const root = H.repoRoot();
const BIN = H.resolveBinary();
const home = fs.mkdtempSync(path.join(H.scratchRoot(), 'wa-wakes-rule-'));
H.guardHome(home);
const db = path.join(home, 'node.db');
const keep = process.env.WA_WAKES_RULE_KEEP === '1';
let node = null, mock = null, wakeTurns = 0;
// One tool call per instruction: the agent's own guard stops a turn that repeats the same call with no new
// observation, and a stub that always answers "call wake" is exactly that loop.
const armed = new Set();
const note = (line) => console.log('  ' + line);

/// The shipped judge, on one body, with optional bounds. Returns { lines, rc }.
function judge(body, env) {
  const result = spawnSync('bash', ['-c', '. "$1/scripts/lib/health-wakes.sh"; wa_health_wakes_verdict', '_', root], {
    input: JSON.stringify(body), encoding: 'utf8',
    env: { ...process.env, ...(env || {}) },
  });
  if (result.error) throw result.error;
  const lines = String(result.stdout || '').split('\n').map((l) => l.trim()).filter(Boolean);
  return { lines, rc: result.status, stderr: String(result.stderr || '') };
}

/// The node's /health as BYTES: the judge reads bytes, and `JSON.stringify(parsed)` would be this row's own
/// serialisation rather than the node's answer (the single-key counts below are about the node's bytes).
function rawHealth() {
  return new Promise((resolve, reject) => {
    http.get({ host: '127.0.0.1', port: node.port, path: '/health', timeout: 6000 }, (res) => {
      let text = '';
      res.setEncoding('utf8');
      res.on('data', (chunk) => (text += chunk));
      res.on('end', () => resolve(text));
    }).on('error', reject).on('timeout', function () { this.destroy(new Error('/health timed out')); });
  });
}

/// A JSON body of the shape `wakes_health()` answers BEFORE the first placement tick (rust/wa-capabilities/src/
/// serve.rs), on a real body the node answered. Used where a real cold node would take a restart to reach.
function asWaiting(body) {
  const copy = JSON.parse(JSON.stringify(body));
  copy.wakes = { known: false, reason: 'wakes_not_reported_yet', note: 'no placement tick has published wake facts since this node started' };
  return copy;
}

/// The same rule as the report states it in jq, for the machines that have jq: the two must agree on every
/// body this row judges, or one of them has drifted.
function jqVerdict(body, env) {
  const program = [
    '(.wakes // null) as $w | (.node_state.state // "") as $lane | (.worker // "") as $worker',
    '| def stall: ($ENV.WA_WAKES_STALL_SECONDS // 120 | tonumber);',
    '  def publish: ($ENV.WA_WAKES_PUBLISH_SECONDS // 30 | tonumber);',
    '  def red($t): "RED " + $t | halt_error(1);',
    '  def unknown($t): red("wakes_unknown: " + $t);',
    '  def waiting($t): "WAITING wakes: " + $t | halt_error(3);',
    '  def num($k): (($w|has($k)) and (($w[$k]|type) == "number"));',
    '  if $w == null then ("UNKNOWN wakes: /health has no wakes object (a node older than this rule, or a body that is not one)" | halt_error(2))',
    '  elif ($w|type) != "object" then unknown("/health.wakes is not an object")',
    '  elif ($w|has("known")|not) then unknown("known is missing from /health.wakes")',
    '  elif $w.known != true then',
    '    (if $w.reason == "wakes_not_reported_yet"',
    '     then waiting("no tick has published wake facts since this node started (wakes_not_reported_yet)")',
    '     else red("wakes_unknown: \\($w.reason // "no reason given")\\(if ($w.error // "") != "" then " (\\($w.error))" else "" end)") end)',
    '  elif ($w.last_tick|type) != "object" then unknown("last_tick is missing from /health.wakes")',
    '  elif ($w.last_tick|has("outcome")|not) then unknown("last_tick.outcome is missing")',
    '  elif $w.last_tick.outcome == "selfloop_tick_failed" then red("selfloop_tick_failed: \\($w.last_tick.error // "no error recorded")")',
    '  elif $w.last_tick.outcome != "ok" then unknown("last_tick outcome \\($w.last_tick.outcome)")',
    '  elif (num("ticks_since_start")|not) then unknown("ticks_since_start is missing from /health.wakes")',
    '  elif (num("ticking_for_s")|not) then unknown("ticking_for_s is missing from /health.wakes")',
    '  elif (num("published_age_ms")|not) then unknown("published_age_ms is missing from /health.wakes")',
    '  elif (num("dispatchable")|not) then unknown("dispatchable is missing from /health.wakes")',
    '  elif (num("oldest_dispatchable_age_s")|not) then unknown("oldest_dispatchable_age_s is missing from /health.wakes")',
    '  elif $w.ticks_since_start == 0 then waiting("the node published a tick count of 0 (no tick since it started)")',
    '  elif $lane == "" then unknown("node_state.state is missing from /health")',
    '  elif (["idle","busy","upgrading"]|index($lane)) == null then unknown("node_state.state " + ($lane|tojson) + " is not a name this rule knows (idle, busy, upgrading)")',
    '  elif $worker == "" then unknown("worker is missing from /health")',
    '  elif $w.published_age_ms > (publish * 1000) then red("wakes_not_publishing: \\($w.published_age_ms) ms old (bound \\(publish)s)")',
    '  else',
    '    (([$w.dispatchable - ($w.deploy_waiting // 0), 0] | max)) as $not_held',
    '    | ([$w.oldest_dispatchable_age_s, $w.ticking_for_s] | min) as $age',
    '    | (($lane != "busy") or ($worker == "stalled")) as $no_turn',
    '    | if ($not_held > 0 and $age > stall and $no_turn)',
    '      then red("self_wake_stalled: \\($not_held) due row(s) the node is not holding, oldest \\($age)s (counted from this process, \\($w.ticking_for_s)s), lane \\($lane)")',
    '      else "GREEN wakes: last_tick ok, \\($w.dispatchable) dispatchable (\\($w.deploy_waiting // 0) held for a deploy), oldest \\($w.oldest_dispatchable_age_s)s, ticking \\($w.ticking_for_s)s, lane \\($lane), worker \\($worker)"',
    '      end',
    '  end',
  ].join('\n');
  const result = spawnSync('jq', ['-r', program], { input: JSON.stringify(body), encoding: 'utf8', env: { ...process.env, ...(env || {}) } });
  if (result.error) return null; // no jq on this machine: the cross-check is SKIPPED, never passed
  // halt_error writes its line to STDERR (a RED is an error's sentence; a GREEN is ordinary output), so the
  // verdict is whichever of the two the form produced.
  return { text: String(result.stdout || '').trim() || String(result.stderr || '').trim(), rc: result.status,
    stderr: String(result.stderr || '').trim() };
}

/// The post-install check, end to end: `scripts/verify-install.sh --json` against this scratch node. Only the
/// self-wake rows are read out of it - the checks about an install's files are somebody else's row.
function verifyInstall() {
  const result = spawnSync('bash', [path.join(root, 'scripts/verify-install.sh'), '--json'], {
    encoding: 'utf8', cwd: home,
    env: { ...process.env, HOME: home, WASM_AGENT_HOME: home, WA_INSTALL_DIR: path.join(home, 'install'),
      WA_PORT: String(node.port), WASM_AGENT_LUA_ROOT: root },
  });
  const text = String(result.stdout || '').trim();
  const line = text.split('\n').filter((l) => l.startsWith('{')).pop();
  if (!line) throw new Error('verify-install.sh printed no JSON: ' + text.slice(0, 400) + String(result.stderr || '').slice(0, 400));
  const report = JSON.parse(line);
  return report.results.filter((row) => row.name === 'the self-wake loop');
}

// Take a column away from the node's OWN ledger, through the product's own sql host and after the product's own
// setup has run (so the row also shows setup does not add it back). An index that covers the column goes first:
// SQLite refuses to drop a column an index names, and a ledger old enough to lack the column lacks the index too.
function dropColumn(column, index) {
  const script = path.join(home, 'drop-' + column + '.lua');
  fs.writeFileSync(script, [
    "local json = dofile('lua/vendor/json.lua')",
    "local function decode(raw) if type(raw) == 'string' then return json.decode(raw) end return raw end",
    "local selfloop = dofile('lua/core/selfloop.lua')",
    'selfloop.setup()',
    ...(index ? ["print('drop_index=" + index + "=' .. tostring((decode(host.sql_exec('DROP INDEX IF EXISTS " + index + "', '[]')) or {}).error or 'ok'))"] : []),
    "local answer = decode(host.sql_exec('ALTER TABLE self_wakes DROP COLUMN " + column + "', '[]'))",
    "print('drop=" + column + "=' .. tostring(answer and answer.error or 'ok'))",
    "local rows = decode(host.sql_query('PRAGMA table_info(self_wakes)', '[]'))",
    'local gone = true',
    'for _, row in ipairs(rows) do if tostring(row.name) == "' + column + '" then gone = false end end',
    "print('gone=" + column + "=' .. tostring(gone))",
    'if not gone then os.exit(1) end',
  ].join('\n') + '\n');
  const result = spawnSync(BIN, ['--db', db], {
    cwd: home, encoding: 'utf8',
    env: H.nodeEnv(home, mock.address().port, { WA_SCRIPT: script }),
  });
  if (result.status !== 0) throw new Error('the ledger column ' + column + ' could not be dropped: ' + String(result.stderr || result.stdout).slice(0, 500));
  assert.match(String(result.stdout), new RegExp('gone=' + column + '=true'), 'the column the node reads is still there: ' + result.stdout);
  // The product's own setup ran in that process, so a column it knows how to add back was not dropped at all.
  return String(result.stdout).trim();
}

// EVERY ROW RUNS WHERE IT IS WRITTEN, against the state that exists at that moment. A row deferred to the end of
// the script would judge the node's LAST state under the name of the first one (measured in this row: the green
// case read a broken node), so a row is an assertion about now, and its name is printed now.
let rows = 0;
function row(name, fn) { fn(); rows += 1; console.log('ok ' + name); }

(async () => {
  try {
    mock = await H.startMock((body) => {
      const last = String(body.messages?.filter((m) => m.role === 'user').at(-1)?.content || '');
      if (last.includes('[self-wake')) { wakeTurns++; return { message: { role: 'assistant', content: 'wake turn' }, finish: 'stop' }; }
      const wanted = last.match(/schedule a wake due (now|in (\d+) seconds?)/);
      if (wanted && !armed.has(last)) {
        armed.add(last);
        const seconds = wanted[2] ? Number(wanted[2]) : 0;
        return { finish: 'tool_calls', message: { role: 'assistant', content: '', tool_calls: [{ id: 'wake-' + seconds, type: 'function',
          function: { name: 'wake', arguments: JSON.stringify({ reason: 'wakes-rule-row', in_seconds: seconds }) } }] } };
      }
      return { message: { role: 'assistant', content: 'finished' }, finish: 'stop' };
    });
    node = await H.startNode({ bin: BIN, home, db, providerPort: mock.address().port });

    // ---- GREEN: a working node -------------------------------------------------------------
    const chat = await node.get('/chat', { text: 'schedule a wake due now', thread: 'wakes-rule' });
    assert(!chat.error, 'the scheduling turn failed: ' + JSON.stringify(chat).slice(0, 300));
    await H.until(async () => wakeTurns >= 1, 'the wake turn never ran');
    const healthy = await H.until(async () => {
      const body = await node.health();
      return body.wakes?.known === true && body.wakes.last_tick?.outcome === 'ok'
        && body.wakes.due === 0 && body.wakes.last_dispatch_at ? body : null;
    }, 'the node never reported a dispatched wake');
    let bodies = { healthy };
    const rawHealthy = await rawHealth();

    row('green', () => {
      const { lines, rc } = judge(healthy);
      assert.equal(rc, 0, 'a healthy node was not green: ' + JSON.stringify(lines));
      assert.equal(lines.length, 1);
      // The lane is whatever the node says at this instant (a wake turn just ended): the line must name it, not
      // assume it. What must hold is the shape and the counts.
      assert.match(lines[0], /^GREEN wakes: last_tick ok, 0 dispatchable \(0 held for a deploy\), oldest 0s, ticking \d+s, lane (idle|busy|upgrading), worker (alive|busy|stalled)$/);
      note(lines[0]);
      // The pre-install check end to end, and the node's body carrying exactly one wakes object (the judge
      // finds the FIRST "wakes": key, so a second one would be judged instead of the node's).
      const rows = verifyInstall();
      assert.equal(rows.length, 1, 'verify-install.sh did not report the loop: ' + JSON.stringify(rows));
      assert.equal(rows[0].status, 'ok', 'verify-install.sh on a healthy node: ' + JSON.stringify(rows[0]));
      assert.equal((JSON.stringify(healthy).match(/"wakes":/g) || []).length, 1, '/health has more than one wakes key');
    });

    // ---- selfloop_tick_failed (+ self_wake_stalled at a 3 s bound) --------------------------
    // A due row must exist when the column goes: the raise happens on the tick's CLAIM, so with nothing due the
    // tick never reads `boot` and would look healthy. The row is armed BEFORE the drop because arming it is a
    // write that names the column.
    const second = await node.get('/chat', { text: 'schedule a wake due in 6 seconds', thread: 'wakes-rule' });
    assert(!second.error, 'the second scheduling turn failed: ' + JSON.stringify(second).slice(0, 300));
    note(dropColumn('boot'));
    const tickFailed = await H.until(async () => {
      const body = await node.health();
      return body.wakes?.last_tick?.outcome === 'selfloop_tick_failed' && Number(body.wakes.dispatchable) >= 1 ? body : null;
    }, 'the broken node never named selfloop_tick_failed', 40000);
    bodies.broken = tickFailed;

    row('selfloop_tick_failed', () => {
      const { lines, rc } = judge(tickFailed);
      assert.equal(rc, 1, 'a raised tick was not red: ' + JSON.stringify(lines));
      const raised = lines.find((line) => line.startsWith('RED selfloop_tick_failed:'));
      assert(raised, 'no RED selfloop_tick_failed in ' + JSON.stringify(lines));
      assert.match(raised, /no such column: boot/, 'the red does not carry the error the tick raised: ' + raised);
      note(raised);
      const rows = verifyInstall();
      const failed = rows.filter((row) => row.status === 'fail');
      assert.equal(failed.length, lines.length, 'verify-install.sh did not fail once per red: ' + JSON.stringify(rows));
      assert.match(JSON.stringify(failed), /selfloop_tick_failed/, 'verify-install.sh did not name the red: ' + JSON.stringify(rows));
    });

    // The row has to be DUE for longer than the lowered bound before that red can be true, and the shipped bound
    // is 120 s: the wait is what makes the same judge say the same thing about a node that is really waiting.
    await H.sleep(5000);
    const stalledBody = await node.health();
    assert(Number(stalledBody.wakes?.oldest_dispatchable_age_s) > 3,
      'the due row did not age past the lowered bound: ' + JSON.stringify(stalledBody.wakes));
    assert.equal(stalledBody.wakes.last_tick.outcome, 'selfloop_tick_failed', 'the tick stopped raising while waiting');

    row('self_wake_stalled', () => {
      // The shipped bound is 120 s; this node's row has been due for seconds, so the row judges the SAME body
      // with the bound lowered - the judge, the body and the idle lane are the real ones.
      const { lines, rc } = judge(stalledBody, { WA_WAKES_STALL_SECONDS: '3' });
      assert.equal(rc, 1);
      const stalled = lines.find((line) => line.startsWith('RED self_wake_stalled:'));
      assert(stalled, 'no RED self_wake_stalled in ' + JSON.stringify(lines));
      assert.match(stalled, /lane idle$/, 'the stall red does not name the idle lane: ' + stalled);
      assert.match(stalled, /due row\(s\)/, 'the stall red does not name how many rows wait: ' + stalled);
      note(stalled);
      // AND THE SHIPPED BOUND DOES NOT FIRE YET: a few seconds due is a tick in progress, not a stall.
      const shipped = judge(stalledBody);
      assert.equal(shipped.lines.filter((line) => line.startsWith('RED self_wake_stalled:')).length, 0,
        'the 120 s bound fired on a row that is seconds old: ' + JSON.stringify(shipped.lines));
    });

    // ---- wakes_unknown: the node cannot say ------------------------------------------------
    note(dropColumn('attempts', 'self_wakes_attempt_idx'));
    const unknown = await H.until(async () => {
      const body = await node.health();
      return body.wakes?.known === false ? body : null;
    }, 'the node never said it cannot report its wake state', 40000);
    bodies.unknown = unknown;

    row('wakes_unknown', () => {
      const { lines, rc } = judge(unknown);
      assert.equal(rc, 1, 'an unknown wake state was not red: ' + JSON.stringify(lines));
      assert(lines[0].startsWith('RED wakes_unknown: '), 'the first red is not wakes_unknown: ' + JSON.stringify(lines));
      note(lines[0]);
      const rows = verifyInstall();
      assert.match(JSON.stringify(rows.filter((row) => row.status === 'fail')), /wakes_unknown/,
        'verify-install.sh did not name wakes_unknown: ' + JSON.stringify(rows));
    });

    // ---- wakes_not_publishing: a real body, one field aged --------------------------------
    // A working node republishes every 2 s, so its answer is never 30 s old; the field is aged HERE and the row
    // says so. Everything else in the body is what the node answered.
    const aged = JSON.parse(JSON.stringify(healthy));
    aged.wakes.published_age_ms = 41000;
    bodies.aged = aged;

    row('wakes_not_publishing', () => {
      const { lines, rc } = judge(aged);
      assert.equal(rc, 1, 'a stale publisher was not red: ' + JSON.stringify(lines));
      assert.equal(lines[0], 'RED wakes_not_publishing: 41000 ms old (bound 30s)', JSON.stringify(lines));
      note(lines[0] + ' (a real body with published_age_ms aged: a working node republishes every 2 s)');
    });

    // ---- WAITING: what an install sees before the node's first tick -------------------------
    // The shape is the product's own (wakes_health() answers exactly this until the first tick publishes); the
    // rest of the body is what the node answered. The END-TO-END cold start is in test-node-wake-facts.cjs.
    const waitingBody = asWaiting(healthy);
    bodies.waiting = waitingBody;

    // AND IT DOES NOT LIE AFTER THE BOUND: a reader still waiting past the bound calls it UNKNOWN, and UNKNOWN is
    // a failure. The endpoint is a stub (a server that answers the before-first-tick shape forever); the WAITER
    // and the judge it calls are the shipped ones.
    const waitingStub = http.createServer((req, res) => { res.writeHead(200, { 'content-type': 'application/json' }); res.end(JSON.stringify(waitingBody)); });
    await new Promise((resolve) => waitingStub.listen(0, '127.0.0.1', resolve));
    const waitingStubPort = waitingStub.address().port;
    // ASYNCHRONOUSLY, because the stub answers from THIS process: spawnSync would block the event loop the stub
    // needs to answer on, and the reader would report a timeout that says nothing about the reader.
    const waitStarted = Date.now();
    const waitResult = await new Promise((resolve) => {
      const child = spawn('bash', ['-c', '. "$1/scripts/lib/health-wakes.sh"; wa_health_wakes_wait "$2" 2', '_', root, String(waitingStubPort)]);
      let out = '';
      child.stdout.on('data', (chunk) => (out += chunk));
      child.on('close', (code) => resolve({ status: code, stdout: out, elapsed: Date.now() - waitStarted }));
    });

    row('waiting', () => {
      const { lines, rc } = judge(waitingBody);
      assert.equal(rc, 3, 'a node that has not published a tick was not WAITING: ' + JSON.stringify(lines));
      assert.equal(lines[0], 'WAITING wakes: no tick has published wake facts since this node started (wakes_not_reported_yet)');
      note(lines[0] + ' (rc 3: not a pass and not a red - the reader waits)');
      waitingStub.close();
      assert.equal(waitResult.status, 2, 'a reader past the bound did not fail: ' + JSON.stringify(waitResult.stdout));
      assert.equal(String(waitResult.stdout).trim(),
        'UNKNOWN wakes: no tick published 2s after the node answered (wakes_not_reported_yet past the bound)',
        'the past-the-bound line: ' + JSON.stringify(waitResult.stdout));
      assert(waitResult.elapsed >= 2000, 'the reader did not actually wait: ' + waitResult.elapsed + ' ms');
      note('past the bound: ' + String(waitResult.stdout).trim());
    });

    // ---- A MISSING FIELD IS RED, BY NAME (the sed readers used to skip it silently) --------
    const fieldBodies = {};
    for (const field of ['published_age_ms', 'dispatchable', 'oldest_dispatchable_age_s']) {
      const copy = JSON.parse(JSON.stringify(healthy));
      delete copy.wakes[field];
      fieldBodies[field] = copy;
    }
    const noLane = JSON.parse(JSON.stringify(healthy));
    delete noLane.node_state;
    fieldBodies.node_state_state = noLane;
    Object.assign(bodies, fieldBodies);

    row('missing_field', () => {
      const expected = {
        published_age_ms: 'RED wakes_unknown: published_age_ms is missing from /health.wakes',
        dispatchable: 'RED wakes_unknown: dispatchable is missing from /health.wakes',
        oldest_dispatchable_age_s: 'RED wakes_unknown: oldest_dispatchable_age_s is missing from /health.wakes',
        node_state_state: 'RED wakes_unknown: node_state.state is missing from /health',
      };
      for (const [name, body] of Object.entries(fieldBodies)) {
        const { lines, rc } = judge(body);
        assert.equal(rc, 1, 'a body without ' + name + ' was not red: ' + JSON.stringify(lines));
        assert.equal(lines[0], expected[name], 'the red does not name the missing field ' + name + ': ' + JSON.stringify(lines));
        note(lines[0]);
      }
    });

    // ---- `node_state.state` BY NAME: no turn running, and a wedged lane is not a hiding place --
    const laneBodies = {};
    laneBodies.busy_alive = JSON.parse(JSON.stringify(healthy));
    laneBodies.busy_alive.node_state = { state: 'busy' }; laneBodies.busy_alive.worker = 'alive';
    laneBodies.busy_stalled = JSON.parse(JSON.stringify(laneBodies.busy_alive)); laneBodies.busy_stalled.worker = 'stalled';
    laneBodies.upgrading_held = JSON.parse(JSON.stringify(laneBodies.busy_alive));
    laneBodies.upgrading_held.node_state = { state: 'upgrading' };
    laneBodies.unknown_name = JSON.parse(JSON.stringify(healthy)); laneBodies.unknown_name.node_state = { state: 'prewarming' };
    for (const body of Object.values(laneBodies)) { body.wakes.dispatchable = 1; body.wakes.oldest_dispatchable_age_s = 600; body.wakes.ticking_for_s = 300; }
    laneBodies.upgrading_held.wakes.deploy_waiting = 1;
    Object.assign(bodies, laneBodies);

    row('lane_names', () => {
      const busy = judge(laneBodies.busy_alive, { WA_WAKES_STALL_SECONDS: '3' });
      assert.equal(busy.rc, 0, 'a busy lane with a live worker was red: ' + JSON.stringify(busy.lines));
      const wedged = judge(laneBodies.busy_stalled, { WA_WAKES_STALL_SECONDS: '3' });
      assert.equal(wedged.rc, 1, 'a wedged lane hid a dead loop: ' + JSON.stringify(wedged.lines));
      assert.match(wedged.lines[0], /lane busy$/, 'the wedged red does not name the lane: ' + wedged.lines[0]);
      note(wedged.lines[0]);
      const installing = judge(laneBodies.upgrading_held, { WA_WAKES_STALL_SECONDS: '3' });
      assert.equal(installing.rc, 0, 'a deploy-held row was red during an install: ' + JSON.stringify(installing.lines));
      assert.match(installing.lines[0], /1 held for a deploy/);
      const stranger = judge(laneBodies.unknown_name);
      assert.equal(stranger.rc, 1, 'a state name this rule does not know was accepted: ' + JSON.stringify(stranger.lines));
      assert.match(stranger.lines[0], /"prewarming" is not a name this rule knows/);
      note(stranger.lines[0]);
    });

    // ---- THE ROW'S AGE COUNTS FROM THIS PROCESS'S FIRST TICK (the good install that would have failed) ----
    const coldStart = (ticking) => {
      const copy = JSON.parse(JSON.stringify(healthy));
      // The lane at the instant of the restart is idle (nothing is running): the body is the node's, the lane is
      // the one this row is about.
      copy.node_state = { state: 'idle' };
      copy.worker = 'alive';
      copy.wakes.dispatchable = 1;
      copy.wakes.oldest_dispatchable_age_s = 600;
      copy.wakes.ticking_for_s = ticking;
      return copy;
    };
    bodies.cold_start = coldStart(3);
    bodies.cold_start_late = coldStart(300);

    row('cold_start_grace', () => {
      const cold = judge(bodies.cold_start);
      assert.equal(cold.rc, 0, 'a row that came due DURING the install was a stall 3 s after the restart: ' + JSON.stringify(cold.lines));
      note(cold.lines[0] + ' (10 min old, this process has ticked 3 s: not a stall)');
      const late = judge(bodies.cold_start_late);
      assert.equal(late.rc, 1, 'a row still due after the process had ticked 300 s was not a stall: ' + JSON.stringify(late.lines));
      assert.match(late.lines[0], /\(counted from this process, 300s\)/);
      note(late.lines[0]);
    });

    // ---- ONE OF EACH KEY: the judge takes the FIRST, so a second one would be judged instead --------
    row('single_keys', () => {
      const count = (text, key) => (text.match(new RegExp('"' + key + '":', 'g')) || []).length;
      assert.equal(count(rawHealthy, 'wakes'), 1, '/health has more than one wakes key');
      const wakesText = JSON.stringify(healthy.wakes);
      assert.equal(count(wakesText, 'known'), 1, 'the wakes object carries known twice: ' + wakesText);
      assert.equal(count(wakesText, 'outcome'), 1, 'last_tick carries outcome twice: ' + wakesText);
      assert.equal(count(wakesText, 'error'), 1, 'last_tick carries error twice: ' + wakesText);
      const unknownText = JSON.stringify(unknown.wakes);
      assert.equal(count(unknownText, 'reason'), 1, 'the unknown answer carries reason twice: ' + unknownText);
      note('the node\'s own answer carries one wants/known/outcome/error key, and one reason on the unknown one');
    });

    // ---- the same rule in jq, on the same bodies ------------------------------------------
    const jqBodies = Object.entries(bodies);
    const haveJq = spawnSync('jq', ['--version'], { encoding: 'utf8' }).status === 0;
    row('jq_agrees', () => {
      if (!haveJq) { console.log('  SKIP jq_agrees: no jq on this machine (the shipped judge is the awk one)'); return; }
      for (const [name, body] of jqBodies) {
        for (const env of [undefined, { WA_WAKES_STALL_SECONDS: '3' }]) {
          const shipped = judge(body, env);
          const jq = jqVerdict(body, env);
          assert(jq, 'jq answered nothing for ' + name);
          assert.equal(jq.rc, shipped.rc, 'jq and the shipped judge disagree on ' + name + ': ' + JSON.stringify([jq, shipped]));
          // THE jq FORM NAMES THE FIRST RED (halt_error stops there, which is what a watcher needs); the shipped
          // judge names every red. On the first line they must be identical, character for character.
          assert.equal(jq.text, shipped.lines[0],
            'jq and the shipped judge printed different lines for ' + name + ': ' + JSON.stringify([jq, shipped.lines]));
        }
      }
      note('jq agrees with scripts/lib/health-wakes.sh on ' + jqBodies.length + ' bodies at both bounds (the rule as stated)');
    });

    console.log('health wakes rule ok (' + rows + ' rows: green, selfloop_tick_failed, self_wake_stalled, '
      + 'wakes_unknown, wakes_not_publishing, waiting, missing_field, lane_names, cold_start_grace, single_keys, '
      + 'jq agreement - judged on a real scratch node, and the waiting body is the shape the product answers '
      + 'before its first tick)');
  } finally {
    if (node) await node.close();
    if (mock) { mock.closeAllConnections(); await new Promise((r) => mock.close(r)); }
    if (process.exitCode || keep) console.log('evidence: ' + home);
    else fs.rmSync(home, { recursive: true, force: true });
  }
})().catch((e) => { console.error(e); process.exitCode = 1; });
