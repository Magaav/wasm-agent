// WHO IS WORKING ON THIS REPOSITORY - the wave's own derived ON/OFF fact.
//
// The wave is ON while any child/agent for this repository is in flight, and OFF when none
// is. That is a fact about the node's OWN records, so it is read from them:
//
//   * the memory store's session rows and their `workspace_*` bindings (who was given which
//     tree, and whether that binding is still allocated, parked or released),
//   * the node's own turn state (`steering_runs`: the client turn a session is running now),
//   * the real `git worktree list` of the repository (what Git itself believes),
//   * the node's own process/client state (a local holder probe, used as corroboration).
//
// NO THIRD PARTY. An `orca` binary is never consulted for a decision here; if one happens to
// exist it may be used as an optional viewer (`orcaView`), and its absence changes nothing.
//
// A durable wave row is BOOKKEEPING. It is not evidence that anyone is working: a crashed
// finisher leaves `running` behind with nothing running. `waveActivity()` therefore never
// reports `active` from a row - only from a positively observed in-flight agent.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {DatabaseSync} from 'node:sqlite';
import {withdrawalProof} from './wave-withdrawal.mjs';

export const key = value => {
  const p = path.resolve(String(value || '')).replaceAll('\\', '/').replace(/^\/\/\?\//, '').replace(/\/+$/, '');
  return process.platform === 'win32' ? p.toLowerCase() : p;
};
const keyOr = value => (value ? key(value) : '');

// The states `lua/core/workspaces.lua` records on a session binding. Resolved means the
// binding has an observed end (released tree, or a parked detached exact tip).
export const RESOLVED_STATES = ['released', 'parked'];
// Transitions that were started and whose outcome is not yet observed. They are never
// treated as resolved, and never treated as activity either.
export const UNRESOLVED_STATES = ['releasing', 'release_unknown', 'parking', 'park_unknown'];
// A turn the node itself says is running right now.
export const LIVE_TURN_STATES = ['active'];
export const LIVE_CHILD_STATES = ['dispatching', 'accepted', 'running'];

export function nativePath(value) {
  if (typeof value !== 'string' || !value) return null;
  const resolved = path.resolve(value).replaceAll('\\', '/');
  return resolved;
}

// THE ACTIVITY SOURCE. A manifest may name it explicitly (`activity:{data:<node state dir>}`);
// production manifests name it through the concrete verifier config, whose `data` is the node
// runtime root the proofs already read. Returning null means "this manifest names no source",
// which callers must report as `activity_unverifiable` - never as OFF.
export function activitySource(manifest) {
  const repo = typeof manifest?.repo === 'string' ? manifest.repo : '';
  const declared = manifest?.activity;
  if (declared && typeof declared === 'object') {
    if (declared.kind === 'none') return {kind: 'none', repo};
    const data = nativePath(declared.data);
    if (data && path.isAbsolute(declared.data)) {
      return {kind: 'node-runtime', repo, data, process_probe: declared.process_probe !== false, memory_db: nativePath(declared.memory_db) || path.join(data, 'memory.db')};
    }
    return {kind: 'invalid', repo, reason: 'activity_source_data_must_be_a_native_absolute_directory'};
  }
  for (const name of ['registries', 'owners', 'operations', 'claims', 'deliveries', 'runtime']) {
    const argv = manifest?.verifiers?.[name]?.argv;
    if (!Array.isArray(argv) || !argv.length) continue;
    const candidate = argv[argv.length - 1];
    if (typeof candidate !== 'string' || !fs.existsSync(candidate)) continue;
    try {
      const config = JSON.parse(fs.readFileSync(candidate, 'utf8'));
      const data = nativePath(config.data);
      if (data) return {kind: 'node-runtime', repo, data, process_probe: config.process_probe !== false, memory_db: path.join(data, 'memory.db')};
    } catch { /* not a config file: keep looking, never guess */ }
  }
  return null;
}

export function sourceOfConfig(config) {
  const data = nativePath(config?.data);
  if (!data) throw Error('node_runtime_data_root_required');
  return {kind: 'node-runtime', repo: config.repo, data, process_probe: config.process_probe !== false, memory_db: path.join(data, 'memory.db')};
}

function git(repo, args) {
  const r = spawnSync('git', ['-C', repo, ...args], {encoding: 'utf8', windowsHide: true, timeout: 60000, maxBuffer: 32 * 1024 * 1024});
  if (r.status !== 0) throw Error(`activity_git_unavailable:${args.join(' ')}:${(r.stderr || r.error?.message || '').trim().slice(0, 200)}`);
  return r.stdout.trim();
}

// THE REAL GIT WORKTREE LIST. Every registration the repository itself carries, with the
// facts the proofs need: path, HEAD, branch, detached/locked/prunable.
export function worktrees(repo) {
  const listing = git(repo, ['worktree', 'list', '--porcelain', '-z']);
  const rows = listing.split('\0\0').filter(Boolean);
  return rows.map(row => {
    const entry = {path: '', head: '', branch: '', detached: false, locked: false, prunable: false, bare: false};
    for (const item of row.split('\0').filter(Boolean)) {
      const space = item.indexOf(' ');
      const name = space < 0 ? item : item.slice(0, space);
      const value = space < 0 ? '' : item.slice(space + 1);
      if (name === 'worktree') entry.path = value.replaceAll('\\', '/');
      else if (name === 'HEAD') entry.head = value;
      else if (name === 'branch') entry.branch = value.replace('refs/heads/', '');
      else if (name === 'detached') entry.detached = true;
      else if (name === 'locked') entry.locked = true;
      else if (name === 'prunable') entry.prunable = true;
      else if (name === 'bare') entry.bare = true;
    }
    return entry;
  }).filter(entry => entry.path);
}

// A repository with no `origin` cannot be the shared integration repository, so it is a throwaway
// fixture whatever directory it lives in; a fixture that remaps TMPDIR (to isolate its own home) is
// no longer under the process temporary root, so the temp-dir heuristic alone is too narrow.
// Production always has an `origin`, where the wave authority rules apply in full.
export function isolatedRepository(repo) {
  let common;
  try {
    common = path.resolve(git(repo, ['rev-parse', '--path-format=absolute', '--git-common-dir'])).replaceAll('\\', '/');
  } catch { return false; }
  const origin = spawnSync('git', ['-C', repo, 'remote', 'get-url', 'origin'], {encoding: 'utf8', windowsHide: true, timeout: 30000});
  if (origin.status !== 0) return true;
  return key(common).startsWith(`${key(os.tmpdir())}/`);
}

// The node's OWN session/binding/turn records. An unreadable or absent store is a refusal -
// it is never an empty (and therefore "quiescent") inventory.
export function sessionInventory(source) {
  const store = source?.memory_db || path.join(source?.data || '', 'memory.db');
  if (!fs.existsSync(store)) return {ok: false, complete: false, reason: 'session_store_missing', store, sessions: [], turns: [], children: []};
  let handle;
  try {
    handle = new DatabaseSync(store, {readOnly: true});
    const all = sql => { try { return handle.prepare(sql).all(); } catch { return null; } };
    const sessions = all("SELECT id,parent_session_id,worktree,workspace_required,workspace_state,workspace_branch,workspace_base_commit,workspace_source_path,workspace_start_state,started_at,ended_at,updated_at FROM sessions WHERE workspace_required=1 OR worktree<>''");
    if (!Array.isArray(sessions)) throw Error('sessions_table_unreadable');
    const turns = all('SELECT session_id,owner,run_id,boot,state,updated_at FROM steering_runs') || [];
    const children = all('SELECT child_id,target_id,parent_session,state,run_id FROM child_completions') || [];
    return {ok: true, complete: true, store, sessions, turns, children, source: 'node:sqlite'};
  } catch (e) {
    return {ok: false, complete: false, reason: `session_store_unreadable:${e.message}`, store, sessions: [], turns: [], children: []};
  } finally { try { handle?.close(); } catch { /* already closed */ } }
}

function decodeJSON(value, fallback = {}) {
  try { const parsed = JSON.parse(value); return parsed && typeof parsed === 'object' ? parsed : fallback; } catch { return fallback; }
}

// The managed root is the node's own state directory: `lua/core/workspaces.lua` builds
// `<data>/wa-worktree-<session>`, so a tree under it is this node's allocation, not a hand-made
// checkout. Naming it explicitly is what keeps "unowned leftover" a decidable question.
export function managedWorktree(source, session) {
  const tree = session.worktree ? String(session.worktree).replaceAll('\\', '/') : '';
  if (!tree || !source?.data) return false;
  return key(tree).startsWith(`${key(source.data)}/wa-worktree-`);
}

// WHICH REPOSITORY A BINDING IS FOR. The recorded `workspace_source_path` is authoritative when
// present; otherwise the binding is resolved through Git itself (its real common directory), so
// a copied store cannot borrow another repository's activity.
function bindingRepo(source, session, commonDir, cache) {
  const recorded = session.workspace_source_path;
  if (recorded) return key(recorded) === key(source.repo);
  if (!session.worktree) return false;
  const tree = key(session.worktree);
  if (cache.has(tree)) return cache.get(tree);
  let answer = false;
  try {
    const resolved = path.resolve(git(session.worktree, ['rev-parse', '--path-format=absolute', '--git-common-dir'])).replaceAll('\\', '/');
    answer = key(resolved) === key(commonDir);
  } catch { answer = false; }
  cache.set(tree, answer);
  return answer;
}

// A local holder probe: the node's own process/client state, matched locally so it costs one
// enumeration. It CORROBORATES an in-flight agent; it never vetoes one, because a turn is
// between process spawns more often than a lane is actually idle.
export function processProbe() {
  if (process.platform === 'win32') {
    const ps = spawnSync('powershell', ['-NoProfile', '-NonInteractive', '-Command',
      'Get-CimInstance Win32_Process | Select-Object ProcessId,Name,ExecutablePath,CommandLine | ConvertTo-Json -Compress'],
      {encoding: 'utf8', windowsHide: true, timeout: 120000, maxBuffer: 64 * 1024 * 1024});
    if (ps.status !== 0) return {available: false, why: `Get-CimInstance failed: ${(ps.stderr || ps.error?.message || '').trim().slice(0, 120)}`, text: []};
    try {
      const parsed = JSON.parse(ps.stdout);
      const rows = Array.isArray(parsed) ? parsed : [parsed];
      return {available: true, checked: rows.length, text: rows.map(r => `${r.ProcessId} ${keyOr(`${r.CommandLine || ''} ${r.ExecutablePath || ''}`)}`)};
    } catch (e) { return {available: false, why: `process list unparsable: ${e.message}`, text: []}; }
  }
  const ps = spawnSync('ps', ['-eo', 'pid,args'], {encoding: 'utf8', windowsHide: true, timeout: 60000, maxBuffer: 64 * 1024 * 1024});
  if (ps.status !== 0) return {available: false, why: 'ps failed', text: []};
  const text = ps.stdout.split('\n').map(line => line.replaceAll('\\', '/').replace(/^\/\/\?\//, '').toLowerCase());
  return {available: true, checked: text.length, text};
}

function holderOf(probe, treePath) {
  if (!probe?.available || !treePath) return null;
  const needle = key(treePath);
  for (const line of probe.text) if (line.includes(needle)) return line.slice(0, 160);
  return null;
}

// AN OPTIONAL VIEWER. If an Orca binary exists it may be asked what it thinks, and the answer is
// recorded as advisory evidence. It is never a decision input and its absence is not a failure.
export function orcaView(source, {enabled = false} = {}) {
  if (!enabled) return {used: false, reason: 'not_requested'};
  const r = spawnSync(source?.orca || 'orca', ['worktree', 'list', '--json'], {encoding: 'utf8', windowsHide: true, timeout: 30000, maxBuffer: 32 * 1024 * 1024});
  if (r.error || r.status !== 0) return {used: false, reason: `optional_viewer_absent:${(r.error?.message || r.stderr || '').trim().slice(0, 120)}`};
  try {
    const value = JSON.parse(r.stdout);
    return {used: true, advisory: true, decision_input: false, worktrees: value?.result?.worktrees?.map(({id, path: p, branch, head}) => ({id, path: p, branch, head})) || [], truncated: value?.result?.truncated};
  } catch { return {used: false, reason: 'optional_viewer_unreadable'}; }
}

// Legacy receipt storage is preserved for audit. No trusted exact-owner drain
// adapter is exposed here: prose creation/replay is unsupported and held.
export const CLAIM_RESOLUTIONS = {schema: 1, kind: 'wave-activity-resolutions'};
export function resolutionsPath(source, commonDir) {
  return source?.resolutions ? path.resolve(source.resolutions) : path.join(commonDir, 'wa-waves', 'activity-resolutions.json');
}
export function readResolutions(file) {
  if (!fs.existsSync(file)) return {ok: true, file, resolutions: []};
  try {
    const value = JSON.parse(fs.readFileSync(file, 'utf8'));
    if (value?.schema !== CLAIM_RESOLUTIONS.schema || value?.kind !== CLAIM_RESOLUTIONS.kind || !Array.isArray(value.resolutions)) return {ok: false, file, reason: 'activity_resolutions_unreadable', resolutions: []};
    return {ok: true, file, resolutions: value.resolutions};
  } catch (e) { return {ok: false, file, reason: `activity_resolutions_unreadable:${e.message}`, resolutions: []}; }
}
export function writeResolution(file, resolution) {
  const current = readResolutions(file);
  if (!current.ok && fs.existsSync(file)) throw Error(current.reason);
  const resolutions = [...current.resolutions, resolution];
  fs.mkdirSync(path.dirname(file), {recursive: true});
  const temporary = `${file}.tmp-${process.pid}`;
  fs.writeFileSync(temporary, `${JSON.stringify({schema: CLAIM_RESOLUTIONS.schema, kind: CLAIM_RESOLUTIONS.kind, resolutions}, null, 2)}\n`);
  fs.renameSync(temporary, file);
  return resolutions;
}
// WHERE THE RESOLUTIONS LIVE: the wave store of this repository, beside `waves.sqlite`.
export function activityStore(source) {
  const commonDir = path.resolve(git(source.repo, ['rev-parse', '--path-format=absolute', '--git-common-dir'])).replaceAll('\\', '/');
  return {commonDir, resolutions: resolutionsPath(source, commonDir)};
}

// A resolution applies only to the exact claim it was written for.
export function resolutionMatches(resolution, claim) {
  if (resolution.session !== claim.session || resolution.claim !== claim.claim) return false;
  if (String(resolution.worktree || '') !== String(claim.worktree || '')) return false;
  for (const field of ['child_id', 'run_id', 'boot']) if (String(resolution[field] || '') !== String(claim[field] || '')) return false;
  return true;
}

// Legacy positive receipt identity is preserved for audit, not settlement proof.
// Unsupported exact-owner drain remains held even after a negative process scan.
export const POSITIVE_CLAIM = 'positive_claim_resolved_by_observation';
export function claimIdentity(record, claim) {
  return {session: record.session, claim, worktree: record.worktree, child_id: record.child?.child_id || '', run_id: record.turn?.run_id || record.child?.run_id || '', boot: record.turn?.boot || ''};
}
// A process holding the tree is stronger evidence than an old resolution: it can never be cleared.
export function findResolution(resolutions, identity, {corroborated = null} = {}) {
  // This inventory has no authenticated exact-owner terminal + descendant/effect
  // drain adapter. Neither prose receipts nor absence in a process scan prove it.
  // Preserve legacy receipts, but do not replay them as settlement.
  return null;
}

// THE INVENTORY. Everything the wave proofs and the ownership proofs need, from our own records.
export function activityInventory(source) {
  const store = sessionInventory(source);
  const trees = worktrees(source.repo);
  const commonDir = path.resolve(git(source.repo, ['rev-parse', '--path-format=absolute', '--git-common-dir'])).replaceAll('\\', '/');
  const cache = new Map();
  const probe = source.process_probe === false ? {available: false, why: 'disabled_by_source', text: []} : processProbe();
  const resolutions = readResolutions(resolutionsPath(source, commonDir));
  const evidence = {
    repository: source.repo, data: source.data, memory_db: store.store, git_common_dir: commonDir,
    session_store: store.ok ? {ok: true, source: store.source, rows: store.sessions.length} : {ok: false, reason: store.reason},
    git_worktrees: trees.length,
    processes: probe.available ? {available: true, checked: probe.checked} : {available: false, why: probe.why || 'unavailable'},
    activity_resolutions: {file: resolutions.file, ok: resolutions.ok, count: resolutions.resolutions.length, reason: resolutions.reason || ''},
    third_party: 'none: ownership, registry and activity are read from the node runtime and Git only',
    orca_view: orcaView(source, {enabled: source.orca_view === true})
  };
  if (!store.ok) return {ok: false, complete: false, reason: store.reason, on: null, activity: 'unverifiable', agents: [], claims: [], resolved_claims: [], bindings: [], held: [], trees, unresolved: [{reason: store.reason}], leftovers: [], evidence};
  if (!resolutions.ok) evidence.session_store = {...evidence.session_store, resolutions_warning: resolutions.reason};

  const liveTurn = new Map();
  for (const turn of store.turns) if (LIVE_TURN_STATES.includes(String(turn.state))) liveTurn.set(String(turn.session_id), turn);
  const liveChild = new Map();
  for (const child of store.children) if (LIVE_CHILD_STATES.includes(String(child.state))) liveChild.set(String(child.parent_session), child);

  const bindings = [];
  const agents = [];
  const claims = [];
  const resolved_claims = [];
  const held = [];
  const unresolved = [];
  const leftovers = [];
  for (const session of store.sessions) {
    const id = String(session.id);
    const treePath = session.worktree ? String(session.worktree) : '';
    const forRepo = bindingRepo(source, session, commonDir, cache);
    if (!forRepo) continue;
    const state = String(session.workspace_state || 'unbound');
    const managed = managedWorktree(source, session);
    const tree = treePath ? trees.find(t => key(t.path) === key(treePath)) : null;
    const exists = treePath ? fs.existsSync(treePath) : false;
    const open = session.ended_at === null || session.ended_at === undefined;
    const turn = liveTurn.get(id) || null;
    const child = liveChild.get(id) || null;
    // A CLAIM OF CURRENT WORK: the session is still open AND the node's own state records a turn
    // running for it, or a child it dispatched that has not settled. A merely open binding is an
    // allocation, not activity, and is named as such below.
    const claim = open && Boolean(turn || child);
    const corroborated = probe.available ? Boolean(holderOf(probe, treePath)) : null;
    const record = {
      session: id, parent: session.parent_session_id || '', state, managed,
      worktree: treePath.replaceAll('\\', '/'), registered: Boolean(tree),
      head: tree?.head || '', branch: tree?.branch || '', detached: Boolean(tree?.detached),
      ended_at: open ? null : session.ended_at, required: session.workspace_required === 1,
      recorded_branch: session.workspace_branch || '',
      owner: runtimeOwner(session),
      turn: turn ? {run_id: String(turn.run_id || ''), boot: String(turn.boot || ''), state: String(turn.state), updated_at: turn.updated_at} : null,
      child: child ? {child_id: String(child.child_id || ''), state: String(child.state), run_id: String(child.run_id || '')} : null,
      corroborated, claim: '', in_flight: false
    };
    // EVERY WAY A CLAIM FAILS TO BE POSITIVE HAS A NAME. An unresolved claim is never counted as
    // activity and never read as OFF: it makes the activity answer UNVERIFIABLE until the claim is
    // settled by the owning runtime; unsupported prose receipts cannot settle it.
    if (claim) {
      if (!treePath || !exists || !tree) record.claim = 'activity_claim_without_a_registered_worktree';
      else if (RESOLVED_STATES.includes(state)) record.claim = `activity_claim_on_a_resolved_binding_${state}`;
      else if (UNRESOLVED_STATES.includes(state)) record.claim = `activity_claim_during_binding_transition_${state}`;
      else if (state !== 'allocated') record.claim = `in_flight_binding_state_${state}`;
      else if (!turn && corroborated !== true) record.claim = 'child_completion_claim_without_a_live_turn_or_process';
      else record.in_flight = true;
    }
    bindings.push(record);
    if (treePath && managed) held.push(record);
    if (record.in_flight) {
      // Unsupported legacy receipts are read for audit only, never settlement.
      agents.push(record);
      continue;
    }
    if (claim) {
      claims.push(record);
      unresolved.push({session: id, reason: record.claim, worktree: record.worktree, child_id: record.child?.child_id || '', run_id: record.turn?.run_id || '', boot: record.turn?.boot || '', resolution: 'refused: exact_owner_settlement_and_drain_unavailable; inspect owning runtime operations and resource claims'});
      continue;
    }
    if (RESOLVED_STATES.includes(state)) {
      if (state === 'parked') {
        // A parked binding is a retained tree at an exact detached tip with an empty branch;
        // the plan's exact tip is checked by the registry proof, here the shape is checked.
        if (!exists) unresolved.push({session: id, reason: 'parked_binding_tree_missing', worktree: record.worktree});
        if (exists && (record.recorded_branch || tree?.branch)) unresolved.push({session: id, reason: 'parked_binding_still_on_a_branch', worktree: record.worktree});
        if (exists && !tree?.detached) unresolved.push({session: id, reason: 'parked_binding_not_detached', worktree: record.worktree});
        if (exists && !tree) unresolved.push({session: id, reason: 'parked_binding_unregistered_tree', worktree: record.worktree});
      } else if (exists) {
        unresolved.push({session: id, reason: 'released_binding_tree_present', worktree: record.worktree});
      }
      continue;
    }
    if (UNRESOLVED_STATES.includes(state)) {
      unresolved.push({session: id, reason: `binding_transition_unresolved_${state}`, worktree: record.worktree});
      continue;
    }
    // Not resolved, not in flight: an allocation this repository still holds. That is WORK TO DO,
    // not activity and not a broken identity - so it is reported separately (`leftovers`). The
    // completion proofs fold it into their unresolved set; the freeze/retirement fence does not,
    // because those bindings are exactly the objects a retirement plan is about to settle.
    if (treePath && managed) leftovers.push({session: id, reason: 'managed_binding_not_reconciled', state, worktree: record.worktree});
  }

  // A registered managed tree with NO binding at all is an unowned leftover.
  for (const tree of trees) {
    if (key(tree.path) === key(source.repo)) continue;
    if (!key(tree.path).startsWith(`${key(source.data)}/wa-worktree-`)) continue;
    if (!bindings.some(b => key(b.worktree) === key(tree.path))) unresolved.push({reason: 'unowned_managed_worktree', worktree: tree.path, head: tree.head, branch: tree.branch});
  }
  // An unreadable resolution record cannot silently drop a resolution.
  if (!resolutions.ok) unresolved.push({reason: resolutions.reason, file: resolutions.file});

  // THE THREE-VALUED ANSWER. `on` is positively observed work; `off` is a complete inventory with
  // no claim at all; anything else is UNVERIFIABLE and must never be treated as OFF.
  const activity = agents.length ? 'on' : claims.length ? 'unverifiable' : 'off';
  return {
    ok: true, complete: true, activity, on: activity === 'on', off: activity === 'off', agents, claims, resolved_claims, bindings, held, trees, unresolved, leftovers,
    evidence: {...evidence, activity, in_flight: agents.length, unresolved_activity_claims: claims.length, resolved_activity_claims: resolved_claims.length, managed_bindings: held.length, unresolved: unresolved.length, leftovers: leftovers.length}
  };
}

export function runtimeOwner(session) {
  const start = decodeJSON(session.workspace_start_state, {});
  const boot = start?.executor?.owner_boot || '';
  return boot ? `runtime:${session.id}:${boot}` : `runtime:${session.id}`;
}

// THE DERIVED WAVE STATE. `activity` is the ON/OFF fact; `convergence` names whether the wave's
// own completion was verified; `runtime_state` is what the wave may report. A row never makes a
// wave active, and an unverifiable convergence is a named state, never a silent completion.
export function waveActivity(source, row) {
  const bookkeeping = String(row?.state || 'pending');
  const legacy = row?.legacy ? decodeJSON(row.legacy, null) : null;
  // A wave whose convergence was never verified is a NAMED state, never a silent completion.
  // `legacy-unverified` is the row a documented migration recorded: it never ran its steps, and
  // nothing is in flight, so it is off - and visibly unverified rather than quietly complete.
  const withdrawn=bookkeeping==='withdrawn' && withdrawalProof(row);
  const convergence = withdrawn ? 'not-run' : bookkeeping === 'complete' ? 'verified' : bookkeeping === 'blocked' ? 'unverified' : legacy ? 'legacy-unverified' : 'open';
  let inventory = null;
  let activity = 'off';
  let reason = '';
  if (source && source.kind === 'node-runtime') {
    inventory = activityInventory(source);
    if (!inventory.ok) { activity = 'unverifiable'; reason = inventory.reason; }
    else {
      activity = inventory.activity;
      // A claim that could not be resolved positively is NAMED, so the caller can consult it.
      if (activity === 'unverifiable') reason = `unresolved_activity_claims:${inventory.claims.map(claim => `${claim.claim}:${claim.session}`).join('|')}`;
    }
  } else {
    activity = 'unverifiable';
    reason = source?.kind === 'none' ? 'no_activity_source_declared' : 'activity_source_unavailable';
  }
  // `unknown` is its own reported state: an activity answer that could not be observed is neither
  // active nor idle, and must never be reported as either.
  const runtime_state = convergence === 'verified' ? 'complete' : activity === 'on' ? 'active' : activity === 'unverifiable' ? 'unknown' : withdrawn ? 'withdrawn' : convergence === 'open' ? 'idle' : 'unverified';
  return {
    wave_id: row?.id, bookkeeping_state: bookkeeping, activity, convergence, runtime_state, legacy_migrated: Boolean(legacy),
    claims: (inventory?.claims || []).map(claim => ({session: claim.session, claim: claim.claim, worktree: claim.worktree, child_id: claim.child?.child_id || '', run_id: claim.turn?.run_id || claim.child?.run_id || '', boot: claim.turn?.boot || ''})),
    reason: reason || (withdrawn ? 'never-admitted plan withdrawn; original history retained; convergence not verified' : convergence === 'verified' ? '' : convergence === 'legacy-unverified' ? 'legacy row: its steps never ran and its convergence was never verified' : String(row?.reason || '')),
    agents: inventory?.agents || [], evidence: inventory?.evidence || null, unresolved: inventory?.unresolved || []
  };
}
