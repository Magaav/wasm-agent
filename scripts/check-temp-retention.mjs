#!/usr/bin/env node
// A temp family needs a retention or cleanup path in the same file as the code that mints it.
//
// WHY THIS EXISTS. `scripts/` mints temporary directories and files by the thousand and almost every
// minter keeps one of them forever: on 2026-09-30 the OS temp directory held 3298 `wa-subagent-test-*`
// directories, 5838 `wajobstestdb*` files, 475 `wa-operation-control*` entries and 252 `wa-session-tree*`
// directories, none of them younger than a day. They are individually small, and that is exactly why they
// were never noticed - the same night, a gate died on a full disk (`os error 112`) ten seconds into a
// build. The count is the leak: a family with no bound grows with every run of the suite, and no reviewer
// sees it in a diff. This check is the mechanical half of the fix: the next family fails in a gate, at
// review, instead of at 1.9 GB.
//
// WHAT IT IS, EXACTLY. It walks the tracked files under `scripts/` and looks for the *act* of minting a
// temporary path - `mktemp`, `mkdtemp`/`mkdtempSync`, PowerShell's `New-TemporaryFile`/`GetTempPath`, or a
// literal family under a temp root (`/tmp`, `$TMPDIR`, `os.tmpdir()`, `$env:TEMP`) - and then requires one
// of these *in the same file*:
//
//   * a removal path: `rm -r`/`rm -f`, `fs.rm`/`rmSync`/`rmdir`, `Remove-Item`, `shutil.rmtree`, or a
//     `trap` that removes;
//   * a declared retention: a line carrying `temp-retention: <reason>` - the marker is a decision with a
//     reason, not a flag, and a marker with no reason fails.
//
// It is NOT a semantic check and it does not prove that every path out of a script removes its temp: a
// file that mints three families and removes one passes, and a family a script *declares* it keeps forever
// passes too (that hole is deliberate and is what `node scripts/test-temp-retention-check.cjs` falsifies:
// the marker is prose, and only a reviewer can hold it to account). What it catches is the case that
// actually happened here - a file that mints a family and never mentions it again, so nothing bounds it.
//
// A file that already leaks is listed under DEFERRED with its owner and the edit it needs: printed on
// every run, never fatal, so this check can be wired into the gate it is protecting (an entry that stops
// matching is reported `resolved`, so the list shrinks instead of rotting). Fixing them is not this
// change's job; naming them is.
//
// Run: node scripts/check-temp-retention.mjs
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const SELF = 'scripts/check-temp-retention.mjs';
const RETENTION = /temp-retention:\s*(\S[^\n]*)/;
const RETENTION_EMPTY = /temp-retention:\s*$/;

// Minting, as three literal shapes. Each is a *creation* of a temp path, not a reference to one.
const MINTS = [
  { id: 'mktemp', what: 'mktemp', re: /\bmktemp\b/ },
  { id: 'mkdtemp', what: 'mkdtemp', re: /\bmkdtemp(?:Sync)?\s*\(/ },
  { id: 'powershell-temp', what: 'New-TemporaryFile / GetTempPath', re: /New-TemporaryFile|\[System\.IO\.Path\]::GetTempPath|\$env:TEMP\b/ },
  {
    id: 'temp-family',
    what: 'a litered family under a temp root',
    re: /(?:\/tmp\/|\$TMPDIR|os\.tmpdir\(\)|\$\{TMPDIR:-[^}]*\}|\$env:TEMP\b)[^\n]{0,50}[A-Za-z0-9][A-Za-z0-9._-]{2,}/,
  },
];

// A removal path in the file. Deliberately broad: this check's failure is "no mention at all", and a
// file that removes *something* has said what it keeps and why somewhere a reviewer can read.
const CLEANUP = [
  { id: 'rm', re: /\brm\s+-[rRf]+|\brm\s+["'$]|\brm\s+-/ },
  { id: 'node-rm', re: /\brmSync\s*\(|fs\.rm\s*\(|fs\.rmdir|rmdirSync\s*\(|\brmdir\b/ },
  { id: 'powershell-remove', re: /Remove-Item|Remove-ItemProperty/ },
  { id: 'python-rmtree', re: /shutil\.rmtree|os\.remove\s*\(/ },
  { id: 'trap-rm', re: /trap\s+[^\n]*\brm\b/ },
];

// Files that already mint a family with no retention or cleanup path. Every one of them was found by this
// check's first run over the repository on 2026-09-30; the measured count in temp beside each family is
// what that run read on disk. Reported on every run, never fatal, and none of them is fixed here: they are
// other deliveries' paths, and the point of the list is that the leak is now visible at review.
const DEFERRED_WHY = 'a fixture created per case and never removed: add the removal where it is created';
const DEFERRED = [
  'scripts/experiment-tool-choice.cjs',
  'scripts/review-placement-leak.cjs',
  'scripts/screenshot.ps1',
  'scripts/test-changeset.lua',
  'scripts/test-cli-terminal.mjs',
  'scripts/test-context-budget.lua',
  'scripts/test-efficiency-report.lua',
  'scripts/test-empty-reply.lua',
  'scripts/test-gate-lane.cjs',
  'scripts/test-guest.lua',
  'scripts/test-job-pipeline.cjs',
  'scripts/test-job-subagents.cjs',
  'scripts/test-jobs.cjs',
  'scripts/test-lua-root-notice.cjs',
  'scripts/test-memory-window.lua',
  'scripts/test-merge-audit.mjs',
  'scripts/test-operation-control.cjs',
  'scripts/test-operation-recovery.cjs',
  'scripts/test-orchestration-e2e.cjs',
  'scripts/test-orchestrator.cjs',
  'scripts/test-prefix-stability.lua',
  'scripts/test-recovery.lua',
  'scripts/test-resource-claims.cjs',
  'scripts/test-run-recovery.cjs',
  'scripts/test-session-title.lua',
  'scripts/test-sqlite-isolation.cjs',
  'scripts/test-sqlite-lifecycle.cjs',
  'scripts/test-subagents-policy.cjs',
  'scripts/test-subagents.cjs',
  'scripts/test-update-watcher.lua',
  'scripts/wa-ui.ps1',
].map(file => ({ file, why: DEFERRED_WHY })).concat([
  // Minted after this list was written and found when the full gate first ran on Linux (openclaw, 30/10,
  // v0.1.0-alpha.12): main had reached 58 offenders, so no full gate had passed since. Named here so the
  // gate can protect against the next one; each still needs the removal where it mints.
  'scripts/agent-benchmark-arm.mjs',
  'scripts/agent-benchmark-docker.mjs',
  'scripts/agent-benchmark-forced-pilot.mjs',
  'scripts/agent-benchmark-pilot-input.mjs',
  'scripts/agent-benchmark-pilot.mjs',
  'scripts/agent-benchmark-sandbox.mjs',
  'scripts/agent-benchmark-worth-fixtures.mjs',
  'scripts/codemode-build.mjs',
  'scripts/fixtures/benchmark-sandbox-native.lua',
  'scripts/lib/delivery-local.mjs',
  'scripts/lib/wave-current-source.mjs',
  'scripts/producer-admission.mjs',
  'scripts/review-serving-exact-tip.cjs',
  'scripts/test-agent-benchmark-sandbox.mjs',
  'scripts/test-agent-benchmark-vault-container.mjs',
  'scripts/test-binding-permanent.cjs',
  'scripts/test-binding-runtime.cjs',
  'scripts/test-binding.cjs',
  'scripts/test-chat-health.cjs',
  'scripts/test-coordinator-steps.cjs',
  'scripts/test-failure-notice.cjs',
  'scripts/test-install-speed.mjs',
  'scripts/test-lightweight-browser.cjs',
  'scripts/test-live-children-cards.cjs',
  'scripts/test-mcp-session.mjs',
  'scripts/test-mcp.mjs',
  'scripts/test-native-target-alias.cjs',
  'scripts/test-native-target-resource.cjs',
  'scripts/test-orchestration-ui.cjs',
  'scripts/test-orchestrator-active.cjs',
  'scripts/test-orchestrator-queue-race.cjs',
  'scripts/test-peer-sync.cjs',
  'scripts/test-provider-binding-negative.cjs',
  'scripts/test-provider-inline-browser.cjs',
  'scripts/test-provider-management-http.cjs',
  'scripts/test-provider-management-ui.cjs',
  'scripts/test-provider-management.cjs',
  'scripts/test-provider-required-ui.cjs',
  'scripts/test-quarantined-retirement.cjs',
  'scripts/test-redact-secrets.lua',
  'scripts/test-run-counts.cjs',
  'scripts/test-run-key-http.cjs',
  'scripts/test-sentinel-private-install.cjs',
  'scripts/test-sentinel-real-parent.cjs',
  'scripts/test-sentinel-service-installer.ps1',
  'scripts/test-serving-contract.cjs',
  'scripts/test-serving-guards.cjs',
  'scripts/test-serving-http.cjs',
  'scripts/test-serving-packet.cjs',
  'scripts/test-stream-cut-recovery.lua',
  'scripts/test-turn-ownership.cjs',
  'scripts/test-wave-current-ref-transaction.mjs',
  'scripts/test-wave-current-source.mjs',
  'scripts/test-wave-native-recovery.mjs',
  'scripts/test-wave-truncated-registry.cjs',
  'scripts/test-web-http-outcomes.mjs',
  'scripts/test-web.mjs',
  'scripts/test-worker-integrate.cjs',
].map(file => ({ file, why: DEFERRED_WHY + ' (found 30/10)' })));

// The family a minting line creates, for the report only: the quoted template with its temp root and its
// nonce removed (`"${TMPDIR}/wa-subagent-test-XXXXXX"` -> `wa-subagent-test-*`). It is read out of the
// line rather than declared, so a family this check has never seen is still named when it is flagged.
function familyOf(text) {
  const quoted = /["'`]([^"'`]{2,160})["'`]/g;
  // Prefer a literal that looks like a temp *template* over the first quoted string on the line: a
  // scratch database named inside it would otherwise be reported as the family.
  const literals = [...text.matchAll(quoted)].map(m => m[1]);
  const template = literals.find(l => /(?:XXXX|TMPDIR|tmpdir|\/tmp|%TEMP%|\$env:TEMP|Temp\b)/.test(l)) || literals[0] || text;
  const raw = template.replace(/^.*[\\/]/, '').trim();
  if (/^(mktemp|mkdtemp)/i.test(raw)) return 'the OS temp directory (no template named)';
  const family = raw.replace(/X{3,}[\s\S]*$/, '*').replace(/\$\{[^}]*\}[\s\S]*$/, '*').replace(/\d{4,}[\s\S]*$/, '*');
  // A module specifier or a bare database name is a value on the minting line, not the family: say so
  // rather than dressing it up as one.
  if (!/^[A-Za-z0-9._-]*[a-z-]{2,}/.test(family) || /^[a-z]+:[a-z_]+$/.test(family) || family === '..') {
    return 'the family name is not readable from this line (see the mint line above)';
  }
  return family || raw;
}

function tracked() {
  const out = execFileSync('git', ['ls-files', '-z'], { cwd: root, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  return out.split('\0').filter(Boolean);
}

const files = tracked()
  .filter(f => f === SELF ? false : /^scripts\/.*\.(sh|bash|mjs|cjs|js|lua|ps1)$/.test(f))
  .filter(f => fs.existsSync(path.join(root, f)) && fs.statSync(path.join(root, f)).isFile())
  .sort();

const deferredBy = new Map(DEFERRED.map(entry => [entry.file, entry]));
let minters = 0, declared = 0, offenders = 0, deferred = 0, resolved = 0;
const failures = [];
const seenDeferred = new Set();

console.log('check-temp-retention: a temp family needs a retention or cleanup path in the same file');
console.log(`  root: ${root}`);
console.log(`  scanned ${files.length} tracked files under scripts/`);

for (const file of files) {
  const lines = fs.readFileSync(path.join(root, file), 'utf8').split('\n');
  const mint = [];
  for (let i = 0; i < lines.length; i++) {
    for (const shape of MINTS) {
      if (shape.re.test(lines[i])) { mint.push({ line: i + 1, shape: shape.what, text: lines[i].trim().slice(0, 140) }); break; }
    }
  }
  if (!mint.length) continue;
  minters++;
  const cleanup = CLEANUP.filter(shape => lines.some(line => shape.re.test(line))).map(shape => shape.id);
  const retentionLine = lines.findIndex(line => RETENTION.test(line));
  const emptyMarker = lines.findIndex(line => RETENTION_EMPTY.test(line));
  const detail = mint.map(m => `${m.line}:${m.shape} ${m.text}`).join(' | ');

  if (emptyMarker >= 0 && retentionLine < 0) {
    offenders++;
    failures.push(`${file} carries \`temp-retention:\` with no reason at line ${emptyMarker + 1}`);
    console.log(`  FAIL  ${file} declares a retention with no reason (line ${emptyMarker + 1}) - a marker with no reason is not a decision`);
    continue;
  }
  if (retentionLine >= 0) {
    declared++;
    console.log(`  RETAIN ${file} (${RETENTION.exec(lines[retentionLine])[1].slice(0, 90)}) - mint at ${mint[0].line}`);
    continue;
  }
  if (cleanup.length) {
    console.log(`  ok    ${file} (mint at ${mint[0].line}; removes via ${cleanup.join(', ')})`);
    continue;
  }
  const known = deferredBy.get(file);
  if (known) {
    deferred++; seenDeferred.add(file);
    console.log(`  DEFERRED ${file} (${familyOf(mint[0].text)})\n             minted: ${detail}\n             ${known.why}\n             owner: not this delivery's file - it is named in the delivery that added this check`);
    continue;
  }
  offenders++;
  failures.push(`${file} mints a temp family with no retention or cleanup path in this file`);
  console.log(`  FAIL  ${file} mints a temp family and never bounds it in this file`);
  console.log(`           ${detail}`);
  console.log('           add the removal path, or a `temp-retention: <reason>` line if keeping it is the decision');
}

for (const entry of DEFERRED) if (!seenDeferred.has(entry.file)) { resolved++; console.log(`  resolved  ${entry.file} no longer mints an unbounded family - delete its DEFERRED entry`); }

console.log(`\ncheck-temp-retention: ${offenders ? 'FAIL' : 'PASS'} (${files.length} files, ${minters} mint temp paths, ${declared} declared, ${deferred} deferred, ${resolved} resolved)`);
for (const failure of failures) console.log(`  failed: ${failure}`);
process.exitCode = offenders ? 1 : 0;
