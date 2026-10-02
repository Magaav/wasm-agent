// ATTACK 1: does checkAdmission still admit produce/allocate for a lane producing RIGHT NOW?
// The wave STORE read is a COPY of the live store. The activity SOURCE is the live one, exactly as
// production derives it (the manifest's verifier config names C:/Users/Victor/.wasm-agent).
// READ-ONLY throughout: every open of waves.sqlite / memory.db is {readOnly:true}.
import {pathToFileURL} from 'node:url';
import {DatabaseSync} from 'node:sqlite';
import path from 'node:path';

const [W, OLDW, REPO] = process.argv.slice(2);
const mod = (root, rel) => pathToFileURL(path.join(root, rel)).href;
const newEntry = await import(mod(W, 'scripts/wave-entry.mjs'));
const oldEntry = await import(mod(OLDW, 'scripts/wave-entry.mjs'));
const act = await import(mod(W, 'scripts/lib/wave-activity.mjs'));

const PHASES = ['produce', 'allocate', 'land', 'admit'];
const store = path.join(REPO, '.git', 'wa-waves');
const db = new DatabaseSync(path.join(store, 'waves.sqlite'), {readOnly: true});
const row = db.prepare('SELECT * FROM waves ORDER BY created_at DESC LIMIT 1').get();
db.close();
const source = act.activitySource(JSON.parse(row.manifest));
console.log('--- production-derived activity source (from the COPY row manifest) ---');
console.log(JSON.stringify(source));
const t0 = Date.now();
const inv = act.activityInventory(source);
console.log('--- activityInventory(real source) ---');
console.log(JSON.stringify({
  on: inv.on, reason: inv.reason,
  agents: inv.agents.map(a => ({session: a.session, state: a.state, turn: a.turn, child: a.child, worktree: a.worktree, registered: a.registered, corroborated: a.corroborated, owner: a.owner, in_flight: a.in_flight})),
  held: inv.held.length, leftovers: inv.leftovers.length, unresolved: inv.unresolved, evidence: inv.evidence,
}, null, 1));
console.log(`probe+inventory elapsed_ms=${Date.now() - t0}`);
const verdict = act.waveActivity(source, row);
console.log('--- waveActivity(row) on the COPY ---');
console.log(JSON.stringify({activity: verdict.activity, convergence: verdict.convergence, runtime_state: verdict.runtime_state, reason: verdict.reason, agents: verdict.agents.length}));
console.log(`--- checkAdmission, store=COPY, row state=${row.state} ---`);
for (const p of PHASES) {
  console.log(`BEFORE-change code ${p.padEnd(9)} => ${JSON.stringify(oldEntry.checkAdmission(REPO, {phase: p}))}`);
  console.log(`AFTER-change  code ${p.padEnd(9)} => ${JSON.stringify(newEntry.checkAdmission(REPO, {phase: p}))}`);
}
