#!/usr/bin/env bash
# A WIT seam has two shapes this check refuses, and both are about what a boundary *says*, not about
# what it compiles to (ARCHITECTURE.md, "Seams are WIT, and async by default").
#
# RULE 1 - a `string` that carries JSON says so in its name. WIT has no recursive types, so "any JS
# value" crosses a seam as a `*-json` string. That is allowed, and it is exactly why the name has to carry
# it: a reader who sees `args: string` cannot tell the user's own JavaScript values from a tool's name,
# its route or a reason word. A field or a parameter whose type is `string` (or `option<string>`) whose
# NAME or whose DOC COMMENT says it carries JSON must therefore be named `*-json`. Measured on this
# tree: 18 such names already comply (codemode.wit's
# `schema-json`/`args-json`/`payload-json`/`result-json`/`entry-json`, quickjs.wit's
# `tools-json`/`globals-json`/`store-json`, hooks.wit's `updated-input-json`/`input-changes-json`,
# model.wit's `arguments-json`/`schema-json`/`policy-json`), and the three that do not are in the baseline
# with the reason they cannot move today.
#
# RULE 2 - nothing new exposes a status to poll. Work that takes time returns a `future` and output
# that keeps coming is a `stream`; a `status`/`poll`/`await-*`/`wait-*` func that sits beside a func handing
# out an operation handle or id is the shape those two replace - unless its own doc comment marks it
# `legacy wrapper over <future-func>`, which is how a seam whose ABI a shipped component still imports
# says so in the file. The ones on main are in the baseline, so the rule binds new code without
# breaking the tree (scripts/wit-lint-baseline.txt).
#
# WHAT THIS DOES NOT COVER, said here because a verdict read for more than it says is worse than no
# verdict:
#   * a `list<u8>` field that carries JSON (hooks.wit's `row.json` is one). The rule is about
#     `string`, because that is where the confusion lives; a bytes field is a different call, and
#     REPORT.md lists it rather than this check judging it.
#   * a variant case's payload (`failed(string)`), which has no name of its own to carry `-json`.
#     wit/memory/deps/kernel/kernel.wit's `journal-entry.payload` is the measured case: the same field
#     this rule flags in wit/kernel/sql.wit, unseen here because that copy carries no doc comment. The
#     rule reads what a file says, never what a copy of it meant.
#   * a mention of a JSON *file* is not a mention of a JSON *value*: `kind: string` documented
#     "`native` (hooks.json) or `claude` (settings.json)" is not a JSON-carrying field, and filenames
#     are stripped before a doc is read (scripts/test-wit-lint.sh proves that case).
#   * a parameter's doc is its function's doc (WIT has no per-parameter doc), so the doc only counts
#     when it says so about that parameter BY NAME ("`config` is the non-secret configuration object
#     (JSON text)"). A function doc describing its RETURN value ("The JSON text of one granted key")
#     is not read as describing its `key` parameter - also proved there.
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
function mentionsJson(text) { return /\bjson\b/i.test(stripFilenames(text)); }
function splitTop(text) {
  const out = []; let depth = 0, cur = '';
  for (const ch of text) {
    if (ch === '<' || ch === '(') depth++;
    else if (ch === '>' || ch === ')') depth--;
    if (ch === ',' && depth === 0) { out.push(cur.trim()); cur = ''; continue; }
    cur += ch;
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
// A parameter has no doc of its own in WIT, so its function doc speaks for it only when it makes
// the parameter the SUBJECT of a clause that says JSON: "config is the non-secret configuration
// object (JSON text)". A function doc describing its RETURN value ("The JSON text of one granted
// key") does not make a parameter its subject, so it must not flag one - the case
// scripts/test-wit-lint.sh fails the check on if this ever widens.
function docNamesCarryingParam(doc, name) {
  const text = stripFilenames(doc).toLowerCase();
  const needle = String(name).toLowerCase();
  if (!text.includes('json')) return false;
  for (const clause of text.split('.')) {
    if (!clause.includes(needle) || !clause.includes('json')) continue;
    if (clause.includes(' is ') || clause.includes(' are ') || clause.includes(' carries ') || clause.includes(' holds ')) return true;
  }
  return false;
}
const STARTISH = /^(?:start|submit|spawn|begin|dispatch|enqueue|schedule)/;
// The two NAMES are exact and only the two prefixes are prefixes: a func called poll-op is not the
// pair this rule describes, so status and poll match whole names and await-/wait- match a suffix.
const POLLISH = /^(?:status|poll)$|^(?:await|wait)-/;

const strings = [];        // every string field/parameter: what crosses the seam, in one table
const funcs = [];          // every func: name, context, return type, doc
const resourceNames = new Set();

for (const file of files) {
  // The key is relative to the wit directory, never to the checkout: a baseline line must mean the
  // same thing in every tree (and in a fixture under /tmp), or it is a key nobody can keep.
  const rel = path.relative(DIR, file).split(path.sep).join('/');
  const lines = fs.readFileSync(file, 'utf8').split('\n');
  const stack = [];
  let doc = [];
  for (let i = 0; i < lines.length; i++) {
    const text = lines[i].replace(/[ \t]+$/, '');
    const trimmed = text.trim();
    if (trimmed.startsWith('///')) { doc.push(trimmed.replace(/^\/\/\/\s?/, '')); continue; }
    if (trimmed === '') { doc = []; continue; }
    if (trimmed.startsWith('//')) continue;
    const opened = trimmed.match(/^(interface|resource|record|variant|enum|flags|world)\s+([a-z0-9-]+)/);
    if (opened) {
      if (opened[1] === 'resource') resourceNames.add(opened[2]);
      stack.push(opened[1] + ':' + opened[2]);
      doc = [];
      continue;
    }
    if (/^type\s+[a-z0-9-]+\s*=/.test(trimmed)) { doc = []; continue; }
    if (trimmed === '}' || trimmed === '};') { if (stack.length) stack.pop(); doc = []; continue; }
    const context = stack.join('/');
    // static can sit on either side of the colon (start: static func(...)), so both are allowed.
    const fname = trimmed.match(/^(?:static\s+)?([a-z][a-z0-9-]*)\s*:\s*(?:static\s+)?(?:async\s+)?func\b/);
    if (fname) {
      let sig = trimmed, j = i;
      while (!sig.includes(';') && j + 1 < lines.length) sig += ' ' + lines[++j].trim();
      const open = sig.indexOf('('), close = sig.lastIndexOf(')');
      const params = open >= 0 && close > open ? splitTop(sig.slice(open + 1, close)) : [];
      const ret = sig.includes('->') ? sig.slice(sig.indexOf('->') + 2).replace(/;\s*$/, '').trim() : '';
      const fnDoc = doc.join(' ');
      for (const param of params) {
        const at = param.indexOf(':');
        if (at < 0) continue;
        const name = param.slice(0, at).trim(), type = param.slice(at + 1).trim();
        if (unwrap(type) !== 'string') continue;
        // The doc speaks about a parameter only when it names it in a carrying phrase.
        strings.push({
          file: rel, line: i + 1, context, where: 'parameter of ' + fname[1], name, type, doc: fnDoc,
          carries: mentionsJson(name) || docNamesCarryingParam(fnDoc, name),
        });
      }
      funcs.push({ file: rel, line: i + 1, context, name: fname[1], ret, doc: fnDoc });
      doc = [];
      continue;
    }
    const field = trimmed.match(/^([a-z][a-z0-9-]*)\s*:\s*([^=]+?),?$/);
    if (field && !/^(use|include|export|import|type)\b/.test(trimmed)) {
      const name = field[1], type = field[2].replace(/,\s*$/, '').trim();
      if (unwrap(type) === 'string') {
        const fieldDoc = doc.join(' ');
        strings.push({ file: rel, line: i + 1, context, where: 'field', name, type, doc: fieldDoc, carries: mentionsJson(name) || mentionsJson(fieldDoc) });
      }
    }
    doc = [];
  }
}

// ---- rule 1: a string that carries JSON is named *-json -----------------------------------------
const jsonNamed = strings.filter((s) => /-json$/.test(s.name));
const violations = [];
for (const s of strings) {
  if (!s.carries || /-json$/.test(s.name)) continue;
  violations.push({
    rule: 'json-name', file: s.file, line: s.line, context: s.context, name: s.name,
    why: (mentionsJson(s.name) ? 'the name says JSON' : 'the doc comment says it is JSON') +
      ', and `' + s.name + ': ' + s.type + '` does not carry -json in the name',
  });
}

// ---- rule 2: a polling func beside an operation handle ------------------------------------------
// The handle a caller would poll by: a return type that is an id or names an operation, or a resource
// a start-ish func hands out (the start/poll pair). Everything else - an HTTP status code, a
// keystore's root-status - is a read, not a poll, and is not flagged.
function handleOf(fn) {
  const ret = unwrap(fn.ret);
  if (/(?:^|-)id$/.test(ret) || /operation/.test(ret)) return ret;
  if (STARTISH.test(fn.name) && resourceNames.has(ret)) return 'resource:' + ret;
  return '';
}
const byContext = new Map();
for (const fn of funcs) {
  if (!byContext.has(fn.context)) byContext.set(fn.context, []);
  byContext.get(fn.context).push(fn);
}
for (const [context, siblings] of byContext) {
  for (const fn of siblings) {
    if (!POLLISH.test(fn.name)) continue;
    let handle = '', beside = '';
    for (const other of siblings) {
      if (other === fn) continue;
      const h = handleOf(other);
      if (h) { handle = h; beside = other.name; break; }
    }
    if (!handle) continue;
    if (/legacy wrapper over\s+[a-z0-9-]+/i.test(fn.doc)) continue;
    violations.push({
      rule: 'poll-without-future', file: fn.file, line: fn.line, context, name: fn.name,
      why: '`' + fn.name + '` sits beside `' + beside + '` handing out `' + handle +
        '`: return a `future`/`stream` instead, or mark the doc "legacy wrapper over <future-func>"',
    });
  }
}

// ---- the baseline -------------------------------------------------------------------------------
// <rule> <file> <context> <name>   # the ones on main, each with the reason it stays. A baseline line
// that no longer matches anything FAILS: a hole that was closed must leave the file, or the file
// stops being a list of what is still true (the rule scripts/test-orphan-tests.mjs already keeps).
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
    console.log(['string-carries-json', s.file, s.context, s.where + ' ' + s.name, s.type, state('json-name', s.file, s.context, s.name)].join('\t'));
  }
  for (const fn of funcs) if (POLLISH.test(fn.name)) console.log(['polling-func', fn.file, fn.context, fn.name, fn.ret || '-', /legacy wrapper over/i.test(fn.doc) ? 'legacy-wrapped' : state('poll-without-future', fn.file, fn.context, fn.name)].join('\t'));
  process.exit(0);
}

for (const v of fresh) console.log('FAIL wit-lint: ' + v.file + ':' + v.line + ' [' + v.context + '] ' + v.name + ': ' + v.why);
for (const k of stale) console.log('FAIL wit-lint: ' + BASELINE + ' still lists "' + k.split('|').slice(1).join(' ') + '", which this check does not flag any more: remove the line');
if (fresh.length || stale.length) {
  console.log('wit-lint: ' + fresh.length + ' new violation(s), ' + stale.length + ' stale baseline line(s), ' + known.size + ' baselined');
  process.exit(1);
}
console.log('wit-lint ok (' + files.length + ' wit files, ' + strings.length + ' string field(s)/parameter(s), ' +
  jsonNamed.length + ' named *-json, ' + funcs.filter((f) => POLLISH.test(f.name)).length + ' polling func(s): ' +
  known.size + ' baselined, 0 new)');
NODE

