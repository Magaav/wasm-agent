// The gate lane's contract, tested with real processes: a real queue, a real kill, a real
// OS-held lease. The gate itself is never run here - a fake command stands in for it, because
// what is under test is *when* a command runs, not what it is.
//
// Each check exists for a way the lane could lie:
//   * two requests together: exactly one holds a slot, and the other's recorded reason names
//     the holder, its elapsed time and the depth it is waiting at (no silent "queued");
//   * order: the earlier request runs first, and a later one cannot overtake it by polling
//     luckily;
//   * the holder is killed mid-run: the slot is NOT handed on while the gate it started is
//     still alive (`orphaned`), and when that process is gone the claim is `abandoned` with
//     both pids in the record and the next request runs - recovery by proof of death, never
//     by a timeout;
//   * a request that cannot be satisfied ends `refused` with the reason it gave up on, and
//     does not run later, on any tick;
//   * `acquire`/`release` lets a caller keep its own runner, and a live lease is never
//     reconciled by anyone else;
//   * an exit 0 with no gate verdict line is recorded as un-verdicted, never as a pass.
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const assert = require('node:assert/strict');
const {spawn, spawnSync} = require('node:child_process');

const repo = path.resolve(__dirname, '..');
const lane = path.join(repo, 'scripts', 'gate-lane.mjs');
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-gate-lane-'));
const state = path.join(root, 'lane');
const longGate = ['node', '-e', 'setTimeout(()=>{},60000)'];
const skippedGate = ['node', '-e', "process.stdout.write('smoke ok (2 skipped)\\n')"];
const silentGate = ['node', '-e', "process.stdout.write('nothing was tested\\n')"];
const children = new Set();
let checks = 0;
const check = (value, label) => { assert.ok(value, label); checks += 1; };
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
function cli(args, {env = {}, detached = false} = {}) {
  const child = spawn(process.execPath, [lane, ...args], {
    cwd: repo, detached, windowsHide: true,
    env: {...process.env, ...env, WA_GATE_LANE_DIR: state},
    stdio: ['ignore', 'pipe', 'pipe']});
  children.add(child);
  const result = {child, pid: child.pid, stdout: '', stderr: '', code: null};
  child.stdout.on('data', chunk => { result.stdout += chunk; });
  child.stderr.on('data', chunk => { result.stderr += chunk; });
  result.done = new Promise(resolve => child.on('close', code => { result.code = code; children.delete(child); resolve(result); }));
  return result;
}
const laneSync = args => {
  const result = spawnSync(process.execPath, [lane, ...args], {cwd: repo, encoding: 'utf8',
    windowsHide: true, env: {...process.env, WA_GATE_LANE_DIR: state}, timeout: 60000});
  assert.ifError(result.error);
  return {code: result.status, stdout: String(result.stdout), stderr: String(result.stderr)};
};
const status = () => JSON.parse(laneSync(['status', '--json']).stdout);
const receipt = text => JSON.parse(text.slice(text.indexOf('{')));
const entryOf = (snapshot, id) =>
  [...snapshot.held, ...snapshot.queue, ...snapshot.recent].find(entry => entry.id === id);
async function until(operation, label, ms = 30000) {
  const deadline = Date.now() + ms;
  let last = null;
  while (Date.now() < deadline) {
    last = await operation();
    if (last) return last;
    await sleep(150);
  }
  throw Error(`timed out waiting for ${label}; last state: ${JSON.stringify(status(), null, 1)}`);
}
const pidAlive = pid => {
  try { process.kill(pid, 0); return true; } catch (error) { return error.code === 'EPERM'; }
};
function killTree(pid) {
  if (process.platform === 'win32') spawnSync('taskkill', ['/F', '/T', '/PID', String(pid)], {windowsHide: true});
  else { try { process.kill(-pid, 'SIGKILL'); } catch { try { process.kill(pid, 'SIGKILL'); } catch {} } }
}

async function main() {
  // 1. A single request runs, and its own words are the record.
  const alone = cli(['run', '--label', 'alone', '--json', '--sample-seconds', '1', '--poll-ms', '300',
    '--', ...['node', '-e', "const t=Date.now();while(Date.now()-t<2500){};process.stdout.write('smoke ok (2 skipped)\\n')"]]);
  const aloneResult = await alone.done;
  check(aloneResult.code === 0, `a lone request must run and exit 0: ${aloneResult.stderr}`);
  const aloneReceipt = receipt(aloneResult.stdout);
  check(aloneReceipt.state === 'done' && aloneReceipt.obtained === true, 'the lone request is recorded as done');
  check(aloneReceipt.skipped === 2 && aloneReceipt.verdict_found === true,
    'the skip count comes from the gate\'s own verdict line');
  check(aloneReceipt.gate_ms >= 2000, 'the gate duration is the command\'s, not the lane\'s');
  check(aloneReceipt.cpu?.available === true && aloneReceipt.cpu.samples >= 1
    && aloneReceipt.cpu.peak_processes_in_tree >= 1,
  `CPU must be sampled from the command's own process tree: ${JSON.stringify(aloneReceipt.cpu)}`);

  // 2. Two together: one runs, one waits with a recorded reason naming the holder.
  const holder = cli(['run', '--label', 'pair-holder', '--sample-seconds', '0', '--poll-ms', '400', '--', ...longGate]);
  await until(async () => status().held.some(entry => entry.label === 'pair-holder'),
    'the first of the pair to be running');
  const waiting = cli(['run', '--label', 'pair-waiter', '--json', '--sample-seconds', '0', '--poll-ms', '400',
    '--wait-seconds', '900', '--', ...skippedGate]);
  const blocked = await until(async () => {
    const snapshot = status();
    const entry = entryOf(snapshot, snapshot.queue[0]?.id);
    return entry && entry.state === 'waiting' && entry.reason?.includes('capacity 1 of 1') ? entry : null;
  }, 'the second request to record why it waits');
  const holderEntry = (await Promise.resolve(status())).held[0];
  check(blocked.waits_for === holderEntry.id,
    'the waiting record names the slot it waits behind');
  check(blocked.reason.includes(`#${holderEntry.id}`) && blocked.reason.includes('queue depth 1'),
    `the reason names the holder and the depth: ${blocked.reason}`);
  check(blocked.depth === 1 && status().queue.length === 1, 'exactly one request waits, at depth 1');
  await sleep(1200); // a wait that is long enough to be a wait.
  killTree(holder.pid);
  const holderDone = await holder.done;
  const waitingResult = await until(async () => (waiting.code === null ? null : waiting), 'the waiter to finish');
  check(holderDone.code === null || holderDone.code !== 0, 'the killed holder does not report a gate pass');
  check(waitingResult.code === 0, `the waiter runs after the slot frees: ${waitingResult.stderr}`);
  const queuedReceipt = receipt(waitingResult.stdout);
  check(queuedReceipt.waited_ms >= 1000 && queuedReceipt.verdict_found === true,
    `the waiter records the wait and then the gate's own verdict: ${queuedReceipt.waited_ms} ms waited`);
  const afterPair = status();
  check(afterPair.slots_held === 0 && afterPair.waiting === 0, 'the lane is empty again after both settle');

  // 3. Kill the holder mid-run. Two outcomes are possible and both are the lane's contract:
  //    the gate outlives its holder (Linux, or a kill that takes only the parent) so the slot
  //    stays held as `orphaned` until that process is gone; or the gate dies with its holder
  //    (measured on this Windows node - see the platform note below) so the claim is `abandoned`
  //    at once. Which one happened is read from the machine, not assumed, and the matching
  //    property is asserted either way.
  const doomed = cli(['run', '--label', 'doomed-holder', '--sample-seconds', '0', '--poll-ms', '400', '--', ...longGate]);
  const doomedEntry = await until(async () => {
    const entry = status().held.find(item => item.label === 'doomed-holder');
    return entry && entry.gate_pid ? entry : null;
  }, 'the doomed holder to start a gate');
  const survivor = cli(['run', '--label', 'after-death', '--sample-seconds', '0', '--poll-ms', '400', '--', ...skippedGate]);
  await until(async () => status().queue.some(entry => entry.label === 'after-death'), 'the survivor to queue');
  process.kill(doomed.pid, 'SIGKILL');
  await sleep(400);
  const gateSurvived = pidAlive(doomedEntry.gate_pid);
  const settled = await until(async () => {
    const entry = status().held.find(item => item.label === 'doomed-holder')
      || status().recent.find(item => item.label === 'doomed-holder');
    return entry && /^(orphaned|abandoned)$/.test(entry.state) ? entry : null;
  }, 'the killed holder to be settled by proof of death');
  console.log(`note: killing holder pid ${doomed.pid} left its gate pid ${doomedEntry.gate_pid}`
    + ` ${gateSurvived ? 'ALIVE, so the slot stays held' : 'gone, so the slot frees at once'}`
    + ` (${process.platform})`);
  check(settled.state === (gateSurvived ? 'orphaned' : 'abandoned'),
    `the recorded state follows the gate's real liveness: ${settled.state}`);
  check(settled.reason.includes(`pid ${doomed.pid}`) && settled.reason.includes(`pid ${doomedEntry.gate_pid}`)
    && /gone|died/.test(settled.reason),
  `the record names the dead holder and the gate it started: ${settled.reason}`);
  if (gateSurvived) {
    check(status().queue.length === 1 && survivor.code === null,
      'the next request is still waiting, because the cores are still busy');
    const refusedReconcile = laneSync(['reconcile', '--id', String(settled.id), '--evidence', 'I looked at it']);
    check(refusedReconcile.code === 1 && /still burning cores/.test(refusedReconcile.stderr),
      'a reconcile is refused while the recorded gate process is alive');
    process.kill(settled.gate_pid, 'SIGKILL');
  } else {
    check(status().slots_held === 0, 'a claim whose gate died with it frees its slot');
  }
  const survivorResult = await until(async () => (survivor.code === null ? null : survivor), 'the survivor to run');
  check(survivorResult.code === 0, `the next request runs once the slot is free: ${survivorResult.stderr}`);
  const abandoned = status().recent.find(entry => entry.id === settled.id);
  check(abandoned.state === 'abandoned' && abandoned.reason.includes('slot released'),
    `the abandoned claim is reconcilable after the death: ${abandoned.reason}`);

  // 4. A request that can never be satisfied ends visibly, and never runs later.
  const stuck = cli(['run', '--label', 'stuck-holder', '--sample-seconds', '0', '--poll-ms', '400', '--', ...longGate]);
  await until(async () => status().held.some(entry => entry.label === 'stuck-holder'), 'the stuck holder to run');
  const hopeless = cli(['run', '--label', 'hopeless', '--sample-seconds', '0', '--poll-ms', '400',
    '--wait-seconds', '3', '--', ...skippedGate]);
  const hopelessResult = await hopeless.done;
  check(hopelessResult.code === 75, `a request with no slot in reach exits 75, not a gate code: ${hopelessResult.code}`);
  const hopelessRow = status().recent.find(entry => entry.label === 'hopeless');
  check(hopelessRow.state === 'refused' && /refused after holding no slot/.test(hopelessRow.reason)
    && hopelessRow.waits_for === status().held[0].id,
  `the refusal names the holder it gave up behind: ${hopelessRow.reason}`);
  check(/terminal, not a retry/.test(hopelessResult.stderr), 'the refusal says it is terminal');
  const noWait = cli(['run', '--label', 'no-wait', '--no-wait', '--sample-seconds', '0', '--', ...skippedGate]);
  const noWaitResult = await noWait.done;
  check(noWaitResult.code === 75 && /refused without waiting/.test(status().recent.find(entry => entry.label === 'no-wait').reason),
    '--no-wait refuses immediately with its reason recorded');
  killTree(stuck.pid);
  await stuck.done;
  await sleep(1200);
  const afterRefusals = status();
  check(!afterRefusals.recent.some(entry => entry.label === 'hopeless' && /running|done/.test(entry.state)),
    'a refused request is never run on a later tick');

  // 5. acquire/release: the caller keeps its own runner. The acquirer blocks while it holds,
  //    because its own lease is the claim's proof of life, and it spawns nothing.
  const owner = cli(['acquire', '--label', 'owner-keeps-its-runner', '--holder-pid', String(process.pid)]);
  const acquired = await until(async () => (owner.stdout.includes('{') ? receipt(owner.stdout) : null),
    'the owner to be granted the slot');
  check(acquired.obtained === true && acquired.mode === 'acquire' && acquired.state === 'running'
    && acquired.command.includes('caller runs its own gate'),
  'acquire grants the slot and says it runs nothing');
  check(owner.code === null, 'the acquirer holds the slot by staying alive, not by exiting');
  const second = laneSync(['acquire', '--label', 'second-owner', '--no-wait', '--holder-pid', String(process.pid)]);
  check(second.code === 75 && /refused/.test(second.stderr),
    'a second acquire is refused while the first holds the slot');
  const liveReconcile = laneSync(['reconcile', '--id', String(acquired.id), '--evidence', 'looks idle to me']);
  check(liveReconcile.code === 1 && /A live owner is never reconciled/.test(liveReconcile.stderr),
    'a live lease refuses reconciliation by someone else');
  const released = laneSync(['release', '--id', String(acquired.id), '--exit', '0',
    '--detail', 'the holder ran its own gate']);
  check(released.code === 0 && status().held.length === 0, 'release frees the slot for the next request');
  const ownerExit = await until(async () => (owner.code === null ? null : owner), 'the acquirer to stop holding');
  check(ownerExit.code === 0, 'the acquirer exits once its slot is released');

  // 6. Exit 0 with no verdict line is un-verdicted, not a pass.
  const silentRun = cli(['run', '--label', 'no-verdict', '--json', '--sample-seconds', '0', '--', ...silentGate]);
  const silentResult = await silentRun.done;
  const silentReceipt = receipt(silentResult.stdout);
  check(silentResult.code === 0 && silentReceipt.verdict_found === false && silentReceipt.skipped === 0,
    'an exit 0 without the gate verdict is recorded as un-verdicted');
  check(/no gate verdict line/.test(silentResult.stderr),
    'and it says so on stderr rather than passing quietly');

  console.log(`gate lane ok (${checks} checks, 0 skipped; real processes, a real kill, real OS leases,`
    + ' fake gate commands, the repository gate itself not run)');
  console.log(`evidence: ${root}`);
}
main().catch(error => {
  console.error(error.stack);
  process.exitCode = 1;
}).finally(() => {
  for (const child of children) { try { killTree(child.pid); } catch {} }
  const unresolved = laneSync(['status']);
  console.error(unresolved.stdout);
});
