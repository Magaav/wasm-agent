#!/usr/bin/env node
// WHICH SCRIPTS MUST TRAVEL WITH A PUBLISHED BUNDLE? The ones a node EXECS FROM ITS INSTALL.
//
// THE DEFECT (mission release-node-updates, D2, measured 25/11 on a peer installed from the published
// v0.1.1 bundle). lua/core/remote_update.lua:449 answers a release-installed node with
// `exec bash <install>/scripts/release-install.sh`, and the published bundle carried install.sh,
// linux/bootstrap.sh and the MCP runtime and nothing else, so every `wa update <node> --release`
// accepted the request and died one layer down with
//   bash: <install>/scripts/release-install.sh: No such file or directory   (code 127)
// - an answer with no name, no fix and no clue, on the node, after the operator had been told the
// request was queued. The list of files a bundle ships was hand-written in scripts/release-linux.sh,
// so it could not notice the code growing a door.
//
// THE RULE. A path this tree builds as <install>/scripts/<file> and hands to a shell must be a member
// of the bundle, and so must every lib that member sources from the same directory: a door that 127s
// one line later (release-install.sh sources scripts/lib/node-binaries.sh) is the same defect with a
// shorter walk. The list is DERIVED from the code here, never written down:
//
//   * lua: a '/scripts/<file>' literal whose expression to its left names the install
//     (install, install_dir(), slashes(install), prefix ...). A tree- or repo-relative path
//     (tree .. '/scripts/deploy.sh') is NOT a bundle member: that tree is not in a bundle.
//   * rust: `resolve_script("<file>", "<override var>")` - the sentinel's own "where a shipped script
//     is", which looks beside the installed binary first (rust/wa-sentinel/src/main.rs).
//   * closure, to a fixpoint: every lib/<name>.sh|py a member names (scripts/lib/x.sh,
//     $(dirname "$0")/lib/x.sh, $INSTALL_DIR/scripts/lib/x.sh) and every sibling script a member
//     actually RUNS - a line that names `scripts/<file>` AND an interpreter/exec verb (bash, sh,
//     node, python3, exec). A file named in prose is not a door: deploy.sh's comments name half the
//     repository, and a list that grows on prose ships the whole tree.
//
// EXEMPTIONS ARE A REVIEWED ALLOW-LIST, WITH A REASON (scripts/lib/install-script-doors.allow, one
// "<repo-relative path> # <why>" per line). A door may be exempt only when its absence is ANSWERED BY
// NAME instead of 127: rust/wa-sentinel resolves `scripts/deploy.sh` beside the binary and refuses
// with "no deploy.sh found (looked at ...; set WA_SENTINEL_DEPLOY ...)", which an operator can read -
// and a bundle node has no tree for deploy.sh to deploy. A door a coordinator's wrapper execs has no
// such answer (bash 127s), so it must ship. An exemption with no reason, or one nothing in the code
// needs any more, is itself a failure.
//
// Usage:
//   node scripts/lib/install-script-doors.mjs --root <tree> --list            the members a bundle needs
//   node scripts/lib/install-script-doors.mjs --root <tree> --check <bundle>  is a staged/published bundle complete?
//   node scripts/lib/install-script-doors.mjs --root <tree> --explain         where each door comes from
// Exit: 0 complete; 1 a door is missing (named: file, site, why); 2 the question could not be asked.
import { readFileSync, existsSync, readdirSync } from 'node:fs';
import { join, dirname, isAbsolute, relative } from 'node:path';

function die(code, message) { process.stderr.write(message.endsWith('\n') ? message : message + '\n'); process.exit(code); }

const args = process.argv.slice(2);
let root = '';
let mode = '';
let bundle = '';
for (let i = 0; i < args.length; i += 1) {
  const a = args[i];
  if (a === '--root') { root = args[i + 1] || ''; i += 1; }
  else if (a === '--list') mode = 'list';
  else if (a === '--explain') mode = 'explain';
  else if (a === '--check') { mode = 'check'; bundle = args[i + 1] || ''; i += 1; }
  else if (a === '--help' || a === '-h') { process.stdout.write('usage: install-script-doors.mjs --root <tree> (--list | --explain | --check <bundle>)\n'); process.exit(0); }
  else die(2, 'install-script-doors: unknown_option: ' + a);
}

const SCRIPT_EXT = '(?:sh|py|mjs|js)';

// A test file is not a door and is not part of a door's closure: a fixture may name any path it likes.
function isTestPath(path) {
  const p = path.replace(/\\/g, '/');
  return /(^|\/)test[-_]/.test(p) || /_tests?\.rs$/.test(p) || /(^|\/)tests\//.test(p);
}

function walk(dir, suffix, out) {
  let entries;
  try { entries = readdirSync(dir, { withFileTypes: true }); } catch (error) { return out; }
  for (const entry of entries.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0))) {
    if (entry.name === 'node_modules' || entry.name === 'target' || entry.name === '.git') continue;
    const path = join(dir, entry.name);
    if (entry.isDirectory()) walk(path, suffix, out);
    else if (entry.isFile() && path.endsWith(suffix)) out.push(path);
  }
  return out;
}

if (root === '') die(2, 'install-script-doors: root_required: --root <tree> (the checkout whose code names the doors)');
if (mode === '') die(2, 'install-script-doors: mode_required: one of --list, --explain, --check <bundle>');
if (!existsSync(join(root, 'lua')) || !existsSync(join(root, 'rust'))) {
  die(2, 'install-script-doors: not_a_tree: ' + root + ' has no lua/ and rust/, so no door can be derived from it');
}

// ---- the allow-list first: an exempt door is not shipped and its closure is not walked --------------
const allowPath = join(root, 'scripts/lib/install-script-doors.allow');
const exempt = new Map();
if (existsSync(allowPath)) {
  for (const raw of readFileSync(allowPath, 'utf8').split('\n')) {
    const line = raw.trim();
    if (line === '' || line.startsWith('#')) continue;
    const hash = line.indexOf('#');
    const path = (hash === -1 ? line : line.slice(0, hash)).trim();
    const why = hash === -1 ? '' : line.slice(hash + 1).trim();
    if (path === '') continue;
    if (why === '') die(1, 'install-script-doors: exemption_without_reason: ' + path + ' (every exemption in ' + allowPath + ' says why)');
    exempt.set(path, why);
  }
}

// ---- the doors the code names ----------------------------------------------------------------------
const found = new Map(); // member -> [{ at, why }]
function note(member, at, why) {
  if (!found.has(member)) found.set(member, []);
  const sites = found.get(member);
  if (!sites.some((s) => s.at === at)) sites.push({ at, why });
}

for (const file of walk(join(root, 'lua'), '.lua', [])) {
  if (isTestPath(file)) continue;
  const text = readFileSync(file, 'utf8');
  text.split('\n').forEach((line, index) => {
    const pattern = new RegExp("['\"\x60]/scripts/([A-Za-z0-9_.\\/-]+\\.(" + SCRIPT_EXT + "))['\"\x60]", 'g');
    let match;
    while ((match = pattern.exec(line)) !== null) {
      const before = line.slice(0, match.index);
      if (!/install/i.test(before)) continue; // tree- or repo-relative: not in a bundle
      note('scripts/' + match[1], relative(root, file) + ':' + (index + 1), 'executed from the install (lua)');
    }
  });
}
for (const file of walk(join(root, 'rust'), '.rs', [])) {
  if (isTestPath(file)) continue;
  const text = readFileSync(file, 'utf8');
  text.split('\n').forEach((line, index) => {
    if (line.trim().startsWith('//')) return; // prose is not a door
    const resolve = new RegExp('resolve_script\\(\\s*"([A-Za-z0-9_.\\/-]+\\.(' + SCRIPT_EXT + '))"', 'g');
    let match;
    while ((match = resolve.exec(line)) !== null) {
      note('scripts/' + match[1], relative(root, file) + ':' + (index + 1), 'resolved beside the installed binary (rust)');
    }
    const beside = new RegExp('\\.join\\("scripts"\\)\\s*\\.\\s*join\\("([A-Za-z0-9_.-]+\\.(' + SCRIPT_EXT + '))"\\)', 'g');
    while ((match = beside.exec(line)) !== null) {
      note('scripts/' + match[1], relative(root, file) + ':' + (index + 1), 'joined onto a directory named in the code (rust)');
    }
  });
}

// ---- the closure: what those members source and run from the same directory ------------------------
// Any spelling of a lib beside the script: $ROOT/scripts/lib/x.sh, $(dirname "$0")/lib/x.sh,
// $INSTALL_DIR/scripts/lib/x.sh. The name is what matters; the prefix is normalised to scripts/lib/.
const LIB = /lib\/([A-Za-z0-9_.-]+\.(?:sh|py))/g;
const VERB = /(^|\s)(?:bash|sh|node|python3|exec|\.)\s/;
const queue = [...found.keys()].filter((m) => !exempt.has(m));
const seen = new Set(queue);
while (queue.length > 0) {
  const member = queue.shift();
  const abs = join(root, member);
  if (!existsSync(abs)) continue;
  let text;
  try { text = readFileSync(abs, 'utf8'); } catch (error) { continue; }
  const add = (next, why) => {
    if (seen.has(next) || exempt.has(next) || isTestPath(next) || !existsSync(join(root, next))) return;
    seen.add(next);
    note(next, member, why);
    queue.push(next);
  };
  const sameDir = dirname(member).replace(/\\/g, '/'); // scripts, or scripts/lib
  for (const line of text.split('\n')) {
    if (line.trim().startsWith('#')) continue; // a comment in a shell script is not an exec
    let match;
    LIB.lastIndex = 0;
    while ((match = LIB.exec(line)) !== null) add('scripts/lib/' + match[1], 'sourced by ' + member);
    if (!VERB.test(line)) continue;
    const sibling = new RegExp('[/\\x60"](?:scripts/)?([A-Za-z0-9_.-]+\\.(' + SCRIPT_EXT + '))[\\x60"\\s]', 'g');
    while ((match = sibling.exec(line)) !== null) {
      const name = match[1];
      if (member.endsWith('/' + name) || member === 'scripts/' + name) continue;
      add(sameDir + '/' + name, 'run from the same directory by ' + member);
      if (sameDir !== 'scripts') add('scripts/' + name, 'run from the install by ' + member);
    }
  }
}

// A door the code names but this tree does not have is a red gate of its own.
const named = [...found.keys()].filter((m) => !exempt.has(m)).sort();
const absent = named.filter((m) => !existsSync(join(root, m)));
if (absent.length > 0) {
  die(1, absent.map((m) => 'install-script-doors: door_absent_in_tree: ' + m + ' is exec from the install (' +
    found.get(m).map((s) => s.at).join(', ') + ') and this tree does not have the file').join('\n'));
}
// Every door may be exempt (a fixture with one reviewed exemption); finding NO door at all is different, and
// it means the derivation read nothing - which is never a pass.
// A TREE WITH NO LUA AND NO RUST SOURCES CANNOT NAME A DOOR, and that is a FIXTURE, not a tree that lost
// them (measured 25/11: the release-channel e2e packs a bundle from a fixture repo that carries scripts and
// no sources, and the derivation refused it). The distinction is what keeps the refusal honest: a tree that
// HAS sources and names no door is still a red gate, because it carries code that could have grown one.
const sources = walk(join(root, 'lua'), '.lua', []).filter((f) => !isTestPath(f)).length
  + walk(join(root, 'rust'), '.rs', []).filter((f) => !isTestPath(f)).length
// IS THIS THE PRODUCT TREE? The update capability's own Lua is what hands a door to a shell (update.lua runs the
// installed updater; remote_update.lua execs release-install.sh and rollback-node.sh), so a tree that carries
// neither cannot be expected to name one - measured 25/11: the release-channel e2e packs a PUBLISHED bundle from
// a fixture repo with two stub Lua files and no such code, and refusing that was wrong. A tree that DOES carry
// them and still names no door is the defect this list exists for, and it stays red.
const productTree = existsSync(join(root, 'lua/core/update.lua')) || existsSync(join(root, 'lua/core/remote_update.lua'))
if (found.size === 0) {
  if (!productTree) {
    process.stderr.write('install-script-doors: door_list_fixture_tree: nothing in ' + root + ' names an install-relative script, and this tree does not carry lua/core/update.lua or lua/core/remote_update.lua, so it is not the product tree and cannot name a door (it carries ' + sources + ' Lua/Rust source(s))\n')
  } else {
    die(1, 'install-script-doors: no_door_derived: nothing in ' + root + ' names an install-relative script, and this tree DOES carry the update capability\'s own Lua (' + sources + ' Lua/Rust source(s)), so its list cannot be right')
  }
}
for (const path of exempt.keys()) {
  if (!found.has(path)) die(1, 'install-script-doors: stale_exemption: ' + path + ' is exempt in ' + allowPath + ' and no code in this tree execs it; drop the line');
}

if (mode === 'explain') {
  for (const member of named) {
    const sites = found.get(member).map((s) => s.at + ' (' + s.why + ')').join(', ');
    process.stdout.write((exempt.has(member) ? 'exempt  ' : 'member  ') + member + '  <- ' + sites + '\n');
  }
  for (const member of [...exempt.keys()].sort()) {
    process.stdout.write('exempt  ' + member + '  [not shipped: ' + exempt.get(member) + ']\n');
  }
  process.exit(0);
}

if (mode === 'list') {
  process.stdout.write(named.join('\n') + '\n');
  process.exit(0);
}

// ---- --check: a staged or published bundle directory ----------------------------------------------
const bundleDir = isAbsolute(bundle) ? bundle : join(process.cwd(), bundle);
if (!existsSync(bundleDir)) die(2, 'install-script-doors: bundle_missing: ' + bundleDir);
const sumsPath = join(bundleDir, 'files.sha256');
if (!existsSync(sumsPath)) {
  // A bundle is identified by files.sha256: every member is listed and hashed there, and bootstrap
  // refuses to install a bundle whose members disagree with it.
  die(2, 'install-script-doors: bundle_has_no_member_list: ' + sumsPath + ' is missing, so membership cannot be answered');
}
const listed = new Set(readFileSync(sumsPath, 'utf8').split('\n').map((l) => l.trim().split(/\s+/).pop()).filter(Boolean));
const missing = [];
for (const member of named) {
  if (!existsSync(join(bundleDir, member))) missing.push({ member, why: 'is not in the bundle' });
  else if (!listed.has(member)) missing.push({ member, why: 'is present but not a bundle member (files.sha256 does not name it)' });
}
if (missing.length > 0) {
  die(1, missing.map((m) => 'door_missing: ' + m.member + ' - ' + m.why + '; the code execs it from the install (' +
    found.get(m.member).map((s) => s.at).join(', ') + '), so a node installed from this bundle answers that door with code 127').join('\n'));
}
process.stdout.write('install-script-doors: complete: ' + named.length + ' install-side member(s); every script the code execs from the install is in the bundle\n');
process.exit(0);
