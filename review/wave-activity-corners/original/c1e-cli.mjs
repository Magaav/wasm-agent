// REVIEWER: section 2 - the operator surface (the real `observe`/`resolve` CLI + `create()`), on a
// LIVE-SHAPED COPY: the two session rows are the LIVE store's own rows (33b4e818's stale `active`
// turn under a dead boot; child:dispatch:6204126f's live turn), the wave store is a COPY of the live
// `.git/wa-waves` with `registration.repo` repointed and the copied row's activity source pointed at
// the copy, the node store is a COPY of the live memory.db. The only edits are the repo/tree path
// prefixes (a Git worktree registration cannot be copied) and the copied wave row's repo/activity.
//
// Usage: node c1e-cli.mjs <tipTree> <oldTree> <scratchRoot>
import {pathToFileURL} from 'node:url';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {spawn, spawnSync} from 'node:child_process';
import {DatabaseSync} from 'node:sqlite';

const [TIP, OLD, ROOT] = process.argv.slice(2);
const mod = (root, rel) => pathToFileURL(path.join(root, rel)).href;
const tipCli = await import(mod(TIP, 'scripts/wave-activity.mjs'));
const oldCli = await import(mod(OLD, 'scripts/wave-activity.mjs'));
const tipLife = await import(mod(TIP, 'scripts/wave-lifecycle.mjs'));
const tipEntry = await import(mod(TIP, 'scripts/wave-entry.mjs'));
const oldEntry = await import(mod(OLD, 'scripts/wave-entry.mjs'));
const tipAct = await import(mod(TIP, 'scripts/lib/wave-activity.mjs'));

const LIVE_REPO = 'C:/Users/Victor/orca/projects/wasm-agent';
const LIVE_DATA = 'C:/Users/Victor/.wasm-agent';
const LIVE_STORE = path.join(LIVE_REPO, '.git', 'wa-waves');
const STALE = '33b4e818-0278-47a1-823a-b756517ec787';                      // live: active turn under a dead boot
const LANE = 'child:dispatch:6204126f-93d1-4249-96a5-514acff56693';       // live lane, turn active now
const STALE_RUN = '4cb9cea0-b387-43dd-92eb-23513fd975ec', STALE_BOOT = '578f10e1-b8e0-4641-acae-d5bc34b652c6';
const LANE_RUN = '6eb6edfd-8d2d-46ab-8176-9e8c4a7d781d', LANE_BOOT = 'b65133b9-06f5-4f96-9b4d-e6acb31e5350';

const B = path.join(ROOT, 'b');
fs.rmSync(B, {recursive: true, force: true});
const repo = path.join(B, 'repo'), data = path.join(B, 'data');
fs.mkdirSync(data, {recursive: true}); fs.mkdirSync(repo, {recursive: true});
const git = (cwd, ...args) => { const r = spawnSync('git', ['-C', cwd, ...args], {encoding: 'utf8', windowsHide: true}); if (r.status !== 0) throw Error(`git ${args.join(' ')}: ${r.stderr}`); return r.stdout.trim(); };
git(repo, 'init', '-q', '-b', 'main'); git(repo, 'config', 'user.name', 'reviewer'); git(repo, 'config', 'user.email', 'reviewer@invalid');
fs.writeFileSync(path.join(repo, 'seed'), 'reviewer fixture\n'); git(repo, 'add', '.'); git(repo, 'commit', '-qm', 'review baseline');

// --- the copy of the LIVE store (its row + registration), repointed at the copy repo.
const store = path.join(repo, '.git', 'wa-waves');
fs.mkdirSync(store, {recursive: true});
for (const name of ['waves.sqlite', 'registration.json', 'migration.json']) fs.copyFileSync(path.join(LIVE_STORE, name), path.join(store, name));
const configFile = path.join(B, 'config.json');
fs.writeFileSync(configFile, JSON.stringify({repo, data, source_root: TIP, monitor_mode: 'external-cli-test', process_probe: true}, null, 1));
const registration = JSON.parse(fs.readFileSync(path.join(store, 'registration.json'), 'utf8'));
registration.repo = repo; registration.config = configFile; registration.source_root = TIP;
fs.writeFileSync(path.join(store, 'registration.json'), JSON.stringify(registration));

const waveDb = new DatabaseSync(path.join(store, 'waves.sqlite'));
const liveRow = waveDb.prepare('SELECT * FROM waves').get();
const manifest = JSON.parse(liveRow.manifest); manifest.repo = repo; manifest.activity = {data};
const STALE_TREE = () => treeOf(STALE);
const writeRepo = repo.replaceAll('\\', '/').toLowerCase();   // wave-lifecycle `native()`
waveDb.prepare('UPDATE waves SET repo=?, manifest=? WHERE id=?').run(writeRepo, JSON.stringify(manifest), liveRow.id);
waveDb.close();

// --- the copy of the LIVE node store: only the two rows above, path prefixes repointed.
const live = new DatabaseSync(path.join(LIVE_DATA, 'memory.db'), {readOnly: true});
const sessions = live.prepare('SELECT * FROM sessions WHERE id IN (?,?)').all(STALE, LANE);
const turns = live.prepare('SELECT * FROM steering_runs WHERE session_id IN (?,?)').all(STALE, LANE);
const ddl = live.prepare("SELECT name, sql FROM sqlite_master WHERE type='table' AND name IN ('sessions','steering_runs','child_completions')").all();
live.close();
const db = new DatabaseSync(path.join(data, 'memory.db'));
for (const t of ddl) db.exec(t.sql);
const treeOf = id => path.join(data, `wa-worktree-${id.replaceAll(':', '-')}`).replaceAll('\\', '/');
for (const s of sessions) {
  const tree = treeOf(s.id); git(repo, 'worktree', 'add', '--detach', tree);
  db.prepare('INSERT INTO sessions(id,parent_session_id,worktree,workspace_required,workspace_state,workspace_branch,workspace_base_commit,workspace_source_path,workspace_start_state,started_at,ended_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)')
    .run(s.id, s.parent_session_id, tree, s.workspace_required, s.workspace_state, s.workspace_branch, s.workspace_base_commit, repo, s.workspace_start_state, s.started_at, s.ended_at, s.updated_at);
}
for (const t of turns) db.prepare('INSERT INTO steering_runs(session_id,owner,run_id,boot,state,updated_at) VALUES(?,?,?,?,?,?)').run(t.session_id, t.owner, t.run_id, t.boot, t.state, t.updated_at);
db.close();

const source = () => ({kind: 'node-runtime', repo, data, memory_db: path.join(data, 'memory.db'), process_probe: true});
const say = (label, value) => console.log(`${label} ${typeof value === 'string' ? value : JSON.stringify(value)}`);
const cli = (tree, ...args) => { const r = spawnSync(process.execPath, [path.join(tree, 'scripts', 'wave-activity.mjs'), ...args], {encoding: 'utf8', windowsHide: true}); return (r.stdout || '').trim(); };
const tryCli = (tree, ...args) => { const out = cli(tree, ...args); try { const j = JSON.parse(out); return j.error ? `REFUSED: ${j.error}` : j; } catch { return `RAW: ${out.slice(0, 200)}`; } };
const summarize = inv => ({activity: inv.activity, agents: inv.agents.map(a => `${a.session}:turn=${a.turn?.state}:corroborated=${a.corroborated}`), claims: inv.claims.map(c => `${c.claim}:${c.session}`), resolved: inv.resolved_claims.map(c => `${c.resolved?.claim}:${c.session}`)});
const turnOf = sid => { const d = new DatabaseSync(path.join(data, 'memory.db'), {readOnly: true}); const r = d.prepare('SELECT * FROM steering_runs WHERE session_id=?').get(sid); d.close(); return r; };
const touch = (sid, {run = null, boot = null, state = 'active'} = {}) => { const d = new DatabaseSync(path.join(data, 'memory.db')); d.prepare('UPDATE steering_runs SET state=?, run_id=COALESCE(?,run_id), boot=COALESCE(?,boot) WHERE session_id=?').run(state, run, boot, sid); d.close(); };
const tryCreate = (mf) => { try { const r = tipLife.create(store, mf); return {ok: r.ok, previous: r.previous && {id: r.previous.id, activity: r.previous.activity}}; } catch (e) { return {ok: false, reason: e.message}; } };
const resFile = path.join(store, 'activity-resolutions.json');

console.log('=== fixture: a copy of the LIVE store + the LIVE node rows, path prefixes repointed ===');
say('wave row (copied from live)', {id: liveRow.id, state: liveRow.state, legacy: liveRow.legacy !== null});
say('session rows kept (live)', sessions.map(s => `${s.id} state=${s.workspace_state} ended=${s.ended_at}`));
say('turn rows kept (live)', turns.map(t => `${t.session_id} state=${t.state} run=${t.run_id} boot=${t.boot}`));
say('tip inventory of the copy', summarize(tipAct.activityInventory(source())));

console.log('\n=== 1. CORNER 1 BEFORE: the stale positive turn on the same store, PRE-DELTA code (e2a86bc) ===');
const oldOb = oldCli.observe(configFile);
say('old observe', {activity: oldOb.activity, agents: oldOb.agents.length, unresolved_activity_claims: oldOb.unresolved_activity_claims.length, keys: Object.keys(oldOb).join(',')});
say(`old resolve(${STALE.slice(0, 12)}…, --run ${STALE_RUN.slice(0, 8)}…)`, tryCli(OLD, 'resolve', configFile, STALE, 'nothing is running', '--run', STALE_RUN));

console.log('\n=== 2. CORNER 1 CLOSED: the same store, TIP ===');
const seen = tipCli.observe(configFile);
for (const claim of seen.activity_claims) say('tip observe activity_claims[]', {session: claim.session, why: claim.why, positive: claim.positive, resolvable: claim.resolvable, corroborated: claim.corroborated, run_id: claim.run_id, boot: claim.boot, resolution: claim.resolution});
say('tip observe', {activity: seen.activity, unresolved_activity_claims: seen.unresolved_activity_claims.length, resolutions: seen.resolutions});
say('the real CLI prints it too', JSON.parse(cli(TIP, 'observe', configFile)).activity_claims.map(c => `${c.session}:why=${c.why}:positive=${c.positive}:resolvable=${c.resolvable}`));
say('the command observe PRINTED (captured before anything was resolved)', `${seen.activity_claims.find(c => c.session === STALE).resolution}  <- no identity flag`);
say('resolve with NO identity flag', tryCli(TIP, 'resolve', configFile, STALE, 'nothing is running'));
say('resolve with the WRONG run id', tryCli(TIP, 'resolve', configFile, STALE, 'nothing is running', '--run', 'not-the-run'));
say('the flag it needs is the entry\'s own identity field', seen.activity_claims.find(c => c.session === STALE).run_id);
say('resolve with the RIGHT run id + evidence', tryCli(TIP, 'resolve', configFile, STALE, 'the node process that started it is gone; nothing runs in that tree', '--run', STALE_RUN));
say('inventory after', summarize(tipAct.activityInventory(source())));
say('resolve AGAIN (same identity)', tryCli(TIP, 'resolve', configFile, STALE, 'again', '--run', STALE_RUN));

console.log('\n=== 3. the fence create() raises has a way out (the copied LIVE row is the previous wave) ===');
fs.rmSync(resFile, {force: true});
say('create() while the stale positive turn is ON', tryCreate({...manifest, id: 'review-next', bootstrap: false, owner: 'review-fixture'}));
say('resolve it (its own identity)', tryCli(TIP, 'resolve', configFile, STALE, 'observed: nothing runs in that tree', '--run', STALE_RUN));
say('create() after the resolution', tryCreate({...manifest, id: 'review-next-2', bootstrap: false, owner: 'review-fixture'}));

console.log('\n=== 4. NON-BORROWABILITY: a NEW turn on the same session is a new claim ===');
touch(STALE, {run: 'review-new-run', boot: 'review-new-boot'});
say('inventory after a NEW turn (run=review-new-run, boot=review-new-boot)', summarize(tipAct.activityInventory(source())));
say('observe entry (the old resolution must not apply)', (() => { const o = tipCli.observe(configFile).activity_claims.find(c => c.session === STALE); return {why: o.why, positive: o.positive, resolvable: o.resolvable, run_id: o.run_id}; })());
say('resolve the new turn on its own identity', tryCli(TIP, 'resolve', configFile, STALE, 'the second turn is dead too', '--run', 'review-new-run'));

console.log('\n=== 5. THE PROCESS-HELD CASE: a process that names the tree ===');
touch(STALE, {run: 'review-held-run', boot: 'review-held-boot'});
const laneTree = STALE_TREE();
const holder = spawn(process.execPath, ['-e', 'setTimeout(() => {}, 60000)', laneTree], {stdio: 'ignore', windowsHide: true});
await new Promise(done => setTimeout(done, 2000));
const held = tipAct.activityInventory(source());
say('inventory while a process holds the tree', {activity: held.activity, corroborated: held.agents.find(a => a.session === STALE)?.corroborated, agents: held.agents.map(a => a.session)});
say('observe entry for the held claim', (() => { const o = tipCli.observe(configFile).activity_claims.find(c => c.session === STALE); return {positive: o.positive, resolvable: o.resolvable, corroborated: o.corroborated, resolution: o.resolution}; })());
say('resolve the held claim', tryCli(TIP, 'resolve', configFile, STALE, 'try to clear live work', '--run', 'review-held-run'));
console.log(`the corroborating process line: ${tipAct.processProbe().text.find(line => line.includes(laneTree.toLowerCase())) || '(none)'}`);

console.log('\n=== 6. ATTACK: the SAME live-shaped turn with the probe blind ===');
const killed = new Promise(done => holder.once('exit', done));
holder.kill(); await killed; await new Promise(done => setTimeout(done, 1000));
const blind = tipAct.activityInventory(source());
say('inventory with the holder gone (the turn is STILL `active` in the node store)', summarize(blind));
say('resolve the STILL-ACTIVE turn (no process names the tree)', tryCli(TIP, 'resolve', configFile, STALE, 'observed: no process names this tree', '--run', 'review-held-run'));
say('inventory after resolving an active turn', summarize(tipAct.activityInventory(source())));
const holder2 = spawn(process.execPath, ['-e', 'setTimeout(() => {}, 30000)', STALE_TREE()], {stdio: 'ignore', windowsHide: true});
await new Promise(done => setTimeout(done, 2000));
const resuspended = tipAct.activityInventory(source());
say('a process that appears LATER suspends the recorded resolution', {activity: resuspended.activity, corroborated: resuspended.agents.find(a => a.session === STALE)?.corroborated, resolved: resuspended.resolved_claims.length});const exit2 = new Promise(done => holder2.once('exit', done));
holder2.kill(); await exit2; await new Promise(done => setTimeout(done, 800));
say('and when it goes the resolution applies again', summarize(tipAct.activityInventory(source())));
say('resolve with NO evidence', tryCli(TIP, 'resolve', configFile, STALE, '   '));
say('the flag it needs is the entry\'s own identity field (measured above)', tipAct.claimIdentity(seen.agents[0], tipAct.POSITIVE_CLAIM).run_id);

console.log('\n=== 7. ATTACK: observe must not lie about resolvability ===');
touch(STALE, {run: 'review-run-3', boot: 'review-boot-3'});
const good = fs.readFileSync(resFile, 'utf8');
fs.writeFileSync(resFile, '{ this is not json');
const lied = tipCli.observe(configFile);
for (const claim of lied.activity_claims) say('observe with an UNREADABLE resolutions file', {session: claim.session, why: claim.why, resolvable: claim.resolvable, resolution: claim.resolution});
say('observe resolutions field', lied.resolutions);
say('and what resolve really does then', tryCli(TIP, 'resolve', configFile, STALE, 'observed', '--run', 'review-run-3'));
fs.writeFileSync(resFile, good);

console.log('\n=== 8. ATTACK: a claim that names nothing, and whether the node can write one ===');
touch(STALE, {run: '', boot: ''});
const emptyInv = tipAct.activityInventory(source());
say('inventory with run_id="" and boot=""', {agents: emptyInv.agents.map(a => `${a.session}:corroborated=${a.corroborated}`), claims: emptyInv.claims.length});
say('resolve it with NO identity flag (it names nothing)', tryCli(TIP, 'resolve', configFile, STALE, 'observed: nothing names this claim'));
const anonymous = tipAct.readResolutions(resFile).resolutions.filter(r => r.claim === tipAct.POSITIVE_CLAIM && !r.run_id && !r.boot);
const laterAnonymous = tipAct.claimIdentity({session: STALE, worktree: STALE_TREE(), turn: {run_id: '', boot: ''}, child: null}, tipAct.POSITIVE_CLAIM);
say('an anonymous resolution matches a LATER anonymous turn of the same session?', anonymous.length > 0 && tipAct.resolutionMatches(anonymous[anonymous.length - 1], laterAnonymous));
say('is an anonymous turn reachable from the node writer?', 'lua/core/steering.lua:25 passes rid + assert(host.runtime_info().boot_id), and lua/core/agent.lua:1029 mints host.uuid() per run - so no');
say('inventory after (the anonymous resolution applies)', summarize(tipAct.activityInventory(source())));

console.log('\n=== 9. the gate on the live-shaped store: tip vs pre-delta ===');
for (const [label, entry] of [['tip', tipEntry], ['pre-delta', oldEntry]]) {
  say(`${label} checkAdmission`, ['produce', 'allocate', 'land', 'admit'].map(p => { const r = entry.checkAdmission(repo, {phase: p}); return `${p}=${r.ok ? 'ok' : r.reason}`; }).join(' | '));
}
console.log(`fixture retained at ${B}`);
const liveWaves = path.join(LIVE_STORE, 'waves.sqlite');
console.log(`live store untouched: sha256(waves.sqlite)=${crypto.createHash('sha256').update(fs.readFileSync(liveWaves)).digest('hex')} activity-resolutions.json exists=${fs.existsSync(path.join(LIVE_STORE, 'activity-resolutions.json'))}`);
