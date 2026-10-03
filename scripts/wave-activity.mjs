#!/usr/bin/env node
// Read-only activity observation. Resolution is fail-closed: this source exposes
// no authenticated exact-owner terminal settlement + descendant/effect drain.
// Caller prose, terminal transcripts and negative/missing process scans are not proof.
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {activityInventory, activityStore, POSITIVE_CLAIM, readResolutions, sourceOfConfig} from './lib/wave-activity.mjs';
const fail = reason => { throw new Error(reason); };
export const REFUSAL = 'exact_owner_settlement_and_drain_unavailable';
const recovery = 'Owning runtime: inspect operation status and await full settlement (not shell exit); inspect retained resource claims and reconcile unknown effects with exact owner/run evidence through the sanctioned operator resource path. Preserve claims and receipts. See docs/CONCURRENCY.md and docs/EXECUTION.md.';
function claimSummary(record, claim, positive = false) {
  return {session: record.session, worktree: record.worktree, run_id: record.turn?.run_id || record.child?.run_id || '', child_id: record.child?.child_id || '', boot: record.turn?.boot || '', corroborated: record.corroborated ?? null, why: claim, positive, resolvable: false, resolution: `refused: ${REFUSAL}`, recovery};
}
function inventoryOf(configFile) {
  const source = sourceOfConfig(JSON.parse(fs.readFileSync(configFile, 'utf8')));
  const inventory = activityInventory(source);
  if (!inventory.ok) fail(`activity_inventory_unavailable:${inventory.reason}`);
  return {source, inventory};
}
export function observe(configFile) {
  const {source, inventory} = inventoryOf(configFile);
  const store = activityStore(source), resolutions = readResolutions(store.resolutions);
  return {
    ok: true, activity: inventory.activity, on: inventory.on, off: inventory.off,
    agents: inventory.agents.map(agent => ({session: agent.session, worktree: agent.worktree, run_id: agent.turn?.run_id || '', child_id: agent.child?.child_id || '', corroborated: agent.corroborated})),
    activity_claims: [...inventory.agents.map(x => claimSummary(x, POSITIVE_CLAIM, true)), ...inventory.claims.map(x => claimSummary(x, x.claim))],
    unresolved_activity_claims: inventory.claims.map(x => claimSummary(x, x.claim)),
    resolved_activity_claims: [],
    unresolved: inventory.unresolved, leftovers: inventory.leftovers.length,
    resolutions: {file: store.resolutions, ok: resolutions.ok, count: resolutions.resolutions.length, replay: 'refused', reason: REFUSAL},
    evidence: inventory.evidence
  };
}
export function resolve(configFile, session, evidence, flags = {}) {
  if (!session) fail('session_required');
  if (typeof evidence !== 'string' || !evidence.trim()) fail('observed_resolution_evidence_required');
  const {inventory} = inventoryOf(configFile);
  if (![...inventory.claims, ...inventory.agents].some(x => x.session === session)) fail(`claim_not_found:${session}`);
  // SAFETY_CREATION: never persist an unsupported settlement, including idempotent prose.
  fail(`${REFUSAL}:${session}:${recovery}`);
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [action, config, session, evidence] = process.argv.slice(2);
  try {
    if (!config) fail('usage: observe CONFIG | resolve CONFIG SESSION EVIDENCE (unsupported settlement refuses)');
    const result = action === 'observe' ? observe(config) : action === 'resolve' ? resolve(config, session, evidence) : fail('unknown_action');
    console.log(JSON.stringify(result, null, 2));
  } catch (e) { console.log(JSON.stringify({ok: false, error: e.message})); process.exitCode = 1; }
}
