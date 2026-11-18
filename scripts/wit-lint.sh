#!/usr/bin/env bash
# A WIT seam has two shapes this check refuses, and both are about what a boundary *says*, not about
# what it compiles to (ARCHITECTURE.md, "Seams are WIT, and async by default").
#
# RULE 1 - a 'string' that carries JSON says so in its name. WIT has no recursive types, so "any JS
# value" crosses a seam as a *-json string. That is allowed, and it is exactly why the name has to carry
# it: a reader who sees 'args: string' cannot tell the user's own JavaScript values from a tool's name,
# its route or a reason word. A field or a parameter whose type is string (or option<string>) whose
# NAME or whose DOC COMMENT says it carries JSON must therefore be named *-json. Measured on this tree:
# 18 such names already comply (codemode.wit's schema-json/args-json/payload-json/result-json/
# entry-json, quickjs.wit's tools-json/globals-json/store-json, hooks.wit's updated-input-json/
# input-changes-json, model.wit's arguments-json/schema-json/policy-json), and the three that do not
# are in the baseline with the reason they cannot move today.
#
# RULE 2 - nothing new exposes a status to poll. Work that takes time returns a future and output that
# keeps coming is a stream; a status/poll/await-*/wait-* func that sits beside a func handing out an
# operation handle or id is the shape those two replace - unless its own doc comment marks it
# "legacy wrapper over <future-func>", which is how a seam whose ABI a shipped component still imports
# says so in the file. The ones on main are in the baseline, so the rule binds new code without
# breaking the tree (scripts/wit-lint-baseline.txt).
#
# HOW A FILE IS READ, because each of these shapes was a hole once:
#   * a declaration ends where WIT's punctuation says it does, not at the newline. 'record r { args:
#     string }' is an opener, a field and a close on one line; 'a: string, b: u32,' is two fields; and
#     a func split as 'status:' with 'func(id: operation-id) -> ...' under it is ONE declaration.
#     Every line is cut on {, } and on the , / ; that end a declaration at depth 0 of a <...>/_(...),
#     and a piece that ends nothing is continued onto the next line. Without that, a one-line record
#     hid its fields and left its block open (later declarations were attributed to it), a
#     comma-separated field list was skipped, and a split func name was invisible.
#   * %status is WIT's escape for a name that collides with a keyword: the declared name is 'status',
#     so the % is stripped before a name is matched.
#   * "application/json" is a MIME type and "never JSON" (or "no JSON here") is a denial. Neither is a
#     field saying it carries a JSON value, so MIME types are stripped and a negated clause is
#     skipped instead of the whole doc being discounted.
#   * a -id return is the handle of a poll ONLY when the poll func takes that id as a parameter:
#     'status: func() -> health' beside 'self-id: func() -> node-id' reads two values, it does not
#     hand out a handle.
#   * a start-ish func at interface level that hands out a resource is a sibling of that resource's
#     own funcs: 'start: func() -> job' beside 'resource job { poll }' is the pair the rule exists
#     for, even though the two funcs sit in different blocks.
#
# WHAT THIS DOES NOT COVER, said here because a verdict read for more than it says is worse than no
# verdict:
#   * a list<u8> field that carries JSON (hooks.wit's row.json is one). The rule is about 'string',
#     because that is where the confusion lives; a bytes field is a different call, and REPORT.md lists
#     it rather than this check judging it.
#   * a variant case's payload (failed(string)), which has no name of its own to carry -json.
#     wit/memory/deps/kernel/kernel.wit's journal-entry.payload is the measured case: the same field
#     this rule flags in wit/kernel/sql.wit, unseen here because that copy carries no doc comment. The
#     rule reads what a file says, never what a copy of it meant.
#   * a mention of a JSON *file* is not a mention of a JSON *value*: 'kind: string' documented
#     "native (hooks.json) or claude (settings.json)" is not a JSON-carrying field, and filenames are
#     stripped before a doc is read (scripts/test-wit-lint.sh proves that case).
#   * a parameter's doc is its function's doc (WIT has no per-parameter doc), so the doc only counts
#     when it says so about that parameter BY NAME ("config is the non-secret configuration object
#     (JSON text)"). A function doc describing its RETURN value ("The JSON text of one granted key")
#     is not read as describing its 'key' parameter - also proved there. For the same reason a
#     baseline line for a parameter names its FUNCTION (run.config): two funcs of one interface can
#     each take a 'config: string', and a key that named only the parameter would accept the second
#     one as already recorded.
#
#   bash scripts/wit-lint.sh [--list]
#   WIT_LINT_DIR=<dir> WIT_LINT_BASELINE=<file> bash scripts/wit-lint.sh     # the fixtures' door
#
# One interpreter run, one pass per file, one read of the baseline: seconds, no toolchain, no network.
set -euo pipefail
cd "$(dirname "$0")/.."
export WIT_LINT_DIR="${WIT_LINT_DIR:-wit}"
export WIT_LINT_BASELINE="${WIT_LINT_BASELINE:-scripts/wit-lint-baseline.txt}"
exec node --input-type=module - "$@" <<'NODE'
import fs from 'node:fs';
import path from 'node:path';

const ROOT = process.cwd();
const DIR = process.env.WIT_LINT_DIR;
const BASELINE = process.env.WIT_LINT_BASELINE;
const list = process.argv.includes('--list');

function witFiles(dir, out) {
  let entries;
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return out; }
  for (const entry of entries.sort((a, b) => (a.name < b.name ? -1 : 1))) {
    const p = path.join(dir, entry.name);
    if (entry.isDirectory()) witFiles(p, out);
    else if (p.endsWith('.wit')) out.push(p);
  }
  return out;
}
const files = witFiles(DIR, []);
if (!files.length) {
  console.log('FAIL wit-lint: no .wit file under ' + DIR + ' (a check that judges nothing is not a pass)');
  process.exit(2);
}

// ---- reading the text ---------------------------------------------------------------------------
// The doc comment a declaration carries is the run of /// lines immediately above it. A blank line
// ends the run: in WIT a blank line separates a package's prose from its first declaration, so it has
// to separate two declarations the same way.
function stripFilenames(text) {
  // hooks.json / settings.json name a FILE a value was read from, not a value that is JSON.
  return String(text || '').replace(/[A-Za-z0-9_./\\-]*\.json\b/g, ' ');
}
function stripMimes(text) {
  // application/json names the media type a header carries, not a value this field holds.
  return String(text || '').replace(/\b[A-Za-z0-9.+-]+\/[A-Za-z0-9.+-]*json\b/gi, ' ');
}
// A clause that denies JSON ("never JSON", "carries no JSON", "isn't a JSON value") is not a clause
// that says a value IS JSON. The mention is skipped clause by clause, never the whole doc: "a FILE
// name, never a value" and "the args are JSON, never a stringified blob" both have to read right.
const NEGATION = /\b(?:never|not|no|none|without|neither|nor|isn't|aren't|wasn't|doesn't|don't|does not|do not|must not|rather than)\b[^.;:!]{0,40}?\bjson\b/i;
function jsonClauses(text) {
  const clean = stripMimes(stripFilenames(text));
  const out = [];
  for (const clause of clean.split(/[.;:!\n]/)) {
    if (!/\bjson\b/i.test(clause)) continue;
    if (NEGATION.test(clause)) continue;
    out.push(clause.toLowerCase());
  }
  return out;
}
function mentionsJson(text) { return jsonClauses(text).length > 0; }

function splitTop(text) {
  // Split on the commas that separate top-level items. '>' closes a generic only when it is not the
  // arrow's ('func() -> x' must not make the depth negative, or the commas inside the result count).
  const out = []; let depth = 0, cur = '', prev = '';
  for (const ch of String(text)) {
    if (ch === '<' || ch === '(') depth++;
    else if (ch === ')') { if (depth > 0) depth--; }
    else if (ch === '>' && prev !== '-') { if (depth > 0) depth--; }
    if (ch === ',' && depth === 0) { out.push(cur.trim()); cur = ''; prev = ch; continue; }
    cur += ch; prev = ch;
  }
  if (cur.trim()) out.push(cur.trim());
  return out;
}
function unwrap(type) {
  let t = String(type).trim();
  for (;;) {
    const m = t.match(/^(?:option|result)<(.*)>$/);
    if (!m) return t;
    t = splitTop(m[1])[0].trim();
  }
}
function escapeRe(s) { return String(s).replace(/[.*+?^()[\]\\{}|]/g, (ch) => '\\' + ch); }
// A parameter has no doc of its own in WIT, so its function doc speaks for it only when it makes the
// parameter the SUBJECT of a clause that says JSON: "config is the non-secret configuration object
// (JSON text)". A function doc describing its RETURN value ("The JSON text of one granted key") does
// not make a parameter its subject, so it must not flag one - the case scripts/test-wit-lint.sh fails
// the check on if this ever widens.
function docNamesCarryingParam(doc, name) {
  const named = new RegExp('\\b' + escapeRe(String(name).toLowerCase()) + '\\b');
  for (const clause of jsonClauses(doc)) {
    if (!named.test(clause)) continue;
    if (/\b(?:is|are|carries|carry|holds|hold)\b/.test(clause)) return true;
  }
  return false;
}
const STARTISH = /^(?:start|submit|spawn|begin|dispatch|enqueue|schedule)/;
// The two NAMES are exact and only the two prefixes are prefixes: a func called poll-op is not the
// pair this rule describes, so status and poll match whole names and await-/wait- match a suffix.
const POLLISH = /^(?:status|poll)$|^(?:await|wait)-/;

// ---- cutting a line into declarations ------------------------------------------------------------
// WIT's punctuation ends a declaration, not the newline. Each line becomes events in order:
//   {kind:'text', text, end}  where end is the ; , { or } that ended it ('' = nothing, continue on)
//   {kind:'close'}            a } with no text of its own (the block it closes was declared earlier)
// A } that follows text emits the text first, then the close, so 'args: string }' is a field and the
// end of its record.
// The depth of a <...>/(...) carries ACROSS lines of one declaration: a func whose parameters are
// written one per line opens a paren that the next lines are inside of, and a ',' in there does not
// end anything.
function lineEvents(text, startDepth) {
  const events = []; let cur = '', depth = startDepth || 0, prev = '';
  const flush = (end) => { const t = cur.trim(); cur = ''; if (t) events.push({ kind: 'text', text: t, end }); };
  for (const ch of String(text)) {
    if (ch === '<' || ch === '(') depth++;
    else if (ch === ')') { if (depth > 0) depth--; }
    else if (ch === '>' && prev !== '-') { if (depth > 0) depth--; }
    if (depth === 0 && (ch === '{' || ch === '}')) {
      flush(ch);
      if (ch === '}') events.push({ kind: 'close' });
      prev = ch; continue;
    }
    if (depth === 0 && (ch === ',' || ch === ';')) { flush(ch); prev = ch; continue; }
    cur += ch; prev = ch;
  }
  flush('');
  return { events, depth };
}

const strings = [];        // every string field/parameter: what crosses the seam, in one table
const funcs = [];          // every func: name, context, return type, parameters, doc
const resourceNames = new Set();

for (const file of files) {
  // The key is relative to the wit directory, never to the checkout: a baseline line must mean the
  // same thing in every tree (and in a fixture under /tmp), or it is a key nobody can keep.
  const rel = path.relative(DIR, file).split(path.sep).join('/');
  const lines = fs.readFileSync(file, 'utf8').split('\n');
  const stack = [];
  let doc = [];
  let pending = null;   // a declaration that has not reached its ; , { or } yet
  const context = () => stack.join('/');

  function parseParam(param) {
    const at = param.indexOf(':');
    if (at < 0) return null;
    return { name: param.slice(0, at).trim().replace(/^%/, ''), type: param.slice(at + 1).trim() };
  }

  // One declaration, complete: an opener, a type alias, a func or a field.
  function declare(text, line, docLines) {
    const trimmed = String(text).trim();
    if (!trimmed) { doc = []; return; }
    const opened = trimmed.match(/^(interface|resource|record|variant|enum|flags|world)\s+([a-z0-9-]+)/);
    if (opened) {
      if (opened[1] === 'resource') resourceNames.add(opened[2]);
      stack.push(opened[1] + ':' + opened[2]);
      doc = [];
      return;
    }
    if (/^type\s+%?[a-z0-9-]+\s*=/.test(trimmed)) { doc = []; return; }
    // static can sit on either side of the colon (start: static func(...)), so both are allowed; the
    // % of a %status name is WIT's keyword escape and not part of the name.
    const fname = trimmed.match(/^(?:static\s+)?%?([a-z][a-z0-9-]*)\s*:\s*(?:static\s+)?(?:async\s+)?func\b/);
    if (fname) {
      const open = trimmed.indexOf('('), close = trimmed.lastIndexOf(')');
      const params = open >= 0 && close > open
        ? splitTop(trimmed.slice(open + 1, close)).map(parseParam).filter(Boolean) : [];
      const ret = trimmed.includes('->') ? trimmed.slice(trimmed.indexOf('->') + 2).replace(/;\s*$/, '').trim() : '';
      const fnDoc = docLines.join(' ');
      const fnContext = context();
      for (const param of params) {
        if (unwrap(param.type) !== 'string') continue;
        // The doc speaks about a parameter only when it names it in a carrying phrase.
        strings.push({
          file: rel, line, context: fnContext, where: 'parameter of ' + fname[1], fn: fname[1],
          name: param.name, type: param.type, doc: fnDoc, member: fname[1] + '.' + param.name,
          carries: mentionsJson(param.name) || docNamesCarryingParam(fnDoc, param.name),
        });
      }
      funcs.push({ file: rel, line, context: fnContext, name: fname[1], ret, doc: fnDoc, params });
      doc = [];
      return;
    }
    const field = trimmed.match(/^%?([a-z][a-z0-9-]*)\s*:\s*([^=]+?)$/);
    if (field && !/^(?:use|include|export|import|type)\b/.test(trimmed)) {
      const name = field[1], type = field[2].trim();
      if (unwrap(type) === 'string') {
        const fieldDoc = docLines.join(' ');
        strings.push({
          file: rel, line, context: context(), where: 'field', fn: '', name, type,
          doc: fieldDoc, member: name,
          carries: mentionsJson(name) || mentionsJson(fieldDoc),
        });
      }
    }
    doc = [];
  }

  for (let i = 0; i < lines.length; i++) {
    const trimmed = lines[i].replace(/[ \t]+$/, '').trim();
    if (trimmed.startsWith('///')) {
      if (pending) { declare(pending.text, pending.line, pending.doc); pending = null; }
      doc.push(trimmed.replace(/^\/\/\/\s?/, ''));
      continue;
    }
    if (trimmed === '') {
      if (pending) { declare(pending.text, pending.line, pending.doc); pending = null; }
      doc = [];
      continue;
    }
    if (trimmed.startsWith('//')) continue;
    // A // comment at the end of a line is not part of the declaration (a /// was taken above).
    const code = trimmed.replace(/(?<!:)\/\/.*$/, '').trim();
    if (!code) continue;
    // @since(version = 0.2.0) / @unstable(feature = ...) is an ANNOTATION on the declaration under
    // it, not a declaration: it neither ends the doc run above it nor joins the next line's text, or
    // every annotated func in the wasi deps disappears from this check.
    if (/^@[a-z][a-z0-9-]*\s*\([^)]*\)\s*$/.test(code)) continue;
    // use types.{error}; is a USE LIST, not a block: its braces must not open and close one, or the
    // interface around it is popped here and every later declaration is attributed to nothing.
    if (/^(?:use|include|export|import)\b/.test(code) || (pending && pending.stmt === 'use')) {
      if (!pending) pending = { text: code, line: i + 1, doc: doc.slice(), stmt: 'use', depth: 0 };
      else pending.text += ' ' + code;
      if (/;\s*$/.test(pending.text)) { declare(pending.text, pending.line, pending.doc); pending = null; }
      continue;
    }
    const scanned = lineEvents(code, pending ? pending.depth : 0);
    for (const ev of scanned.events) {
      if (ev.kind === 'close') {
        if (pending) { declare(pending.text, pending.line, pending.doc); pending = null; }
        if (stack.length) stack.pop();
        doc = [];
        continue;
      }
      if (!pending) pending = { text: ev.text, line: i + 1, doc: doc.slice(), depth: 0 };
      else pending.text += ' ' + ev.text;
      if (ev.end) { declare(pending.text, pending.line, pending.doc); pending = null; }
    }
    if (pending) pending.depth = scanned.depth;
  }
  if (pending) declare(pending.text, pending.line, pending.doc);
}

// ---- rule 1: a string that carries JSON is named *-json -----------------------------------------
const jsonNamed = strings.filter((s) => /-json$/.test(s.name));
const violations = [];
for (const s of strings) {
  if (!s.carries || /-json$/.test(s.name)) continue;
  violations.push({
    rule: 'json-name', file: s.file, line: s.line, context: s.context, name: s.member,
    why: (mentionsJson(s.name) ? 'the name says JSON' : 'the doc comment says it is JSON') +
      ', and ' + s.name + ': ' + s.type + ' does not carry -json in the name',
  });
}

// ---- rule 2: a polling func beside an operation handle ------------------------------------------
// The handle a caller would poll by: a return type that names an operation, an id the poll func
// itself takes, or a resource a start-ish func hands out (the start/poll pair). Everything else - an
// HTTP status code, a keystore's root-status, a node's own self-id - is a read, not a poll, and is
// not flagged.
function handleOf(fn, poller) {
  const ret = unwrap(fn.ret);
  if (/operation/.test(ret)) return ret;
  if (/(?:^|-)id$/.test(ret)) {
    // The id has to be what the poll func asks with. 'self-id: func() -> node-id' beside
    // 'status: func() -> health' hands out no handle: nothing is polled by it.
    const taken = (poller.params || []).some((p) => unwrap(p.type) === ret || p.name === ret);
    return taken ? ret : '';
  }
  if (STARTISH.test(fn.name) && resourceNames.has(ret)) return 'resource:' + ret;
  return '';
}
const byContext = new Map();
for (const fn of funcs) {
  if (!byContext.has(fn.context)) byContext.set(fn.context, []);
  byContext.get(fn.context).push(fn);
}
for (const [context, siblings] of byContext) {
  // A func inside 'resource R' also sits beside the start-ish funcs of the block that declares R: the
  // pair is 'start: func() -> job' at interface level and 'poll' inside 'resource job', and the two
  // are not siblings of each other in the text.
  const inResource = context.match(/^(.*)\/resource:([a-z0-9-]+)$/);
  const outers = inResource
    ? (byContext.get(inResource[1]) || []).filter((f) => STARTISH.test(f.name) && unwrap(f.ret) === inResource[2])
    : [];
  for (const fn of siblings) {
    if (!POLLISH.test(fn.name)) continue;
    let handle = '', beside = '';
    for (const other of [...outers, ...siblings]) {
      if (other === fn) continue;
      const h = handleOf(other, fn);
      if (h) { handle = h; beside = other.name; break; }
    }
    if (!handle) continue;
    if (/legacy wrapper over\s+[a-z0-9-]+/i.test(fn.doc)) continue;
    violations.push({
      rule: 'poll-without-future', file: fn.file, line: fn.line, context, name: fn.name,
      why: fn.name + ' sits beside ' + beside + ' handing out ' + handle +
        ': return a future/stream instead, or mark the doc "legacy wrapper over <future-func>"',
    });
  }
}

// ---- the baseline -------------------------------------------------------------------------------
// <rule> <file> <context> <name>   # the ones on main, each with the reason it stays. A baseline line
// that no longer matches anything FAILS: a hole that was closed must leave the file, or the file
// stops being a list of what is still true (the rule scripts/test-orphan-tests.mjs already keeps).
// A parameter's <name> is func.param: the function is part of what the line claims.
const baseline = new Map();
if (fs.existsSync(BASELINE)) {
  for (const raw of fs.readFileSync(BASELINE, 'utf8').split('\n')) {
    const line = raw.trim();
    if (!line || line.startsWith('#')) continue;
    const [rule, file, context, name] = line.split(/\s+/);
    if (!rule || !file || !context || !name) {
      console.log('FAIL wit-lint: ' + BASELINE + ' has a line that is not "<rule> <file> <context> <name> <reason>": ' + line);
      process.exit(1);
    }
    baseline.set([rule, file, context, name].join('|'), line);
  }
}
const key = (v) => [v.rule, v.file, v.context, v.name].join('|');
const known = new Set();
const fresh = [];
for (const v of violations) {
  if (baseline.has(key(v))) { known.add(key(v)); continue; }
  fresh.push(v);
}
const stale = [...baseline.keys()].filter((k) => !known.has(k));

if (list) {
  // What a listed name is: fine as it stands, recorded in the baseline, or a failure. The list is the
  // map REPORT.md keeps, so it says which of the three a name is rather than only that it mentions JSON.
  const state = (rule, file, context, name) => {
    const same = violations.some((v) => v.rule === rule && v.file === file && v.context === context && v.name === name);
    if (!same) return 'ok';
    return known.has([rule, file, context, name].join('|')) ? 'baselined' : 'FAIL';
  };
  for (const s of strings.filter((s) => s.carries)) {
    console.log(['string-carries-json', s.file, s.context, s.where + ' ' + s.name, s.type, state('json-name', s.file, s.context, s.member)].join('\t'));
  }
  for (const fn of funcs) if (POLLISH.test(fn.name)) console.log(['polling-func', fn.file, fn.context, fn.name, fn.ret || '-', /legacy wrapper over/i.test(fn.doc) ? 'legacy-wrapped' : state('poll-without-future', fn.file, fn.context, fn.name)].join('\t'));
  process.exit(0);
}

for (const v of fresh) console.log('FAIL wit-lint: ' + v.file + ':' + v.line + ' [' + v.context + '] ' + v.name + ': ' + v.why);
for (const k of stale) console.log('FAIL wit-lint: ' + BASELINE + ' still lists "' + k.split('|').slice(1).join(' ') + '", which this check does not flag any more: remove the line');
const knownBy = (rule) => [...known].filter((k) => k.startsWith(rule + '|')).length;
if (fresh.length || stale.length) {
  console.log('wit-lint: ' + fresh.length + ' new violation(s), ' + stale.length + ' stale baseline line(s), ' + known.size + ' baselined');
  process.exit(1);
}
console.log('wit-lint ok (' + files.length + ' wit files, ' + strings.length + ' string field(s)/parameter(s), ' +
  jsonNamed.length + ' named *-json, ' + funcs.filter((f) => POLLISH.test(f.name)).length + ' polling func(s): ' +
  known.size + ' baselined (' + knownBy('json-name') + ' json-name, ' + knownBy('poll-without-future') + ' poll-without-future), 0 new)');
NODE
