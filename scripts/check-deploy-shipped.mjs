#!/usr/bin/env node
// The shipped set is declared once (scripts/deploy-shipped.json) and read by the hook's predicate. This
// check is what keeps that declaration from drifting away from the installers, and it exists because the
// first version of the predicate *was* a hand-written list beside the installer: it missed `jobs/**`
// (which scripts/deploy.sh installs into the sentinel's job store) and `scripts/upgrade.sh` (which
// installs itself), so a child that changed what the node runs was reported as having no install impact.
// A missing class is exactly the failure this hook exists to prevent, and a list nobody re-derives is how
// it happens.
//
// What it does, in order:
//   1. parses scripts/deploy.sh and scripts/upgrade.sh for every source they install (literal
//      `$ROOT/...` paths and globs, plus the installer variables it knows by name: `$0`, `$NEW`,
//      `$SOURCE_UI`, `$DEPLOY_SRC`, `$LIB_SRC`, `$SOURCE_ROOT/skills/*`);
//   2. runs scripts/ship-wave.mjs into a scratch directory and checks every file it writes;
//   3. asserts the predicate (imported from scripts/subagent-return-hook.mjs, not re-implemented) says
//      "shipped" for a concrete instance of each rule, and "not shipped" for a control set - so the check
//      fails both when a copied path is missing and when the predicate has become "everything".
//
// Exit codes: 0 ok; 1 a copied path the manifest does not cover, a rule the predicate denies, or a
// control path the predicate claims; 4 usage or an unreadable input.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {loadShipped, shipsToDeploy} from './subagent-return-hook.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '..');
let checked = 0;
function check(value, label) {
  if (!value) {
    process.stderr.write(`deploy-shipped: FAIL ${label}\n`);
    process.exitCode = 1;
    throw Object.assign(new Error(label), {failed: true});
  }
  checked += 1;
}

/// Installer variables whose value is a source path, named explicitly rather than guessed: each is read
/// from the installer's own assignment and asserted below.
const INSTALLER_VARIABLES = {
  deploy: {DEPLOY_SRC: 'scripts/deploy.sh', LIB_SRC: 'scripts/lib/service-target.sh'},
  upgrade: {NEW: 'rust/', SOURCE_UI: 'ui/'},
};

function installerSources(file) {
  const text = fs.readFileSync(file, 'utf8');
  const rules = new Set();
  const variables = file.endsWith('upgrade.sh') ? INSTALLER_VARIABLES.upgrade : INSTALLER_VARIABLES.deploy;
  for (const [name, target] of Object.entries(variables)) {
    // The variable must still be assigned in the installer; if it is gone, this table is stale and the
    // rule it stands for has to be re-derived rather than silently kept.
    check(new RegExp(`(^|\\s)(export\\s+)?${name}=`).test(text), `${path.basename(file)} still assigns $${name} (${target})`);
    rules.add(target);
  }
  if (file.endsWith('upgrade.sh')) {
    // `$0` is this script: upgrade.sh installs itself.
    check(text.includes('cp -f "$0"'), 'upgrade.sh still installs itself');
    check(text.includes('"$SOURCE_ROOT"/skills/*'), 'upgrade.sh still installs skills/*');
    rules.add('scripts/upgrade.sh');
    rules.add('skills/');
  }
  // Only the lines that install something: a `cp`/`cp -R`, or the loop that feeds one. Every other
  // mention of a tree path (a `[ -d ... ]` test, a build manifest path) is not a copy, and asserting the
  // predicate covers it would be asserting a rule nobody declared.
  for (const line of text.split(/\r?\n/)) {
    if (!/\bcp\s+-[fR]|for (source|skill_source) in/.test(line)) continue;
    for (const match of line.matchAll(/"\$(?:ROOT|SOURCE_ROOT)\/([^"\s]+)"/g)) {
      if (match[1].includes('$')) continue;
      rules.add(match[1]);
    }
  }
  return [...rules];
}

/// One concrete path that the rule covers, so the predicate is asked about a real file rather than the
/// rule's own spelling.
function exampleFor(rule) {
  if (rule.endsWith('/')) {
    const found = walk(path.join(root, rule)).find((entry) => entry !== '');
    return found ? `${rule}${found}` : null;
  }
  if (rule.includes('*')) {
    const directory = path.dirname(path.join(root, rule));
    const pattern = path.basename(rule);
    const prefix = pattern.slice(0, pattern.indexOf('*'));
    let entries = [];
    try { entries = fs.readdirSync(directory); } catch { return null; }
    const hit = entries.filter((entry) => entry.startsWith(prefix)).sort()[0];
    return hit ? `${path.dirname(rule)}/${hit}` : null;
  }
  return fs.existsSync(path.join(root, rule)) ? rule : null;
}

function walk(directory, limit = 4000) {
  const out = [];
  const stack = [''];
  while (stack.length > 0 && out.length < limit) {
    const relative = stack.pop();
    let entries = [];
    try { entries = fs.readdirSync(path.join(directory, relative), {withFileTypes: true}); } catch { continue; }
    for (const entry of entries) {
      const next = relative === '' ? entry.name : `${relative}/${entry.name}`;
      if (entry.isDirectory()) stack.push(next);
      else out.push(next);
    }
  }
  return out;
}

function shipWaveFiles() {
  const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-ship-check-'));
  try {
    const result = spawnSync(process.execPath, [path.join(here, 'ship-wave.mjs'), root, scratch], {encoding: 'utf8', windowsHide: true, timeout: 120000});
    check(result.status === 0, `ship-wave.mjs runs (${result.stderr || result.error?.message || ''})`);
    return walk(path.join(scratch, 'scripts'));
  } finally {
    fs.rmSync(scratch, {recursive: true, force: true});
  }
}

function main() {
  // An explicit manifest is how the suite falsifies this check: point it at a manifest with a copied path
  // removed and the check must go red naming that path.
  const shipped = loadShipped(process.argv[2] || undefined);
  check(!shipped.error, `the manifest is readable (${shipped.error || shipped.file})`);
  const manifest = shipped.manifest;

  const rules = [...installerSources(path.join(here, 'deploy.sh')), ...installerSources(path.join(here, 'upgrade.sh'))];
  // The manifest itself has to reach the install: the hook reads it from beside its own script, so a
  // deploy that ships the hook without the declaration would make every verdict `cannot be computed`.
  check(fs.readFileSync(path.join(here, 'deploy.sh'), 'utf8').includes('scripts/deploy-shipped.json'),
    'deploy.sh ships scripts/deploy-shipped.json beside the hook scripts');
  const examples = [];
  for (const rule of rules) {
    const example = exampleFor(rule);
    if (example === null) {
      process.stderr.write(`deploy-shipped: note: rule ${rule} has no example in this tree (nothing to check)\n`);
      continue;
    }
    check(shipsToDeploy(example, manifest), `the predicate covers ${example} (rule ${rule})`);
    examples.push(example);
  }

  const fromShipWave = shipWaveFiles();
  check(fromShipWave.length > 0, 'ship-wave.mjs wrote at least one file');
  for (const file of fromShipWave) {
    check(shipsToDeploy(`scripts/${file}`, manifest), `the predicate covers scripts/${file} (written by ship-wave.mjs)`);
  }
  for (const entry of manifest.invoked_but_not_installed || []) {
    check(!shipsToDeploy(entry, manifest), `${entry} is declared as invoked but not installed, and the predicate agrees`);
  }

  // The other direction: a predicate that answers "shipped" for everything is as useless as one that
  // answers it for nothing.
  for (const control of ['docs/JOBS.md', 'tests/fixture.cjs', 'review/notes.md', 'scripts/delivery-record.mjs',
    'scripts/test-subagent-return-hook.cjs', 'scripts/ship-wave.mjs', 'scripts/lib/nested/probe.cjs', 'README.md']) {
    check(!shipsToDeploy(control, manifest), `the predicate does not claim ${control}`);
  }

  console.log(`deploy shipped ok (${checked} checks; ${rules.length} rules from the installers, ${examples.length} examples, ${fromShipWave.length} from ship-wave.mjs)`);
}

try {
  main();
} catch (error) {
  if (!error.failed) {
    process.stderr.write(`deploy-shipped: ${error.stack || error}\n`);
    process.exitCode = 4;
  }
}
