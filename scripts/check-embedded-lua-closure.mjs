// Every literal `dofile` target reachable from the binary's embedded Lua must itself be embedded.
//
// Why this exists: the build-generated `EMBEDDED` table is the whole module set an *installed*
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
// Non-literal targets are counted rather than guessed at. The deploy runtime check verifies
// the actual generated artifact with disk Lua disabled. Comments are stripped before the scan.
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
if (!source.includes('include!(concat!(env!("OUT_DIR"), "/embedded.rs"))')) die('generated registry is not wired into main.rs');
const registry = new Map();
function collect(dir) {
  for (const entry of fs.readdirSync(path.join(repo, dir), {withFileTypes:true})) {
    const name = dir + '/' + entry.name;
    if (entry.isDirectory()) collect(name);
    else if (/\.(lua|sql)$/.test(name)) registry.set(name, name);
  }
}
collect('lua/core'); collect('lua/vendor');
for (const name of ['AGENTS.orchestrator.md', 'AGENTS.subagents.md']) registry.set(name, name);

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
say('generated embedded registry: ' + registry.size + ' entries (' +
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
