// Every literal `dofile` target reachable from the binary's embedded Lua must itself be embedded.
//
// Why this exists: `rust/wa-host/src/main.rs`'s `EMBEDDED` table is the whole module set an *installed*
// node has. A node runs with no `WASM_AGENT_LUA_ROOT` (that is the shipped shape; `deploy.sh` ships it
// that way and `wa-sentinel/src/instance.rs` protects it), so `dofile("scripts/...")` and any other path
// the table does not carry resolves in a checkout and dies in production with
// `embedded module missing: <name>`. That is exactly how `wa subscription login` shipped broken:
// `lua/core/init.lua` loaded `scripts/openai-sub-login.lua`, the table carries `lua/` and nothing under
// `scripts/`, and no test could see it because `scripts/test.sh` exports a Lua root for everything it
// runs. The login CLI now lives in `lua/core/openai_sub_login.lua` and this check is what notices the
// next one.
//
// What it checks, mechanically: the `EMBEDDED` keys are the registry; starting from them, follow every
// *literal* `dofile("x")` reachable in the tree, and fail naming each target that is not a registry key.
// Non-literal targets (`dofile(some_variable)`) cannot be checked statically, so they are counted and
// printed rather than guessed at. A parse that does not account for every `include_str!` in the table is
// a failure, not a smaller answer - a partial registry is how this check would pass vacuously. Comments
// and string literals are stripped before the scan, so a comment that names a path is not a call.
//
//   node scripts/check-embedded-lua-closure.mjs [repo root]
import fs from 'node:fs';
import path from 'node:path';

const BACKSLASH = String.fromCharCode(92);
const repo = path.resolve(process.argv[2] || process.cwd());
const mainRs = path.join(repo, 'rust', 'wa-host', 'src', 'main.rs');
const say = message => process.stdout.write(message + '\n');
const die = message => { process.stderr.write('check-embedded-lua-closure: ' + message + '\n'); process.exit(1); };

if (!fs.existsSync(mainRs)) die('no ' + mainRs + ' - run this from the repository root');

const source = fs.readFileSync(mainRs, 'utf8');
const start = source.indexOf('const EMBEDDED');
if (start < 0) die('no EMBEDDED table in ' + mainRs);
const table = source.slice(start, source.indexOf('];', start));

const entries = (table.match(/include_str!/g) || []).length;
const registry = new Map();
for (const match of table.matchAll(/\(\s*"([^"]+)"\s*,\s*include_str!\(\s*"([^"]+)"\s*\)\s*\)/g)) {
  registry.set(match[1], match[2]);
}
if (registry.size === 0) die('the EMBEDDED table parsed as empty - this check would pass vacuously');
if (registry.size !== entries) {
  die('parsed ' + registry.size + ' of ' + entries + ' EMBEDDED entries in ' + mainRs +
    ' - a partial parse silently checks a partial registry, so this is a failure and not a smaller answer');
}

const problems = [];
const seen = new Set();
const queue = [...registry.keys()];
let filesRead = 0;
let literals = 0;
let dynamic = 0;

// Comments are not calls. A comment that *names* a `dofile` target (as this delivery's own explanation
// does, and as any future author's will) must not fail the gate: the first run of this check reported
// the path out of a comment in `lua/core/openai_sub_login.lua`, which is a false positive and would
// train the next reader to ignore the check. Strings are tracked so that a `--` inside one does not
// start a comment; long `[[ ]]` blocks are removed whole.
function stripComments(text) {
  return text
    .replace(/--\[\[[\s\S]*?\]\]/g, '')
    .split('\n')
    .map(line => {
      let quote = null;
      for (let at = 0; at < line.length; at += 1) {
        const ch = line[at];
        if (quote) { if (ch === BACKSLASH) { at += 1; continue; } if (ch === quote) quote = null; continue; }
        if (ch === '"' || ch === "'") { quote = ch; continue; }
        if (ch === '-' && line[at + 1] === '-') return line.slice(0, at);
      }
      return line;
    })
    .join('\n');
}

while (queue.length > 0) {
  const name = queue.shift();
  if (seen.has(name) || !name.endsWith('.lua')) continue;
  seen.add(name);
  const file = path.join(repo, name);
  if (!fs.existsSync(file)) {
    problems.push({ from: '(the registry itself)', target: name, why: 'registered but not on disk' });
    continue;
  }
  filesRead += 1;
  const lines = stripComments(fs.readFileSync(file, 'utf8')).split('\n');
  lines.forEach((line, index) => {
    // Two patterns rather than one with a backreference: this file has to survive being written, copied
    // and reviewed, and a pattern that needs a backslash escape is the one that quietly stops matching
    // after an editing accident. (It did, in the first draft of this file: 55 entries, 0 matches.)
    for (const pattern of [/dofile\(\s*'([^']*)'/g, /dofile\(\s*"([^"]*)"/g]) {
      for (const match of line.matchAll(pattern)) {
        literals += 1;
        let target = match[1].split(BACKSLASH).join('/');
        if (target.startsWith('./')) target = target.slice(2);
        if (registry.has(target)) { queue.push(target); continue; }
        problems.push({ from: name + ':' + (index + 1), target, why: 'not in EMBEDDED' });
      }
    }
    for (const _ of line.matchAll(/dofile\(\s*[A-Za-z_][^)'"]*/g)) dynamic += 1;
  });
}

const luaEntries = [...registry.keys()].filter(name => name.endsWith('.lua')).length;
say('embedded registry: ' + registry.size + ' entries, all ' + entries + ' include_str! accounted for (' +
  luaEntries + ' .lua)');
say('traversed: ' + filesRead + ' embedded file(s), ' + literals + ' literal dofile target(s), ' +
  dynamic + ' non-literal (not checkable statically)');
say('module names reached by following literals: ' + seen.size);

if (problems.length > 0) {
  for (const problem of problems) {
    say('MISSING ' + problem.target + '  (required by ' + problem.from + ': ' + problem.why + ')');
  }
  die(problems.length + ' dofile target(s) are not in the binary\'s EMBEDDED registry: ' +
    problems.map(problem => problem.target).join(', ') +
    ' - an installed node has no Lua root, so each of these is readable in a checkout and absent where it ships');
}

say('embedded lua closure ok: every literal dofile target reachable from the registry is in the registry');
