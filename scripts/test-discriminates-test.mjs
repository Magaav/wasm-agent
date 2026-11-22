#!/usr/bin/env node
// scripts/test-discriminates.sh, judged by the only thing that matters about it: does it separate a test
// that would have caught a bug from one that would not?
//
// Review r1 found both directions wrong, and each case below is one of its MUSTs:
//   MUST 1a  a missing symbol on the base is a NON-blocking new-symbol row
//   MUST 1b  assertion markers are checked BEFORE the missing-code markers
//   MUST 1c  a MODIFIED test whose verdict did not change is unchanged-verdict, not a blocker
//   MUST 1d  SKIP is a skipped row, never exit 3
//   MUST 2   a test's OWN path in its header is not "new code"; a test that PASSES is never new-symbol
//   MUST 3   every changed test gets a row: test-a/test-b -> 2 rows
//   MUST 4   a rust/ change makes the Lua rows unrevertable, and a PATH wa is never used
//   MUST 5   Refactor-only in a round of several branches is refused by name
//
// Hermetic: a scratch Git repository, a scratch HOME, no node, no network, no binary. The subject needs
// no wa to judge a shell fixture, which keeps this check cheap enough for the land step.
//
// Where it runs: scripts/fast.sh (contract checks) and scripts/gate-checks.mjs ("discrimination").
import {execFileSync, spawnSync} from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '..');
const SUBJECT = path.join(root, 'scripts/test-discriminates.sh');
if (!fs.existsSync(SUBJECT)) { console.error('FAIL the subject is missing: ' + SUBJECT); process.exit(1); }

const home = fs.mkdtempSync(path.join(os.tmpdir(), 'disc-home-'));
const repo = path.join(home, 'fixture');
fs.mkdirSync(repo, {recursive: true});
// The node's temp root lives INSIDE the operator store in real life ($HOME/.wasm-agent/tmp), and the fixture
// copies that on purpose: the row homes used to be made under it, which is a home the guard must refuse.
const tmpdir = path.join(home, 'tmp');
fs.mkdirSync(tmpdir, {recursive: true});
const env = {...process.env, HOME: home, WASM_AGENT_HOME: home, TMPDIR: tmpdir,
  WASM_AGENT_TMPDIR: path.join(home, '.wasm-agent', 'tmp')};
for (const k of ['WASM_AGENT_VAULT_URL', 'WASM_AGENT_VAULT_DIR', 'WASM_AGENT_DB', 'WASM_AGENT_RENDEZVOUS', 'WASM_AGENT_RELAY', 'WA_BIN']) delete env[k];

const git = (...args) => execFileSync('git', args, {cwd: repo, env, encoding: 'utf8'});
const write = (rel, text) => {
  const full = path.join(repo, rel);
  fs.mkdirSync(path.dirname(full), {recursive: true});
  fs.writeFileSync(full, text);
};
const run = (...args) => spawnSync('bash', [SUBJECT, '--repo', repo, ...args], {cwd: home, env, encoding: 'utf8'});
const commit = (message) => { git('add', '-A'); git('commit', '-qm', message); };
const fresh = (branch) => { git('checkout', '-qB', branch, 'main'); };

const rowsOf = out => Object.fromEntries(out.split('\n')
  .filter(l => l.split('\t').length >= 3 && !l.startsWith('test-discriminates:'))
  .map(l => { const [verdict, file, ...reason] = l.split('\t'); return [file, {verdict, reason: reason.join(' ')}]; }));

let failed = 0, checks = 0;
const ok = (condition, label) => { checks++; if (!condition) { failed++; console.error('FAIL ' + label); } };
const verdictIs = (rows, file, verdict, label) =>
  ok(rows[file]?.verdict === verdict, label + ': ' + JSON.stringify(rows[file]));

try {
  git('init', '-q', '-b', 'main', '.');
  git('config', 'user.email', 'fixture@example.invalid');
  git('config', 'user.name', 'fixture');
  write('lua/knob.txt', 'VALUE=old\n');
  write('scripts/test-existing.sh', 'echo ok\n');
  commit('base');

  // ---- MUST 1: a fix adds tests; the good one discriminates, the vacuous one does not -----------------
  fresh('change/fix');
  write('lua/knob.txt', 'VALUE=new\n');
  write('scripts/test-good.sh', 'grep -q VALUE=new lua/knob.txt || { echo "FAIL: the knob is still old"; exit 1; }\n');
  write('scripts/test-vacuous.sh', 'echo everything is fine\n');
  write('scripts/test-loaderror.sh', 'source lua/does-not-exist.sh\n');
  // MUST 1b: the message says "missing", but this is an ASSERTION that fired - it must discriminate.
  write('scripts/test-says-missing.sh', 'grep -q VALUE=new lua/knob.txt || { echo "FAIL: the new value is missing"; exit 1; }\n');
  // MUST 1d: a test that skips itself on this machine.
  write('scripts/test-skips.sh', 'echo "SKIP no fixture here"; exit 0\n');
  commit('the fix');

  {
    const r = run('main');
    const rows = rowsOf(r.stdout);
    ok(r.status === 1, 'a vacuous added test blocks: exit 1, got ' + r.status);
    verdictIs(rows, 'scripts/test-good.sh', 'discriminates', 'the good test discriminates');
    verdictIs(rows, 'scripts/test-vacuous.sh', 'does-not', 'the vacuous added test does not');
    verdictIs(rows, 'scripts/test-loaderror.sh', 'new-symbol', 'MUST 1a: a missing symbol is new-symbol, not does-not');
    verdictIs(rows, 'scripts/test-says-missing.sh', 'discriminates', 'MUST 1b: an assertion that says "missing" still discriminates');
    verdictIs(rows, 'scripts/test-skips.sh', 'skipped', 'MUST 1d: a SKIP is a skipped row');
    ok(/it does not catch this change/.test(rows['scripts/test-vacuous.sh']?.reason ?? ''), 'the vacuous row says why');
    ok(!Object.keys(rows).some(k => k.startsWith('lua/')), 'a changed non-test path is never a test row');
    ok(!Object.keys(rows).some(k => k.endsWith('.md') || k.endsWith('.txt')),
      'a report or a snapshot whose name starts with test- is not a test: ' + Object.keys(rows).join(','));
    // The scratch tree AND the row homes are gone after a run (they live under different roots since 22/11:
    // the tree under the node's temp root inside the operator store, the homes outside it).
    const left = fs.readdirSync(path.join(home, '.wasm-agent', 'tmp')).filter(n => n.startsWith('discriminates-'));
    ok(left.length === 0, 'the scratch worktree is removed after a run: ' + left.join(', '));
    const homes = fs.readdirSync(tmpdir).filter(n => n.startsWith('discriminates-homes-'));
    ok(homes.length === 0, 'the row homes are removed after a run: ' + homes.join(', '));
  }

  // MUST 1c: a MODIFIED test whose verdict does not change is not evidence, and does not block.
  fresh('change/test-only');
  write('scripts/test-existing.sh', 'echo ok # a comment fixed\n');
  commit('fix a test only');
  {
    const r = run('main');
    const rows = rowsOf(r.stdout);
    verdictIs(rows, 'scripts/test-existing.sh', 'unchanged-verdict', 'MUST 1c: a modified green test is unchanged-verdict');
    ok(r.status === 0, 'MUST 1c: and it does not block: exit ' + r.status);
    ok(/does not block/.test(rows['scripts/test-existing.sh']?.reason ?? ''), 'and the row says so');
  }

  // MUST 2: a test whose HEADER names its own path is not "a spec for new code".
  fresh('change/self-named');
  write('scripts/test-self.sh', '#!/usr/bin/env bash\n# scripts/test-self.sh: a test for a value the fix changes.\ngrep -q VALUE=new2 lua/knob.txt || { echo "FAIL: the value is old"; exit 1; }\n');
  write('lua/knob.txt', 'VALUE=new2\n');
  commit('a self-named test');
  {
    const r = run('main');
    const rows = rowsOf(r.stdout);
    verdictIs(rows, 'scripts/test-self.sh', 'discriminates', 'MUST 2: a test naming its own path still discriminates');
    ok(r.status === 0, 'MUST 2: and nothing blocks, got ' + r.status);
  }

  // MUST 3: two tests where one runs the other are still TWO rows, and both are judged.
  fresh('change/two-tests');
  write('scripts/test-a.sh', '#!/usr/bin/env bash\nbash scripts/test-b.sh || exit 1\ngrep -q VALUE=new3 lua/knob.txt || { echo "FAIL: a"; exit 1; }\n');
  write('scripts/test-b.sh', '#!/usr/bin/env bash\ngrep -q VALUE=new3 lua/knob.txt || { echo "FAIL: b"; exit 1; }\n');
  write('lua/knob.txt', 'VALUE=new3\n');
  commit('two tests');
  {
    const r = run('main');
    const rows = rowsOf(r.stdout);
    ok(Object.keys(rows).filter(k => k.startsWith('scripts/test-')).length >= 2,
      'MUST 3: test-a/test-b -> 2 rows, got ' + JSON.stringify(Object.keys(rows)));
    verdictIs(rows, 'scripts/test-b.sh', 'discriminates', 'MUST 3: the inner test is judged, not skipped');
  }

  // MUST 4: a rust/ change makes the Lua rows unrevertable, and a PATH wa is never used.
  fresh('change/rust');
  write('rust/thing.rs', 'fn main() {}\n');
  write('lua/knob.txt', 'VALUE=new4\n');
  write('scripts/test-existing.sh', 'grep -q VALUE=new4 lua/knob.txt || { echo "FAIL: old"; exit 1; }\n');
  commit('touch rust and a test');
  {
    const r = run('main');
    ok(/unrevertable|no runner/.test(rowsOf(r.stdout)['scripts/test-existing.sh']?.verdict ?? '') ||
       /unrevertable/.test(r.stdout + r.stderr) || /changes rust/.test(r.stdout),
      'MUST 4: a rust/ change is named, not silently judged against this tree binary: ' + r.stdout.slice(-400));
  }

  // ---- JSON is what a consumer parses ---------------------------------------------------------------
  git('checkout', '-qB', 'change/fix2', 'main');
  write('lua/knob.txt', 'VALUE=new5\n');
  write('scripts/test-good.sh', 'grep -q VALUE=new5 lua/knob.txt || { echo "FAIL: the knob is still old"; exit 1; }\n');
  commit('the fix again');
  {
    const r = run('main', '--json');
    const line = r.stdout.split('\n').find(l => l.startsWith('{"rows"'));
    let parsed = null;
    try { parsed = JSON.parse(line); } catch { parsed = null; }
    ok(parsed !== null, 'the --json line parses as JSON: ' + line);
    ok(parsed?.rows?.some(x => x.verdict === 'discriminates' && x.test === 'scripts/test-good.sh'),
      'the JSON keeps the verdict and the file');
  }

  // ---- a REFACTOR-ONLY branch is exempt from discriminating, and must stay GREEN --------------------
  fresh('change/refactor');
  write('scripts/test-existing.sh', 'echo ok # the refactor moved nothing\n');
  write('scripts/test-red.sh', 'echo "FAIL: red on the refactored code"; exit 1\n');
  write('docs/missions/reports/fixture.md', 'Refactor-only: the value moves, nothing else changes\n');
  commit('a refactor');
  {
    const r = run('main');
    const rows = rowsOf(r.stdout);
    ok(/refactor-only/.test(r.stdout), 'the refactor declaration is echoed');
    verdictIs(rows, 'scripts/test-existing.sh', 'green', 'a green test is the evidence on a refactor');
    verdictIs(rows, 'scripts/test-red.sh', 'does-not', 'a test red on the refactored code blocks');
    ok(r.status === 1, 'refactor mode blocks on a red test: exit ' + r.status);
  }

  // MUST 5: one Refactor-only line cannot speak for a round of several branches.
  {
    const r = spawnSync('bash', [SUBJECT, '--repo', repo, '--branches', 'change/refactor,change/fix2', 'main'],
      {cwd: home, env, encoding: 'utf8'});
    ok(r.status === 76 && /refactor-only/i.test(r.stdout + r.stderr),
      'MUST 5: a mixed round with a Refactor-only line is refused by name: exit ' + r.status);
  }

  // ---- a branch with NO new test, and a base that is not a commit ------------------------------------
  fresh('change/no-test');
  write('lua/knob.txt', 'VALUE=changed\n');
  commit('no test');
  {
    const r = run('main');
    ok(r.status === 0, 'a branch with no new test does not invent a verdict: exit ' + r.status);
    ok(/adds or changes no test/.test(r.stdout), 'and it says why it had nothing to check');
  }
  {
    const r = run('no-such-ref');
    ok(r.status === 76, 'an unreadable base refuses with 76, got ' + r.status);
    ok(/refused/.test(r.stdout + r.stderr), 'and the refusal is named');
  }

  // MUST 1 (r2): a round that judges NOTHING - every row a named non-judgment - must not block a landing.
  // Two shapes: a rust/ change whose only tests are Lua (all unrevertable), and a branch that only
  // DELETES a test (not-applicable). Both exited 3 and blocked every landing of that shape.
  fresh('change/rust-only-lua');
  write('rust/thing.rs', 'fn main() {}\n');
  // A LUA row: only Lua rows are unrevertable under a rust/ change, which is the shape that blocked.
  write('scripts/test-lua-only.lua', 'assert(true, "a lua row")\n');
  commit('rust plus a lua test');
  {
    const r = run('main');
    ok(r.status === 0, 'MUST 1: all rows unrevertable exits 0, never 3: got ' + r.status);
    ok(/nothing was judged/.test(r.stdout), 'MUST 1: and it says nothing was judged, not that it passed');
  }
  fresh('change/delete-only');
  git('rm', '-q', 'scripts/test-existing.sh');
  commit('delete a test only');
  {
    const r = run('main');
    ok(r.status === 0, 'MUST 1: a delete-only test change exits 0, got ' + r.status);
    ok(/nothing was judged/.test(r.stdout), 'MUST 1: and it names the non-judgment');
  }

  // ---- MUST 7: a row that GUARDS its scratch home is judged, not left unclassified ------------------
  // 22/11 (mission main-green-2): this script hands every row a scratch HOME. A row that guards it asks the
  // node which home it replaced (scripts/lib/scratch-home.lua, WA_HOME_BEFORE_OVERRIDE) and REFUSES with
  // exit 2 when the launcher replaced HOME without recording the original. Eleven rows - the ten
  // scripts/test-land-*.lua parts and scripts/test-font-setup.lua - were then `unclassified` and blocked a
  // landing for a fact about THIS script, not about the branch. The fixture below is that shape: a row that
  // refuses when the fact is missing and discriminates when it is there.
  fresh('change/guarded');
  write('lua/knob.txt', 'VALUE=guarded\n');
  write('scripts/test-guarded-home.sh', [
    '#!/usr/bin/env bash',
    '# The shape every guarded row has (scripts/lib/scratch-home.lua): the launcher replaced HOME, so the only',
    '# way this row can prove it is not on the operator home is the home the launcher recorded.',
    'real="${WA_HOME_BEFORE_OVERRIDE:-}"',
    'if [ -z "$real" ]; then',
    '  echo "REFUSED: the launcher replaced HOME and did not record the home it replaced"',
    '  exit 2',
    'fi',
    '# ...and the home it hands over may not be inside the operator store (scripts/lib/scratch-home.lua).',
    'case "${WASM_AGENT_HOME:-}" in',
    '  "$real"/.wasm-agent|"$real"/.wasm-agent/*)',
    '    echo "REFUSED: the row home is inside the operator store"',
    '    exit 2 ;;',
    'esac',
    'grep -q VALUE=guarded lua/knob.txt || { echo "FAIL: the knob is still the old value"; exit 1; }',
    '',
  ].join('\n'));
  commit('a guarded row');
  {
    const r = run('main');
    const rows = rowsOf(r.stdout);
    verdictIs(rows, 'scripts/test-guarded-home.sh', 'discriminates',
      'MUST 7: a row that guards its scratch home is judged, not unclassified');
    ok(r.status === 0, 'MUST 7: and it does not block the gate: exit ' + r.status);
  }

  // ---- MUST 8: a Lua row that cannot LOAD the code under test is new-symbol, not "discriminates" -----
  // MEASURED 22/11 (mission main-green-2): the row message is the host's own, verbatim -
  // `lua error: [string "bootstrap"]:1: lua_root_unreadable: <path>` - and it says the base has no such file.
  // The general assertion marker (`lua error:`) used to swallow it and report that the row had caught a bug.
  // A shell row here reproduces the exact text; the classifier reads text, so the shape is what is judged.
  fresh('change/cannot-load');
  write('lua/knob.txt', 'VALUE=load\n');
  write('scripts/test-cannot-load.sh', [
    '#!/usr/bin/env bash',
    "echo 'lua error: [string \"bootstrap\"]:1: lua_root_unreadable: scripts/lib/nothing-like-this.lua'",
    'exit 1',
    '',
  ].join('\n'));
  commit('a row that cannot load its subject');
  {
    const r = run('main');
    const rows = rowsOf(r.stdout);
    verdictIs(rows, 'scripts/test-cannot-load.sh', 'new-symbol',
      'MUST 8: a load failure is new-symbol, not evidence of a caught bug');
    ok(r.status === 0, 'MUST 8: and it does not block: exit ' + r.status);
  }

  // The real home is never the fixture.
  ok(env.WASM_AGENT_HOME === home && home !== os.homedir(), 'this check runs against a scratch home');
} finally {
  fs.rmSync(home, {recursive: true, force: true});
}

if (failed > 0) { console.error('test-discriminates: ' + failed + ' of ' + checks + ' checks failed'); process.exit(1); }
console.log('test-discriminates: ' + checks + ' checks ok');
