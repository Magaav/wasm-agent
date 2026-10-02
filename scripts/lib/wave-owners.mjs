// OWNERSHIP FROM OUR OWN INVENTORY.
//
// Who owns a tree, and whether that owner has settled, is answered from the node's own records:
// the managed session workspaces and their recorded `workspace_*` state, the real Git worktree
// list, and the node's own turn/process state (`scripts/lib/wave-activity.mjs`). No third-party
// CLI is required, and an Orca binary that happens to exist is at most an optional viewer whose
// absence changes no verdict.
//
// The guarantees are the ones the Orca-backed version provided: no unowned or unresolved
// leftovers, exact tree/tip agreement, and parked/released bindings reconciled - each one now
// provable from the repository and the node runtime alone.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {activityInventory, sourceOfConfig, key, runtimeOwner} from './wave-activity.mjs';

const digest = value => crypto.createHash('sha256').update(JSON.stringify(value)).digest('hex');
const nonemptyString = value => typeof value === 'string' && value.length > 0;
const finiteStamp = value => typeof value === 'number' && Number.isFinite(value) && value > 0;

// A positively identified agent: every field that names it is present, so a comparison can never
// succeed by comparing two absences.
export function positiveInFlightAgent(agent) {
  if (!agent || !nonemptyString(agent.session) || !nonemptyString(agent.worktree)) return false;
  if (agent.in_flight !== true) return false;
  if (!agent.turn && !agent.child) return false;
  if (agent.turn) {
    if (!nonemptyString(agent.turn.run_id) || !nonemptyString(agent.turn.boot) || agent.turn.state !== 'active') return false;
    if (!finiteStamp(agent.turn.updated_at)) return false;
  }
  if (agent.child && !nonemptyString(agent.child.child_id)) return false;
  return true;
}

// A positively reconciled binding: released (no tree left behind) or parked (a real detached
// exact tip with an empty branch). Anything else is not settled and is named as unresolved.
export function positiveResolvedBinding(binding) {
  if (!binding) return false;
  if (binding.state === 'released') return !binding.registered;
  if (binding.state === 'parked') return Boolean(binding.registered) && binding.detached === true && !binding.branch && !binding.recorded_branch;
  return false;
}

export function ownerInventory(config) {
  const source = sourceOfConfig(config);
  const inventory = activityInventory(source);
  if (!inventory.ok) throw Error(`owner_inventory_unavailable:${inventory.reason}`);
  const unresolved = [...inventory.unresolved];
  // Every agent this repository counts as working must be positively identified, or the
  // inventory cannot speak for it: an identity-less owner fails closed rather than comparing
  // undefined against undefined. A local process that does not name the tree CORROBORATES
  // nothing and vetoes nothing - a turn is between process spawns more often than a lane is idle.
  for (const agent of inventory.agents) {
    if (!positiveInFlightAgent(agent)) unresolved.push({session: agent.session, reason: 'in_flight_agent_identity_incomplete', worktree: agent.worktree});
  }
  const agents = inventory.agents.map(agent => ({session: agent.session, worktree: agent.worktree, state: agent.state, owner: agent.owner, run_id: agent.turn?.run_id || '', boot: agent.turn?.boot || '', child_id: agent.child?.child_id || ''}));
  const bindings = inventory.bindings.map(binding => ({session: binding.session, state: binding.state, worktree: binding.worktree, branch: binding.branch, recorded_branch: binding.recorded_branch, head: binding.head, detached: binding.detached, registered: binding.registered, owner: binding.owner, in_flight: binding.in_flight}));
  return {
    ok: !unresolved.length, complete: true, unresolved, leftovers: inventory.leftovers, agents, bindings, held: inventory.held.length,
    activity: inventory.activity, unresolved_activity_claims: inventory.claims.length, resolved_activity_claims: inventory.resolved_claims.length,
    trees: inventory.trees.map(tree => ({path: tree.path, head: tree.head, branch: tree.branch, detached: tree.detached})),
    evidence: inventory.evidence, third_party: 'none'
  };
}

export function frozenOwners(config, wave, main, target = null, tip = null) {
  if (!config.owner_freeze) throw Error('current_owner_freeze_required');
  const ticket = JSON.parse(fs.readFileSync(config.owner_freeze, 'utf8'));
  if (ticket.schema !== 1 || ticket.kind !== 'wave-owner-freeze' || ticket.wave_id !== wave || ticket.main !== main ||
      key(ticket.repo) !== key(config.repo) || !ticket.reviewer || ticket.reviewer === ticket.issuer || !Array.isArray(ticket.trees)) {
    throw Error('owner_freeze_identity_unverified');
  }
  const current = ownerInventory(config);
  if (!current.ok) return current;
  // Bind current session/turn identity. A timestamp or an old run alone never earns quiescence:
  // every agent working now must have been frozen, with the same run and boot.
  for (const agent of current.agents) {
    const frozen = ticket.agents?.find(old => old.session === agent.session);
    if (!frozen || frozen.run_id !== agent.run_id || frozen.boot !== agent.boot || key(frozen.worktree) !== key(agent.worktree)) throw Error('owner_takeover_or_inventory_movement');
  }
  // Every binding recorded at freeze time must still be the same owner at the same tip, and no new
  // binding may have appeared. The tree's own Git branch is deliberately NOT compared: detaching a
  // parked tree is part of the retirement this fence authorizes. What must not move is the owner
  // identity, the session's recorded branch, and the exact tip.
  for (const binding of current.bindings) {
    const frozen = ticket.bindings?.find(old => old.session === binding.session);
    if (!frozen) throw Error('current_binding_appeared_after_freeze');
    if ((frozen.owner || '') !== (binding.owner || '')) throw Error('owner_identity_changed_after_freeze');
    if ((frozen.recorded_branch || '') !== (binding.recorded_branch || '')) throw Error('current_binding_changed_after_freeze');
    if (frozen.registered && binding.registered && (frozen.head || '') !== (binding.head || '')) throw Error('exact_tree_tip_moved_after_freeze');
  }
  for (const frozen of ticket.bindings || []) {
    if (!current.bindings.some(binding => binding.session === frozen.session)) throw Error('frozen_binding_missing_now');
  }
  if (target) {
    const tree = ticket.trees.find(entry => key(entry.path) === key(target));
    if (!tree || tree.tip !== tip || !tree.owner_id || !tree.evidence?.length) throw Error('exact_tree_owner_settlement_required');
    const live = current.trees.find(entry => key(entry.path) === key(target));
    if (live && tree.tip && live.head !== tree.tip) throw Error('exact_tree_tip_moved_after_freeze');
    return {...current, settled: true, worktree: target, tip, owner_id: tree.owner_id, evidence: tree.evidence, freeze_sha256: digest(ticket)};
  }
  return {...current, freeze_sha256: digest(ticket)};
}

export {runtimeOwner};
