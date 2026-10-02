#!/usr/bin/env node
// THE WAVE'S OWN ACTIVITY, OBSERVED AND - WHEN IT CANNOT BE RESOLVED BY OBSERVATION - RESOLVED
// BY NAME.
//
// Why this exists. A claim of current work that cannot be resolved positively (a turn whose tree is
// gone, a binding mid-release, a child completion nobody corroborates) must never be read as OFF -
// that would admit a second wave over live work - and must never be permanently ON either. So it is
// reported with a name, and this CLI is the named way out: the operator records, with evidence,
// that this exact claim is settled. The resolution binds the claim's identity, so a NEW claim (a
// different run, child, boot or tree) can never borrow it.
//
//   node scripts/wave-activity.mjs observe <config.json>
//   node scripts/wave-activity.mjs resolve <config.json> <session> "<observed evidence>" [--child <child_id>] [--run <run_id>] [--actor <who>]
//
// `observe` is read-only. `resolve` writes only the wave store's `activity-resolutions.json`.
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {activityInventory, activityStore, readResolutions, resolutionMatches, sourceOfConfig, writeResolution} from './lib/wave-activity.mjs';

const fail = reason => { throw new Error(reason); };

function options(argv) {
  const positional = [], flags = {};
  for (let i = 0; i < argv.length; i += 1) {
    const value = argv[i];
    if (value.startsWith('--')) { flags[value.slice(2)] = argv[i + 1]; i += 1; } else positional.push(value);
  }
  return {positional, flags};
}

function claimIdentity(claim) {
  return {session: claim.session, claim: claim.claim, worktree: claim.worktree, child_id: claim.child?.child_id || '', run_id: claim.turn?.run_id || claim.child?.run_id || '', boot: claim.turn?.boot || ''};
}

export function observe(configFile) {
  const source = sourceOfConfig(JSON.parse(fs.readFileSync(configFile, 'utf8')));
  const inventory = activityInventory(source);
  if (!inventory.ok) fail(`activity_inventory_unavailable:${inventory.reason}`);
  const store = activityStore(source);
  const resolutions = readResolutions(store.resolutions);
  return {
    ok: true, activity: inventory.activity, on: inventory.on, off: inventory.off,
    agents: inventory.agents.map(agent => ({session: agent.session, worktree: agent.worktree, run_id: agent.turn?.run_id || '', child_id: agent.child?.child_id || '', corroborated: agent.corroborated})),
    unresolved_activity_claims: inventory.claims.map(claim => ({...claimIdentity(claim), why: claim.claim, resolution: `node scripts/wave-activity.mjs resolve ${configFile} ${claim.session} "<what you observed>"`})),
    resolved_activity_claims: inventory.resolved_claims.map(claim => ({...claimIdentity(claim), why: claim.claim, resolved: claim.resolved})),
    unresolved: inventory.unresolved, leftovers: inventory.leftovers.length, resolutions: {file: store.resolutions, ok: resolutions.ok, count: resolutions.resolutions.length},
    evidence: inventory.evidence
  };
}

export function resolve(configFile, session, evidence, flags = {}) {
  if (!session) fail('session_required');
  if (typeof evidence !== 'string' || !evidence.trim()) fail('observed_resolution_evidence_required');
  const source = sourceOfConfig(JSON.parse(fs.readFileSync(configFile, 'utf8')));
  const inventory = activityInventory(source);
  if (!inventory.ok) fail(`activity_inventory_unavailable:${inventory.reason}`);
  const claim = inventory.claims.find(entry => entry.session === session);
  if (!claim) {
    if (inventory.agents.some(entry => entry.session === session)) fail(`claim_is_not_unresolved:${session}:activity_is_positively_on`);
    if (inventory.resolved_claims.some(entry => entry.session === session)) fail(`claim_already_resolved:${session}`);
    fail(`claim_not_found:${session}`);
  }
  const identity = claimIdentity(claim);
  // The operator must name the identity that distinguishes this claim from a later one.
  const named = identity.child_id || identity.run_id || identity.boot;
  const given = flags.child || flags.run || flags.boot || '';
  if (named && given !== named) fail(`claim_identity_required:${session}:--child|--run|--boot ${named}`);
  if (!named && (flags.child || flags.run || flags.boot)) fail(`claim_identity_mismatch:${session}:this claim names no child, run or boot`);
  const store = activityStore(source);
  const existing = readResolutions(store.resolutions);
  if (!existing.ok && fs.existsSync(store.resolutions)) fail(existing.reason);
  if (existing.resolutions.some(entry => resolutionMatches(entry, identity))) return {ok: true, session, claim: identity.claim, already_resolved: true, file: store.resolutions};
  const resolution = {...identity, evidence, at: Date.now(), by: flags.actor || process.env.WA_WAVE_ACTOR || 'operator'};
  writeResolution(store.resolutions, resolution);
  // REPORT WHAT THE RESOLUTION ACTUALLY DID: the inventory is read again, not assumed.
  const after = activityInventory(source);
  return {ok: true, session, claim: identity.claim, resolution, file: store.resolutions, activity_after: after.ok ? after.activity : 'unverifiable', unresolved_activity_claims_after: after.ok ? after.claims.length : null};
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [action, ...rest] = process.argv.slice(2);
  try {
    const {positional, flags} = options(rest);
    const [configFile, session, evidence] = positional;
    if (!configFile) fail('usage: observe CONFIG | resolve CONFIG SESSION EVIDENCE [--child|--run|--boot VALUE] [--actor WHO]');
    const result = action === 'observe' ? observe(configFile)
      : action === 'resolve' ? resolve(configFile, session, evidence, flags)
      : fail('usage: observe CONFIG | resolve CONFIG SESSION EVIDENCE [--child|--run|--boot VALUE] [--actor WHO]');
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
  } catch (e) {
    process.stdout.write(`${JSON.stringify({ok: false, error: e.message})}\n`);
    process.exitCode = 1;
  }
}
