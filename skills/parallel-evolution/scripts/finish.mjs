// Mechanical finish evidence. Review, conflict resolution and repairs stay with the agent.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {spawn, spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';

const [mode, directory, expectedHead] = process.argv.slice(2);
const repo = path.resolve(directory || process.cwd());
const runner = fileURLToPath(import.meta.url);
const sha = text => crypto.createHash('sha256').update(text).digest('hex');
const runnerIdentity = {path:runner,sha256:sha(fs.readFileSync(runner)),platform:process.platform};
// Native Windows paths require native Git Bash; System32 bash launches WSL.
const gateShell=process.platform==='win32'
  ? path.join(process.env.ProgramFiles || 'C:/Program Files','Git','bin','bash.exe') : 'bash';
const quote = text => "'" + text.replaceAll("'", "'\"'\"'") + "'";
function git(...args) {
  const result = spawnSync('git', args, {cwd:repo, encoding:'utf8', windowsHide:true,
    timeout:60000, maxBuffer:8*1024*1024});
  if (result.error || result.status !== 0) throw Error(result.error?.message || result.stderr || `git ${args[0]} exited ${result.status}`);
  return result.stdout.trim();
}
function inspect() {
  const checks = [];
  const check = (name, operation) => {
    try { const detail = operation(); checks.push({name,ok:true,detail}); return detail; }
    catch (error) { checks.push({name,ok:false,error:String(error.message)}); return null; }
  };
  const require = (condition, detail) => { if (!condition) throw Error(detail); return true; };
  const head = check('revision', () => {
    const actual = git('rev-parse','HEAD');
    require(/^[a-f0-9]{40,64}$/.test(expectedHead || '') && actual === expectedHead,
      `expected HEAD ${expectedHead}; observed ${actual}`);
    return actual;
  });
  const tree = check('source_tree', () => git('rev-parse','HEAD^{tree}'));
  const branch = check('branch', () => git('symbolic-ref','--short','HEAD'));
  check('clean', () => require(git('status','--porcelain') === '', 'uncommitted changes remain'));
  // Refresh observations without pruning local remote-tracking refs: drafts and
  // stale refs are operator-owned evidence, not finish-gate cleanup targets.
  check('fresh_remote_refs', () => git('fetch','origin'));
  check('current', () => require(git('rev-list','--count','HEAD..origin/main') === '0', 'branch is behind origin/main'));
  check('pushed', () => {
    const upstream = git('rev-parse','--abbrev-ref','--symbolic-full-name','@{upstream}');
    require(upstream === `origin/${branch}`, `publish this branch with its own upstream; observed ${upstream}`);
    require(git('rev-list','--left-right','--count',`HEAD...${upstream}`).split(/\s+/).every(n => n === '0'),
      `branch and ${upstream} differ; sync/push is unfinished`);
    return upstream;
  });
  check('merge_proof', () => git('merge-tree','--write-tree','origin/main','HEAD'));
  return {repository_ready:checks.every(item => item.ok),repo,head,tree,branch,checks,runner:runnerIdentity,
    inference_required:['one concern and patch review','impact audit and its coverage','integration/deployment when requested']};
}
function receiptPath() { return path.resolve(repo, git('rev-parse','--git-path','wa-finish-gate.json')); }
function verify(state) {
  if (!state.repository_ready) return {...state,gate_verified:false};
  try {
    const receipt = JSON.parse(fs.readFileSync(receiptPath(),'utf8'));
    if (receipt.schema !== 1 || receipt.repo !== repo || receipt.tree !== state.tree || receipt.passed !== true)
      throw Error('no passing gate evidence for this source tree');
    if (receipt.log_sha256 !== sha(fs.readFileSync(receipt.log))) throw Error('gate log differs from recorded evidence');
    if (!Number.isFinite(receipt.gate_ms) || receipt.gate_ms < 0) throw Error('gate duration is missing or invalid');
    if (receipt.gate_runs !== 1) throw Error('gate run count is missing or invalid');
    if (receipt.gate_exit !== 0) throw Error('gate exit status is missing or nonzero');
    return {...state,gate_verified:true,tested_head:receipt.head,equivalence:'git_tree',skipped:receipt.skipped,
      gate_ms:receipt.gate_ms,gate_runs:receipt.gate_runs,gate_log:receipt.log};
  } catch (error) { return {...state,gate_verified:false,gate_error:error.message}; }
}
// ---- THE GATE LANE: one CPU-heavy gate at a time per node --------------------------------------
// Every producer ran this gate on its own and nothing coordinated the runs: N finishes at once
// meant N cargo builds contending for the same cores, and the same four-tree candidate passed
// alone (`exit 0`, `smoke ok (2 skipped)`) and failed twice while four children competed. The
// lane is `scripts/gate-lane.mjs`; this is its consumer.
//
// It decides *when*, never *what*: the command stays `bash scripts/test.sh`, the verdict line and
// the skip count are still read here out of this run's own log, and this process stays the
// supervisor of the gate. `acquire` grants a slot, prints the row that names it and then blocks
// while holding it; `release --id` ends the claim. `run` is not used for exactly that reason - it
// spawns the gate itself, which would make the lane a second supervisor of a process this file
// must keep.
const LANE_SCRIPT = path.join(path.dirname(fileURLToPath(import.meta.url)),'..','..','..','scripts','gate-lane.mjs');
const LANE_OFF = String(process.env.WA_GATE_LANE ?? '').trim().toLowerCase() === 'off';
// A gate can contain gates: `scripts/test-parallel-finish.mjs` runs `finish.mjs gate` on fixture
// trees, and the repository gate (scripts/test.sh) runs that suite. Those nested runs are inside
// CPU this process has already paid for, so they inherit this admission decision instead of asking
// for a slot of their own - a second request there would wait behind the slot its own parent holds,
// and the parent would wait for it.
//
// The marker is spelled `GATE_LANE_HELD` and not `WA_GATE_LANE_HELD` because the gate fences its own
// environment before it runs anything: scripts/test.sh unsets every `WA_*` and `WASM_AGENT_*`
// variable (its `compgen -e` loop, letting only WASM_AGENT_SKIP_UI_TESTS, WASM_AGENT_IN_TURN and
// WA_GATE_JOBS through) so no caller's runtime state leaks into the gate. Measured on this tree: a
// `WA_`-named marker is gone by the time the nested suite runs, the nested gate then asks for a slot
// it can never get, and both gates wait for each other until the outer one is killed. The marker
// therefore uses a name that fence does not unset, and scripts/test-gate-lane-wiring.cjs applies the
// fence *text taken from the real gate* before it runs its nested gate, so a fence that grows to
// cover this name fails that test instead of deadlocking a real gate.
const LANE_HELD = process.env.GATE_LANE_HELD || '';
const laneNotice = text => process.stderr.write(`${text}\n`);

// Ask once through this source's lane runner. Unavailable or unverified
// reservations refuse execution; an explicit administrative override is recorded.
async function laneAcquire({cwd,label}) {
  const record = {lane:'gate',mode:'slot',request:null,label:label || null,dir:null,waited_ms:0,reason:null};
  if (LANE_OFF) {
    record.mode = 'off';
    record.reason = 'WA_GATE_LANE=off: the gate runs with no slot, by name';
    laneNotice(`gate lane: ${record.reason}`);
    return {obtained:false,refused:false,marker:'off',record};
  }
  if (LANE_HELD) {
    let origin;
    try { origin=JSON.parse(process.env.GATE_LANE_ORIGIN || ''); } catch {}
    const validation=origin && LANE_HELD===`slot:${origin.id}`
      ? spawnSync(process.execPath,[LANE_SCRIPT,'validate','--dir',origin.dir,'--id',String(origin.id),
        '--lease',origin.lease,'--holder-pid',String(process.pid)],
      {encoding:'utf8',windowsHide:true,timeout:20000}) : null;
    if (!validation || validation.status !== 0) {
      record.mode='refused';record.reason=`invalid_inheritance: ${LANE_HELD} has no verified live ancestor lease`;
      laneNotice(`gate lane: ${record.reason}`);
      return {obtained:false,refused:true,marker:null,record};
    }
    record.mode='inherited';record.request=origin.id;record.dir=origin.dir;
    record.reason=`inherited ${LANE_HELD}: verified live ancestor lease`;
    laneNotice(`gate lane: ${record.reason}; no second slot is requested`);
    return {obtained:false,refused:false,marker:LANE_HELD,origin,record};
  }
  const started = Date.now();
  let child;
  try {
    child = spawn(process.execPath,[LANE_SCRIPT,'acquire','--cwd',path.resolve(cwd),
      ...(label ? ['--label',label] : []),'--holder-pid',String(process.pid)],
    {cwd:path.resolve(cwd),windowsHide:true,stdio:['ignore','pipe','pipe'],env:process.env});
  } catch (error) {
    record.mode = 'unavailable';
    record.reason = `could not start ${LANE_SCRIPT}: ${error.message}`;
    laneNotice(`gate lane: ${record.reason}; this gate did not run.`);
    return {obtained:false,refused:true,marker:null,record};
  }
  const outcome = await new Promise(resolve => {
    let out = '', err = '', settled = false;
    const settle = value => { if (!settled) { settled = true; resolve(value); } };
    child.stdout.on('data',chunk => {
      out += chunk;
      const start = out.indexOf('{');
      if (start < 0) return;
      try { settle({grant:JSON.parse(out.slice(start))}); } catch { /* the receipt is still arriving */ }
    });
    // The lane narrates its own wait while it holds this process ("waiting (120s). capacity 1 of 1
    // in use; running #12 (label, pid 123, held 900s); queue depth 1 …"): those lines are this
    // gate's queue position and the holder's name, so they are passed through, not swallowed.
    child.stderr.on('data',chunk => { err += chunk; process.stderr.write(chunk); });
    child.on('error',error => settle({error}));
    child.on('close',code => settle({code,out,err}));
  });
  record.waited_ms = Date.now() - started;
  if (outcome.grant) {
    record.request = outcome.grant.id;
    record.dir = outcome.grant.dir;
    record.label = outcome.grant.label || label || null;
    record.reason = `slot #${outcome.grant.id} granted`
      + (record.waited_ms >= 1000 ? ` after waiting ${(record.waited_ms / 1000).toFixed(1)}s` : ' at once');
    laneNotice(`gate lane: ${record.reason}; this process runs the gate and releases the slot when it ends.`);
    record.runner=outcome.grant.runner;
    return {obtained:true,refused:false,marker:`slot:${outcome.grant.id}`,origin:outcome.grant.inheritance,child,record};
  }
  const words = String(outcome.error?.message || outcome.err || '').trim().split('\n').filter(Boolean).pop()
    || 'no reason given';
  if (!outcome.error && outcome.code === 75) {
    // The lane was reached and made a decision, and it is terminal by design: it waited its own
    // budget (WA_GATE_LANE_WAIT_SECONDS, 2 h by default), and its record names the holder, how long
    // that holder has held the slot and the depth it gave up at. Running the gate now would put a
    // second CPU-heavy gate on a node whose holder has been busy for hours - the condition under
    // which these gates failed tonight - so this is the one case where the gate does not run.
    record.mode = 'refused';
    record.reason = words;
    laneNotice(`gate lane: no slot was granted and this is terminal, not a retry: ${words}`);
    return {obtained:false,refused:true,marker:null,record};
  }
  // Missing script, unreadable store and version skew are observable refusals.
  // They never grant a speculative second gate on the same host.
  record.mode = 'unavailable';
  record.reason = words;
  laneNotice(`gate lane: could not be consulted (${words}); this gate did not run.`);
  return {obtained:false,refused:true,marker:null,record};
}

// The gate's environment, with the marker that tells a gate nested inside it whether it is inside
// a verified reservation: slot plus its originating store and live lease.
const laneGateEnv = slot => ({...process.env,GATE_LANE_HELD:slot.marker,
  GATE_LANE_ORIGIN:slot.origin ? JSON.stringify(slot.origin) : ''});

// Give the slot back and record what the gate did with it. Best effort: the row is the lane's, the
// verdict is this file's, and a release that fails is reported rather than allowed to fail the gate.
async function laneRelease(slot,exit,detail) {
  if (!slot.obtained) return;
  const request = slot.record?.request ?? null;
  if (!request) {
    laneNotice('gate lane: a slot was granted without a request id; nothing can be released, so the'
      + ' lane will settle that row by proof of death, not by a timeout.');
    return;
  }
  const args = [LANE_SCRIPT,'release','--id',String(request),'--detail',detail];
  if (Number.isInteger(exit)) args.push('--exit',String(exit));
  const released = spawnSync(process.execPath,args,{encoding:'utf8',windowsHide:true,timeout:60000,env:process.env});
  if (released.status !== 0) {
    laneNotice(`gate lane: releasing slot #${request} reported:`
      + ` ${(released.stderr || released.stdout || '').trim() || `exit ${released.status}`}`
      + ' - the lane row is still the record of it.');
    slot.child?.unref();slot.child?.stdout?.destroy();slot.child?.stderr?.destroy();
    return;
  }
  // The acquirer holds the claim in its own process and stops once its row ends; if it cannot (a
  // lane that could not settle the row), it is stopped here. A lease dies with the process that
  // holds it, so the slot is freed either way and is never left looking held.
  const child = slot.child;
  if (!child || child.exitCode !== null || child.signalCode) return;
  await new Promise(resolve => {
    const timer = setTimeout(() => {
      laneNotice(`gate lane: the acquirer for slot #${request} did not stop after its row ended;`
        + ' terminating it - its lease dies with it, so the slot is freed.');
      try { child.kill('SIGKILL'); } catch {}
      resolve();
    },5000);
    child.once('close',() => { clearTimeout(timer); resolve(); });
  });
}

async function gate() {
  const gateStarted = process.hrtime.bigint();
  const before = inspect();
  if (!before.repository_ready) return {...before,gate_verified:false};
  const existing = verify(before);
  if (existing.gate_verified) return {...existing,gate_reused:true,gate_run_count:0,gate_exit:0};
  // The slot is asked for before this run touches any of its own evidence: a request that never got
  // a slot leaves the previous receipt exactly as it found it.
  const slot = await laneAcquire({cwd:repo,label:`finish ${before.branch || path.basename(repo)}`});
  if (slot.refused) return {...verify(before),gate_verified:false,gate_lane:slot.record,
    gate_error:`the gate did not run: the gate lane granted no slot (${slot.record.reason})`};
  const receipt = receiptPath(), log = `${receipt}.log`;
  fs.mkdirSync(path.dirname(receipt),{recursive:true});
  // Remove old proof before execution: a failed rerun must never leave a passing receipt.
  if (fs.existsSync(receipt)) fs.unlinkSync(receipt);
  const fd = fs.openSync(log,'w');
  const executionStarted=process.hrtime.bigint();
  let result;
  try {
    result = spawnSync(gateShell,['scripts/test.sh'],{cwd:repo,stdio:['ignore',fd,fd],
      windowsHide:true,timeout:3500*1000,env:laneGateEnv(slot)});
  } finally { fs.closeSync(fd); }
  const bytes = fs.readFileSync(log);
  // The queue is not the gate: `gate_ms` excludes the time this run spent waiting for a slot (the
  // lane's own record of that wait is `gate_lane.waited_ms`), so a duration still means the same
  // thing whatever else the node was doing when it was taken.
  const gateMs = Number((Number(process.hrtime.bigint() - executionStarted) / 1e6).toFixed(3));
  const verdict = /(?:^|\n)smoke ok(?: \((\d+) skipped\))?\r?\n?$/u.exec(bytes.toString('utf8'));
  const after = inspect();
  if (result.error) {
    // A timeout or cancelled shell is not proof its descendants stopped. Keep
    // the acquisition/watchdog real until owner drain evidence settles it.
    laneNotice(`gate lane: execution error (${result.error.message}); reservation retained pending process drain`);
    if (slot.obtained) {
      const deferred=spawnSync(process.execPath,[LANE_SCRIPT,'defer','--id',String(slot.record.request),
        '--gate-pid',String(result.pid || 0),'--detail',`finish execution error: ${result.error.message}; owner must prove descendant drain`],
      {encoding:'utf8',windowsHide:true,timeout:20000});
      if (deferred.status!==0) {
        laneNotice(`gate lane: could not durably defer reservation: ${deferred.stderr || deferred.error?.message}`);
        // Retain this holder as well: dropping it would let a legacy watchdog
        // mistake a lost ancestry link for drain. Reconciliation needs this PID.
        slot.child?.unref();slot.child?.stdout?.destroy();slot.child?.stderr?.destroy();
        await new Promise(()=>{setInterval(()=>{},1000);});
      }
    }
    slot.child?.unref();slot.child?.stdout?.destroy();slot.child?.stderr?.destroy();
  } else {
    await laneRelease(slot,result.status,`finish gate in ${repo} exited ${result.status}`
      + `${verdict ? `; "${verdict[0].trim()}"` : '; no verdict line'}`);
  }
  if (result.error || result.status !== 0 || !verdict || !after.repository_ready || after.tree !== before.tree)
    return {...after,gate_verified:false,gate_error:result.error?.message || `gate exit=${result.status}; verdict=${Boolean(verdict)}`,
      gate_log:log,gate_ms:gateMs,gate_runs:1,gate_run_count:1,gate_exit:result.status,gate_lane:slot.record};
  fs.writeFileSync(receipt,JSON.stringify({schema:1,repo,head:before.head,tree:before.tree,passed:true,
    skipped:Number(verdict[1] || 0),gate_ms:gateMs,gate_runs:1,gate_exit:result.status,log,log_sha256:sha(bytes),
    gate_lane:slot.record,runner:runnerIdentity,shell:gateShell,at:new Date().toISOString()}));
  return {...verify(after),gate_reused:false,gate_run_count:1,gate_exit:result.status,gate_lane:slot.record};
}
function spellDefinitions() {
  // This repo uses bash on Windows too. Native paths are quoted as bash literals.
  const params = {runner_arg:{type:'string',default:quote(runner)},repo_arg:{type:'string'},head:{type:'string'}};
  const command = verb => `node {{runner_arg}} ${verb} {{repo_arg}} {{head}}`;
  const observation = (verb, expect) => ({kind:'run',script:command(verb),expect});
  const target = {node:'local'};
  return {spells:[
    {name:'parallel-evolution-ready',description:'Verify clean, current, pushed, mergeable repository state',target,params,
      steps:[observation('check',{repository_ready:true})],post:[observation('check',{repository_ready:true})]},
    {name:'parallel-evolution-gate',description:'Run the gate and verify its source-bound evidence',target,params,
      pre:[observation('check',{repository_ready:true})],
      steps:[{...observation('gate',{gate_verified:true}),timeout_seconds:10800}],
      post:[observation('verify',{repository_ready:true,gate_verified:true})]}
  ],composition:{name:'parallel-evolution-finish',description:'Verify repository readiness, run the gate, and recheck completion evidence',
    parts:[{name:'parallel-evolution-ready'},{name:'parallel-evolution-gate'}]}};
}
try {
  let result;
  if (mode === 'spell') result = spellDefinitions();
  else if (mode === 'check') result = inspect();
  else if (mode === 'gate') result = await gate();
  else if (mode === 'verify') result = verify(inspect());
  else throw Error('usage: finish.mjs spell|check|gate|verify <absolute-repo> <expected-HEAD>');
  console.log(JSON.stringify(result));
} catch (error) { console.log(JSON.stringify({repository_ready:false,gate_verified:false,error:error.message})); process.exitCode=1; }
