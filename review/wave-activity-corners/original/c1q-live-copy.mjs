// REVIEWER: section 1 - the LIVE store, on a COPY, through the TIP's library half.
//
// The live repository identity is used (that is what the real session rows bind to, and what the
// real `git worktree list` answers for), but nothing is written near it:
//   * the node store read is a COPY of the live memory.db,
//   * the resolutions store read/written is a COPY of the live store's activity-resolutions.json
//     (which does not exist live - `source.resolutions` is the library's own redirection),
//   * the live `.git/wa-waves` is opened read-only and never written.
// Usage: node c1q-live-copy.mjs <tipTree> <oldTree> <copyMemoryDb> <copyResolutionsFile>
import {pathToFileURL} from 'node:url';
import path from 'node:path';
import fs from 'node:fs';
import crypto from 'node:crypto';

const [TIP, OLD, COPY_DB, COPY_RES] = process.argv.slice(2);
const mod = (root, rel) => pathToFileURL(path.join(root, rel)).href;
const tip = await import(mod(TIP, 'scripts/lib/wave-activity.mjs'));
const old = await import(mod(OLD, 'scripts/lib/wave-activity.mjs'));

const LIVE_REPO = 'C:/Users/Victor/orca/projects/wasm-agent';
const LIVE_DATA = 'C:/Users/Victor/.wasm-agent';
const source = () => ({kind: 'node-runtime', repo: LIVE_REPO, data: LIVE_DATA, memory_db: COPY_DB, process_probe: true, resolutions: COPY_RES});

const sha = f => crypto.createHash('sha256').update(fs.readFileSync(f)).digest('hex');
const liveStore = path.join(LIVE_REPO, '.git', 'wa-waves');
const before = {waves: sha(path.join(liveStore, 'waves.sqlite')), resolutions_exists: fs.existsSync(path.join(liveStore, 'activity-resolutions.json'))};

const brief = inv => ({
  activity: inv.activity, on: inv.on, off: inv.off,
  agents: inv.agents.map(a => ({session: a.session, run_id: a.turn?.run_id, boot: a.turn?.boot, corroborated: a.corroborated})),
  claims: inv.claims.map(c => ({session: c.session, claim: c.claim, corroborated: c.corroborated})),
  resolved: inv.resolved_claims.map(c => ({session: c.session, claim: c.resolved?.claim, by: c.resolved?.by})),
  unresolved: inv.unresolved.length, leftovers: inv.leftovers.length,
  processes: inv.evidence.processes, rows: inv.evidence.session_store.rows
});

const first = tip.activityInventory(source());
console.log('--- the live store, on a copy, TIP code ---');
console.log(JSON.stringify(brief(first), null, 1));
const oldInv = old.activityInventory({kind: 'node-runtime', repo: LIVE_REPO, data: LIVE_DATA, memory_db: COPY_DB, process_probe: true});
console.log('--- the same copy, PRE-DELTA code (e2a86bc) ---');
console.log(JSON.stringify({activity: oldInv.activity, agents: oldInv.agents.length, claims: oldInv.claims.map(c => `${c.claim}:${c.session}`), notes: 'pre-delta has no POSITIVE_CLAIM and no resolutions key on the record'}, null, 1));

// (A) THE LIVE POSITIVE ROWS: which of the live in-flight turns does the probe corroborate?
for (const agent of first.agents) {
  console.log(`live in-flight agent ${agent.session} run=${agent.turn?.run_id} boot=${agent.turn?.boot} corroborated=${agent.corroborated} tree_exists=${fs.existsSync(agent.worktree)} registered=${agent.registered}`);
}
// (B) THE ONE LIVE STALE TURN: 33b4e818's steering row is `active` under a dead boot, its tree gone.
const stale = first.bindings.find(b => b.session === '33b4e818-0278-47a1-823a-b756517ec787');
console.log('live stale turn binding:', JSON.stringify(stale && {session: stale.session, claim: stale.claim, corroborated: stale.corroborated, registered: stale.registered, state: stale.state, turn: stale.turn, tree_exists: fs.existsSync(stale.worktree)}));

// (C) THE ESCAPE HATCH, DRIVEN THROUGH THE TIP's OWN LIBRARY PRIMITIVES, with the resolution file
// redirected to the copy. `findResolution` + `claimIdentity` are exactly what activityInventory uses.
if (fs.existsSync(COPY_RES)) fs.rmSync(COPY_RES);
const victim = first.agents.find(a => a.corroborated === false) || first.agents[0];
if (victim) {
  const identity = tip.claimIdentity(victim, tip.POSITIVE_CLAIM);
  console.log('tip claimIdentity(positive) =', JSON.stringify(identity), '(the row says corroborated=', victim.corroborated + ')');
  console.log('pre-delta module exports POSITIVE_CLAIM/claimIdentity/findResolution at all?',
    JSON.stringify({POSITIVE_CLAIM: old.POSITIVE_CLAIM, claimIdentity: typeof old.claimIdentity, findResolution: typeof old.findResolution}));
  tip.writeResolution(COPY_RES, {...identity, evidence: 'review: the probe does not name this tree', at: Date.now(), by: 'review-6b8b6fcc'});
  const after = tip.activityInventory(source());
  console.log('a POSITIVE_CLAIM resolution for a LIVE in-flight row the probe cannot see:', victim.session,
    '-> activity=', after.activity, 'agents=', after.agents.length, 'resolved=', JSON.stringify(after.resolved_claims.map(c => `${c.resolved.claim}:${c.session}`)),
    '(the row still says turn=', victim.turn?.state, ')');
  console.log('findResolution(corroborated=true) applies?', tip.findResolution(tip.readResolutions(COPY_RES).resolutions, identity, {corroborated: true}) !== null);
} else {
  console.log('no live in-flight agent to resolve (nothing measured)');
}
// (D) THE BORROW TEST ON REAL LIVE IDENTITY: a NEW turn on the same session has a new run_id/boot.
if (victim) {
  const later = {...victim, turn: {...victim.turn, run_id: 'review-new-run', boot: 'review-new-boot'}};
  const resolutions = tip.readResolutions(COPY_RES).resolutions;
  console.log('borrowed by a NEW turn (new run_id/boot)?',
    tip.resolutionMatches(resolutions[0], tip.claimIdentity(later, tip.POSITIVE_CLAIM)));
  const sameTurnAgain = {...victim};
  const again = tip.findResolution(resolutions, tip.claimIdentity(sameTurnAgain, tip.POSITIVE_CLAIM), {corroborated: false});
  console.log('applies to the SAME identity while the probe is blind?', again !== null,
    '| applies while the probe SEES the process (corroborated=true)?', tip.findResolution(resolutions, tip.claimIdentity(sameTurnAgain, tip.POSITIVE_CLAIM), {corroborated: true}) !== null);
}
const afterWrites = {waves: sha(path.join(liveStore, 'waves.sqlite')), resolutions_exists: fs.existsSync(path.join(liveStore, 'activity-resolutions.json'))};
console.log('live store before/after this script:', JSON.stringify({before, afterWrites}), before.waves === afterWrites.waves ? 'UNCHANGED' : 'CHANGED');
