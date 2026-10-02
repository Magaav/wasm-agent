#!/usr/bin/env node
// The shipped set is declared once (scripts/deploy-shipped.json) and read by the hook's predicate. This
// check is what keeps that declaration from drifting away from the installers, and it exists because the
// first version of the predicate *was* a hand-written list beside the installer: it missed `jobs/**`
// (which scripts/deploy.sh installs into the sentinel's job store) and `scripts/upgrade.sh` (which
// installs itself), so a child that changed what the node runs was reported as having no install impact.
// A missing class is exactly the failure this hook exists to prevent, and a list nobody re-derives is how
// it happens.
//
// The first version of THIS check then derived less than it claimed, which is the same failure one level
// up: it read only `cp -f`/`cp -R` and only the `"$ROOT/<path>"` spelling, so `"$ROOT"/<path>` (the
// quote-then-slash form deploy.sh uses for every glob), a plain `cp`, `install` and `mv` were invisible,
// and a rule whose example was absent from the tree was skipped with a note. Dropping `jobs/`,
// `scripts/whatsapp-*` or `scripts/subagent-return-*` from the manifest therefore stayed green. It now:
//
//   1. reads every copy-like line (`cp`, `cp -f`, `cp -R`, `install`, `mv`, and the loops that feed
//      them), in every quoting, and derives the tree paths they name;
//   2. resolves the installer variables whose value is a source path from the installer's own assignment
//      (falling back to a named declaration only where the value is not a tree path - a built binary);
//   3. refuses to pass a rule it cannot instantiate: a directory or glob with no example in the tree is
//      instantiated synthetically, and an exact path that neither exists nor is built by that same
//      installer is a failure naming the path - never a silent skip;
//   4. runs scripts/ship-wave.mjs and checks every file it writes;
//   5. asserts the predicate (imported from scripts/subagent-return-hook.mjs, not re-implemented) says
//      "shipped" for every derived rule and "not shipped" for a control set - so it fails both when a
//      copied path is missing and when the predicate has become "everything".
//
// Usage: node scripts/check-deploy-shipped.mjs [manifest.json] [--installers <dir>]
// Exit codes: 0 ok; 1 a copied path the manifest does not cover, a rule the predicate denies, an
// uninstantiable rule, or a control path the predicate claims; 4 usage or an unreadable input.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {loadShipped, shipsToDeploy} from './subagent-return-hook.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '..');
let checked = 0;
const notes = [];
function check(value, label) {
  if (!value) {
    process.stderr.write(`deploy-shipped: FAIL ${label}\n`);
    process.exitCode = 1;
    throw Object.assign(new Error(label), {failed: true});
  }
  checked += 1;
}
function note(text) {
  notes.push(text);
}

/// Installer variables whose value is a source path. The value is read from the installer's own
/// assignment; `declared` is used only when that value is not a tree path (a binary the installer was
/// handed, or built), and the check asserts the assignment still exists so this table cannot outlive it.
const INSTALLER_VARIABLES = {
  deploy: {
    DEPLOY_SRC: {declared: 'scripts/deploy.sh', why: 'deploy.sh installs its own copy'},
    LIB_SRC: {declared: 'scripts/lib/service-target.sh', why: 'the helper beside that copy'},
  },
  upgrade: {
    NEW: {declared: 'rust/', why: 'the binary upgrade.sh installs is built from rust/'},
    SOURCE_UI: {declared: 'ui/', why: 'the UI assets it installs'},
  },
};

/// A tree path named directly by a copy line, in any of the spellings the installers use:
/// `"$ROOT/scripts/x"`, `"$ROOT"/scripts/x`, `$ROOT/scripts/x`. The optional quote matters: the
/// quote-then-slash form is how deploy.sh spells *every glob it installs*, and missing it is why dropping
/// `jobs/`, `scripts/whatsapp-*` or `scripts/subagent-return-*` from the manifest used to stay green.
const TREE_PATH = /\$(?:ROOT|SOURCE_ROOT|SOURCE_UI)["']?\/([A-Za-z0-9._*/-]+)/g;
/// A line that installs something. `cp -f`/`cp -R`/plain `cp`, `install`, `mv`, and the `for source in`
/// loops that feed them. Prose is stripped first: `install` is an English word too.
const COPY_LINE = /(^|[\s|;&({])(cp|install|mv)\s/;
const LOOP_LINE = /for\s+(source|skill_source)\s+in\s/;

function stripComment(line) {
  const trimmed = line.trimStart();
  if (trimmed.startsWith('#')) return '';
  const cut = line.search(/(^|\s)#/);
  return cut === -1 ? line : line.slice(0, cut);
}

function assignmentValue(text, name) {
  const match = text.match(new RegExp(`(?:^|\\n)\\s*(?:export\\s+)?${name}=("[^"]*"|'[^']*'|[^\\s;]+)`));
  if (!match) return null;
  const value = match[1].replace(/^["']|["']$/g, '');
  const tree = value.match(/\$(?:ROOT|SOURCE_ROOT)\/([A-Za-z0-9._/-]+)/);
  return tree ? tree[1] : value;
}

function installerSources(file) {
  const text = fs.readFileSync(file, 'utf8');
  const name = path.basename(file);
  const rules = new Map();
  const add = (rule, why) => {
    if (!rule || rule.includes('$')) return;
    if (!rules.has(rule)) rules.set(rule, why);
  };
  for (const raw of text.split(/\r?\n/)) {
    const line = stripComment(raw);
    if (line === '' || !(COPY_LINE.test(line) || LOOP_LINE.test(line))) continue;
    for (const match of line.matchAll(TREE_PATH)) add(match[1], `copied by ${name}`);
  }
  const variables = file.endsWith('upgrade.sh') ? INSTALLER_VARIABLES.upgrade : INSTALLER_VARIABLES.deploy;
  for (const [variable, entry] of Object.entries(variables)) {
    const value = assignmentValue(text, variable);
    check(value !== null, `${name} still assigns $${variable} (${entry.why})`);
    const resolved = value !== null && value.includes('/') && !value.startsWith('$') ? value : entry.declared;
    add(resolved, `installed by ${name} as $${variable}`);
  }
  if (file.endsWith('upgrade.sh')) {
    check(text.includes('cp -f "$0"'), 'upgrade.sh still installs itself');
    check(text.includes('"$SOURCE_ROOT"/skills/*'), 'upgrade.sh still installs skills/*');
    add('scripts/upgrade.sh', 'upgrade.sh installs itself as $0');
    add('skills/', 'installed by upgrade.sh from $SOURCE_ROOT/skills');
  }
  return rules;
}

/// The crates this installer builds, so a copied path that is not in the tree can be recognised as a
/// build output rather than an absent file: `cargo build --manifest-path "$ROOT/<crate>/Cargo.toml"`.
/// Comments are stripped first, for the same reason the copy lines are: a commented-out build line is not
/// a build, and reading one as if it were would let a copied build output pass as "the installer builds
/// it" after the build was deleted.
function builtCrates(file) {
  const crates = new Set();
  for (const raw of fs.readFileSync(file, 'utf8').split(/\r?\n/)) {
    const line = stripComment(raw);
    if (line === '') continue;
    for (const match of line.matchAll(/cargo\s+build[^\n]*--manifest-path\s+"?\$(?:ROOT|SOURCE_ROOT)\/([A-Za-z0-9._/-]+)\/Cargo\.toml/g)) {
      crates.add(match[1]);
    }
  }
  return [...crates];
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

function globMatch(rule) {
  const directory = path.dirname(path.join(root, rule));
  const pattern = path.basename(rule);
  const prefix = pattern.slice(0, pattern.indexOf('*'));
  let entries = [];
  try { entries = fs.readdirSync(directory); } catch { return null; }
  const hit = entries.filter((entry) => entry.startsWith(prefix)).sort()[0];
  return hit ? `${path.dirname(rule)}/${hit}` : null;
}

function synthesise(rule) {
  if (rule.endsWith('/')) return `${rule}probe`;
  if (rule.includes('*')) return rule.replace('*', 'probe');
  return rule;
}

/// One concrete path for a rule, or a refusal to invent one. `absent` is a failure at the call site: a
/// path an installer copies that is neither in the tree nor built by that installer is a defect, and
/// skipping it with a note is how the first version of this check let one through.
function exampleFor(rule, crates) {
  if (rule.endsWith('/')) {
    const found = walk(path.join(root, rule)).filter((entry) => entry !== '')[0];
    return found ? {example: `${rule}${found}`, how: 'from the tree'} : {example: synthesise(rule), how: 'synthesised: the directory is empty in this tree'};
  }
  if (rule.includes('*')) {
    const hit = globMatch(rule);
    return hit ? {example: hit, how: 'from the tree'} : {example: synthesise(rule), how: 'synthesised: nothing in this tree matches the rule'};
  }
  if (fs.existsSync(path.join(root, rule))) return {example: rule, how: 'from the tree'};
  if (crates.some((crate) => rule.startsWith(`${crate}/target/`))) {
    return {example: rule, how: `built by this installer (${crates.find((crate) => rule.startsWith(`${crate}/target/`))})`};
  }
  return {absent: true};
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
  const argv = process.argv.slice(2);
  let manifestArg = null;
  let installersDir = here;
  let listRules = false;
  for (let index = 0; index < argv.length; index += 1) {
    if (argv[index] === '--installers') installersDir = path.resolve(argv[++index]);
    else if (argv[index] === '--list') listRules = true;
    else if (manifestArg === null) manifestArg = argv[index];
    else throw Object.assign(new Error(`unexpected argument ${argv[index]}`), {code: 4});
  }
  const shipped = loadShipped(manifestArg || undefined);
  check(!shipped.error, `the manifest is readable (${shipped.error || shipped.file})`);
  const manifest = shipped.manifest;

  const deploy = path.join(installersDir, 'deploy.sh');
  const upgrade = path.join(installersDir, 'upgrade.sh');
  check(fs.existsSync(deploy) && fs.existsSync(upgrade), `the installers are readable in ${installersDir}`);
  const crates = [...new Set([...builtCrates(deploy), ...builtCrates(upgrade)])];
  const rules = new Map([...installerSources(deploy), ...installerSources(upgrade)]);

  // `--list` is how a reviewer reads the derivation without reading this file: every rule, why it is a
  // rule, and the concrete path the predicate is asked about.
  if (listRules) {
    for (const [rule, why] of rules) {
      const resolved = exampleFor(rule, crates);
      process.stdout.write(`${rule}\t${why}\t${resolved.absent ? 'ABSENT FROM THE TREE' : `${resolved.example} (${resolved.how})`}\n`);
    }
    process.stdout.write(`crates built here: ${crates.join(', ') || 'none'}\n`);
    return;
  }

  for (const [rule, why] of rules) {
    const resolved = exampleFor(rule, crates);
    check(!resolved.absent,
      `copies ${rule} (${why}), which is not in the tree and this installer does not build it`);
    check(shipsToDeploy(resolved.example, manifest),
      `the predicate covers ${resolved.example} (rule ${rule}, ${why}, ${resolved.how})`);
    if (resolved.how !== 'from the tree') note(`rule ${rule}: checked as ${resolved.example} (${resolved.how})`);
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

  for (const text of notes) process.stderr.write(`deploy-shipped: note: ${text}\n`);
  console.log(`deploy shipped ok (${checked} checks; ${rules.size} rules from the installers, ${fromShipWave.length} from ship-wave.mjs)`);
}

try {
  main();
} catch (error) {
  if (!error.failed) {
    process.stderr.write(`deploy-shipped: ${error.stack || error}\n`);
    process.exitCode = error.code === 4 ? 4 : 4;
  }
}
