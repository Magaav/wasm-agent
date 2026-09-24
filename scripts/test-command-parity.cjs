// The window and the CLI offer the same `/` commands, and this is what says so.
//
// `/update` and `/merge` were written into `wa chat` and into `ui/app.js` in the same change, and
// nothing held the two lists together afterwards. So the window's `/new` - which starts a thread, a
// thing the REPL needs just as much - simply did not exist in the CLI, the help stayed silent about
// it, and the only thing that could have caught that was a reader remembering the other surface is
// there. Two lists in two languages, kept in step by memory.
//
// So this reads the sources and compares them: the rows in `lua/core/commands.lua` (the CLI's list),
// the `COMMANDS` array in `ui/app.js` (the window's), the `elseif` arms in `lua/core/chat.lua` that
// must exist for every row, and the one sentence written twice on purpose (the `/merge` brief in
// `lua/core/merge.lua` and in `ui/app.js`).
//
// What it does *not* check: the sentences. The window says "still listed in the engine view" and this
// REPL says "still listed by `wa sessions`", because a reader of one cannot run the other's
// instruction. Names and promises are the shared contract; the words around them are each surface's
// own.
const fs = require('node:fs');
const assert = require('node:assert/strict');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const read = (file) => fs.readFileSync(path.join(root, file), 'utf8');
const ui = read('ui/app.js');
const commands = read('lua/core/commands.lua');
const chat = read('lua/core/chat.lua');
const merge = read('lua/core/merge.lua');

let checks = 0;

// The window's list: the names inside `const COMMANDS = [ ... ];`. The array is found first and the
// names read only from it, so a `/` string elsewhere in the file (a comment, a hint) cannot be
// mistaken for a command.
function windowCommands(text) {
  const start = text.indexOf('const COMMANDS = [');
  assert.notEqual(start, -1, 'ui/app.js: no `const COMMANDS = [` to read');
  const end = text.indexOf('\n];', start);
  assert.notEqual(end, -1, 'ui/app.js: the COMMANDS array is not closed');
  const names = [];
  for (const match of text.slice(start, end).matchAll(/name:\s*"(\/[a-z-]+)"/g)) names.push(match[1]);
  return names;
}

// The CLI's list: `{ name = "/x", ... }` rows, and the aliases they declare. That row shape is the
// contract this reads - it is why `commands.lua` holds data rather than prose.
function cliCommands(text) {
  const names = [];
  const aliases = [];
  for (const row of text.matchAll(/\{\s*name\s*=\s*"(\/[a-z-]+)"/g)) names.push(row[1]);
  for (const alias of text.matchAll(/alias\s*=\s*\{\s*"(\/[a-z-]+)"/g)) aliases.push(alias[1]);
  return { names, aliases };
}

// A command is handled when `chat.lua` compares the typed line to it, whole or as a prefix with
// arguments (`line:sub(1, 10) == "/remember "`).
function armed(text, name) {
  return text.includes(`line == "${name}"`)
    || text.includes(`line:sub(1, ${name.length + 1}) == "${name} "`);
}

// Every double-quoted literal in a slice, joined: the `/merge` brief is one sentence spread over
// several source lines in each language, so the comparison is on the sentence, not on the layout.
function literals(text, from, to) {
  const out = [];
  for (const match of text.slice(from, to).matchAll(/"((?:[^"\\]|\\.)*)"/g)) out.push(match[1]);
  return out.join(' ').replace(/\s+/g, ' ').trim();
}

// The window's brief: one `const` statement of `"..." +` lines. The pieces are read one after another
// rather than by slicing to the next `;` - the sentence contains one ("Escalate a conflict; never
// force it"), and a rule about punctuation inside prose is a rule that breaks on the next edit.
function windowBrief(text) {
  const marker = 'const ORCHESTRATOR_BRIEF = ';
  const at = text.indexOf(marker);
  assert.notEqual(at, -1, 'ui/app.js: ORCHESTRATOR_BRIEF is gone');
  const out = [];
  let cursor = at + marker.length;
  for (;;) {
    const match = /^\s*"((?:[^"\\]|\\.)*)"\s*(\+)?/.exec(text.slice(cursor));
    if (!match) break;
    out.push(match[1]);
    cursor += match[0].length;
    if (!match[2]) break; // no trailing `+`: the statement ends here
  }
  assert.ok(out.length > 0, 'ui/app.js: ORCHESTRATOR_BRIEF has no string in it');
  return out.join(' ').replace(/\s+/g, ' ').trim();
}

// The CLI's brief: `table.concat({ ... }, " ")`.
function luaBrief(text) {
  const at = text.indexOf('M.brief = table.concat({');
  assert.notEqual(at, -1, 'lua/core/merge.lua: M.brief is gone');
  const stop = text.indexOf('}, " ")', at);
  assert.notEqual(stop, -1, 'lua/core/merge.lua: M.brief is not closed by `}, " ")`');
  return literals(text, at, stop);
}

function checkSurface(options = {}) {
  const { uiText = ui, cliText = commands, chatText = chat } = options;
  const offered = windowCommands(uiText);
  const { names, aliases } = cliCommands(cliText);

  // A regex that stopped matching would make every rule below pass while checking nothing.
  assert.ok(offered.length >= 3, `the window's list no longer parses: found ${offered.length} commands`);
  assert.ok(names.length >= 3, `the CLI's list no longer parses: found ${names.length} rows`);
  checks += 2;

  for (const required of ['/new', '/update', '/merge']) {
    assert.ok(offered.includes(required), `ui/app.js no longer offers ${required}`);
    assert.ok(names.includes(required), `lua/core/commands.lua no longer offers ${required}`);
    checks += 2;
  }

  // The direction that matters: the window may not offer what this REPL cannot do. The REPL may offer
  // more - it is the process holding the ledger, so `/remember`, `/recall` and `/console` are its own.
  const missing = offered.filter((name) => !names.includes(name));
  assert.deepEqual(missing, [], `the window offers commands the CLI does not have: ${missing.join(', ')}`);
  checks += 1;

  // A row with no arm is a promise the REPL cannot keep, and the one a reader finds by trying it.
  const unarmed = [...names, ...aliases].filter((name) => !armed(chatText, name));
  assert.deepEqual(unarmed, [], `lua/core/commands.lua lists commands chat.lua does not handle: ${unarmed.join(', ')}`);
  checks += 1;

  // The help's hint column is fixed, so a usage wider than it silently pushes every hint right. The
  // rows are read from the `M.commands` block only: `M.usage` is the usage *line*, ten times wider
  // than any row, and a check that reads it would fail forever.
  const column = Number((cliText.match(/M\.COLUMN = (\d+)/) || [])[1]);
  assert.ok(Number.isInteger(column), 'lua/core/commands.lua: no M.COLUMN to align the help with');
  const block = cliText.slice(cliText.indexOf('M.commands = {'));
  assert.ok(block.includes('usage = "'), 'lua/core/commands.lua: no M.commands rows to read');
  const usages = [...block.matchAll(/(?:^|\s)usage\s*=\s*"([^"]*)"/g)].map((match) => match[1]);
  assert.ok(usages.length >= 3, `the CLI's usages no longer parse: found ${usages.length}`);
  const wide = usages.filter((usage) => usage.length > column);
  assert.deepEqual(wide, [], `usages wider than the help column (${column}): ${wide.join(', ')}`);
  checks += 3;

  return { offered, names, aliases };
}

checkSurface();

const offeredBrief = windowBrief(ui);
const promisedBrief = luaBrief(merge);
assert.ok(offeredBrief.includes('skills/git-orchestrator'),
  'the /merge brief must name the skill that holds the procedure');
assert.ok(offeredBrief.includes('never force it'), 'the /merge brief must say a conflict is escalated');
assert.equal(offeredBrief, promisedBrief,
  'the /merge brief differs between ui/app.js and lua/core/merge.lua: it is written twice so that the '
  + 'trigger is one word in both surfaces, and the sentence is what says which procedure it triggers');
checks += 3;

// A rule that cannot fail is not a check, so each one is run against a text it must reject. Four of
// these are the real future drift: a command added to the window, a row added without an arm, a row
// whose usage breaks the help's column, and one of the two briefs edited on one side only.
const rejects = [
  ['a window command missing from the CLI',
    () => checkSurface({ cliText: commands.replace('name = "/new"', 'name = "/brand-new"') })],
  ['a CLI row with no arm in the REPL',
    () => checkSurface({ chatText: chat.replace('elseif line == "/new" then', 'elseif line == "/brand-new" then') })],
  ['a window command the CLI does not have',
    () => checkSurface({ uiText: ui.replace('const COMMANDS = [', 'const COMMANDS = [\n  { name: "/delete", run: () => {} },') })],
  ['a usage wider than the help column',
    () => checkSurface({ cliText: commands.replace('usage = "/session"', 'usage = "/session-that-is-too-long"') })],
  ['a list that stopped parsing',
    () => checkSurface({ uiText: ui.replace('const COMMANDS = [', 'const COMMANDS_LIST = [') })],
  ['a one-sided edit of the /merge brief',
    () => assert.equal(windowBrief(ui.replace('Act as the git orchestrator', 'Act as the merge helper')), promisedBrief)],
];
for (const [label, mutate] of rejects) {
  assert.throws(mutate, Error, `must fail: ${label}`);
}
checks += rejects.length;

console.log(`command parity ok (${checks} checks, 0 skipped; sources, not a live REPL)`);
