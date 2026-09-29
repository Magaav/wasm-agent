#!/usr/bin/env node
// A script run must say which copy of the Lua it loaded.
//
// With WASM_AGENT_LUA_ROOT unset, `dofile` resolves every module from the copy compiled into the
// binary (`include_str!`), so a focused test written to exercise an edit under `lua/` can run green
// while never loading that edit. Two workers hit this on the same day; one lost a whole green run
// (28 checks) to the binary's own `update.lua` and only found out from an independent verifier.
// The note on stderr is the tell, and the assertions below are real process runs: one fixture
// script run under two environments, and two bad roots that must fail loudly instead of falling
// back to the embedded copy.
const fs = require('node:fs'), os = require('node:os'), path = require('node:path');
const crypto = require('node:crypto'), assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const repo = path.resolve(__dirname, '..');
let bin = path.resolve(process.env.WA_BIN || path.join(repo, 'rust/target/release', process.platform === 'win32' ? 'wa.exe' : 'wa'));
if (!fs.existsSync(bin) && fs.existsSync(bin + '.exe')) bin += '.exe';
assert.ok(fs.existsSync(bin), 'no binary to run: ' + bin);
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-lua-root-'));
const home = path.join(root, 'home'); fs.mkdirSync(home);
const NOTE = 'lua root unset: using embedded modules; edits under lua/ are NOT under test';
const MARK = 'lua root fixture ok';
let checks = 0;
const check = (condition, label) => { assert.ok(condition, label); checks++; };
// The fixture is deliberately mode-agnostic: the *same* script has to run both ways. It reports
// which copy answered through LOADED_SOURCES - the hash the loader records for the module it
// actually evaluated - so the disk run can assert it read the file in the tree.
const fixture = path.join(root, 'fixture.lua');
fs.writeFileSync(fixture, [
  'local json = dofile("lua/vendor/json.lua")',
  'local update = dofile("lua/core/update.lua")',
  'assert(type(update.verdict) == "function", "lua/core/update.lua did not define verdict")',
  'print(json.encode({marker = "' + MARK + '", loaded = LOADED_SOURCES["lua/core/update.lua"],',
  '  root = host.getenv("WASM_AGENT_LUA_ROOT") or ""}))',
  '',
].join('\n'));
function run(name, { luaRoot, script = fixture, argv = ['--db', path.join(root, name + '.db')] }) {
  const env = {};
  for (const [key, value] of Object.entries(process.env)) {
    if (!/^(WASM_AGENT_|WA_|OPENAI_|ANTHROPIC_|OPENCODE_)/.test(key)) env[key] = value;
  }
  Object.assign(env, {
    WASM_AGENT_HOME: home, WASM_AGENT_RELAY: '', WASM_AGENT_RENDEZVOUS: '', WASM_AGENT_MANAGED: '0',
  });
  if (luaRoot !== undefined) env.WASM_AGENT_LUA_ROOT = luaRoot;
  if (script) env.WA_SCRIPT = script;
  const result = spawnSync(bin, argv, { cwd: repo, env, encoding: 'utf8', timeout: 60000, windowsHide: true });
  fs.writeFileSync(path.join(root, name + '.log'),
    'exit=' + result.status + '\n-- stdout --\n' + (result.stdout || '') + '-- stderr --\n' + (result.stderr || ''));
  return { status: result.status, out: result.stdout || '', err: result.stderr || '' };
}
function occurrences(haystack, needle) {
  let count = 0, at = 0;
  for (;;) { const found = haystack.indexOf(needle, at); if (found < 0) return count; count++; at = found + needle.length; }
}
try {
  // ---- the same script, a root in use: the modules must be the tree's, and no note ------------
  const treeHash = crypto.createHash('sha256').update(fs.readFileSync(path.join(repo, 'lua/core/update.lua'))).digest('hex');
  const disk = run('disk', { luaRoot: repo });
  check(disk.status === 0, 'a script run with a root must succeed: ' + disk.err);
  check(disk.out.includes(MARK), 'the fixture must run with a root set: ' + disk.out);
  check(!disk.err.includes(NOTE), 'no note when a Lua root IS in use, got: ' + disk.err);
  const diskLine = JSON.parse(disk.out.split('\n').find((line) => line.includes(MARK)));
  check(diskLine.root === repo, 'the run must see the root it was given, got ' + diskLine.root);
  check(diskLine.loaded === treeHash, 'the module under test must be the copy in the tree, got ' + diskLine.loaded);

  // ---- the same script, no root: the note, once, and it is the binary's copy -------------------
  const embedded = run('embedded', {});
  check(embedded.status === 0, 'a script run without a root must still succeed: ' + embedded.err);
  check(embedded.out.includes(MARK), 'the fixture must run without a root too: ' + embedded.out);
  check(embedded.err.includes(NOTE), 'a script run with no Lua root must say its modules are embedded, got: ' + embedded.err);
  check(occurrences(embedded.err, NOTE) === 1, 'the note must appear exactly once, got ' + occurrences(embedded.err, NOTE));
  const embeddedLine = JSON.parse(embedded.out.split('\n').find((line) => line.includes(MARK)));
  check(embeddedLine.root === '', 'the unset run must see no root, got ' + embeddedLine.root);
  check(/^[0-9a-f]{64}$/.test(embeddedLine.loaded), 'the embedded run must still record a source hash, got ' + embeddedLine.loaded);

  // ---- the neighbouring trap: a root that is set and unusable must fail loudly -----------------
  for (const [name, luaRoot] of [['missing', path.join(root, 'no-such-tree')], ['incomplete', path.join(root, 'empty-tree')]]) {
    if (name === 'incomplete') fs.mkdirSync(luaRoot);
    const bad = run(name, { luaRoot });
    check(bad.status !== 0, 'a ' + name + ' root must fail the run, got exit ' + bad.status);
    check(bad.err.includes('lua_root_unreadable'), 'a ' + name + ' root must say lua_root_unreadable, got: ' + bad.err);
    check(!bad.out.includes(MARK), 'a ' + name + ' root must not fall back to the embedded copy silently: ' + bad.out);
    check(!bad.err.includes(NOTE), 'a set root is not an unset one: no note on ' + name + ', got: ' + bad.err);
  }

  // ---- the entry modules Rust loads itself follow the same rule ---------------------------------
  // `lua/core/init.lua`, server.lua and subagents.lua do not go through `dofile`; they used to fall
  // back to the binary silently. A command run with an unusable root must refuse instead.
  const entries = run('entry-modules', { luaRoot: path.join(root, 'empty-tree'), script: null, argv: ['--db', path.join(root, 'entry-modules.db')] });
  check(entries.status !== 0, 'an unusable root must fail a command run too, got exit ' + entries.status);
  check(entries.err.includes('lua_root_unreadable'), 'an unusable root must be named for the entry modules, got: ' + entries.err);
  check(!entries.err.includes(NOTE), 'a command run is not a script run: no note, got: ' + entries.err);

  console.log('lua root notice ok (' + checks + ' checks, 0 skipped; real process runs: 2 script-run environments, 2 unusable roots, 1 command run)');
} catch (error) {
  console.error(error.stack);
  process.exitCode = 1;
} finally {
  console.log('evidence: ' + root);
}
