#!/usr/bin/env node
// The three-way merge behind `scripts/lib/install-default-policy.sh`: bring the rules a release SHIPS into
// the `policy.json` a node already has, without overwriting the rules its operator wrote.
//
// The failure this exists for (openclaw, 07/11). `policy.json` had been installed from an older shipped
// default. A later release added `ix/*` to `wa-whatsapp`'s `kv.write` allow list. The deploy kept the node
// file - correct, it never overwrites an operator's edits - and so the new rule never arrived: every index
// write was refused (`no_policy`/`target_not_allowed`) until it was added by hand. "Keep the operator's
// file" and "ship the new rule" are not in conflict; keeping the whole FILE when only one RULE was the
// operator's is what was wrong.
//
// So the unit of the merge is the RULE, not the file:
//
//   base    the shipped default this node's file was installed from (a copy the install recorded, or the
//           oldest default in `policies/default.json`'s history whose bytes are the node's own);
//   ours    the node's file;
//   theirs  the default this release ships.
//
// Per unit: ours == base -> take theirs (the node never touched it); theirs == base -> keep ours (the node
// edited it, the release did not); ours == theirs -> nothing to do; otherwise a REAL conflict - both sides
// changed the same rule - and the node's version wins, loudly (the deploy continues; `installed.txt`
// records the warning). A rule the release deletes goes when the node never touched it.
//
// A unit is:
//
//   top:<key>             a top-level member other than `components` (`version`, `sensitive_capabilities`);
//   component:<name>      a component entry without its `capabilities` (the `note`, and anything else);
//   rule:<name>/<cap>     one capability rule (`wa-whatsapp/kv.write`).
//
// Comparison is by VALUE (canonical JSON), never by bytes: a file this tool wrote once is pretty-printed
// by this tool, so a byte comparison would call every rule of it "edited" on the next deploy.
//
// No base (`--additions-only`): the node's file matches no default this tree ever shipped, so nothing can
// say which of its rules the operator wrote. New rules and new components are added; an EXISTING rule is
// never modified - adding entries to an `allow` list the operator narrowed would widen the very limit the
// policy exists to enforce - and the entries the release has and the node lacks are printed as a hint.
//
// Usage:
//   node policy-merge.mjs --ours F --theirs F [--base F] [--additions-only]
//                         [--out F] [--summary F]
//   node policy-merge.mjs --verify F          # the file parses as a policy document
//
// Exit: 0 merged or nothing to do, 1 usage/IO error, 3 `--ours` does not parse (kept, warned),
//       4 `--theirs` does not parse (this release cannot install its own default).
//
// It prints no message text and no secret: only rule ids (`component/capability`), counts and the allow
// entries a rule is missing. Nothing here reads the node's state, the network or the environment.
import { readFileSync, writeFileSync } from 'node:fs';

const ABSENT = Symbol('absent');

const isObject = (value) => value !== null && typeof value === 'object' && !Array.isArray(value);

// One stable string per JSON value, so two documents can be compared by what they MEAN. Key order is not
// part of a policy (serde does not care), and a reformatted file is not an edit.
function canonical(value) {
  if (Array.isArray(value)) return '[' + value.map(canonical).join(',') + ']';
  if (isObject(value)) {
    return '{' + Object.keys(value).sort().map((key) => JSON.stringify(key) + ':' + canonical(value[key])).join(',') + '}';
  }
  return JSON.stringify(value === undefined ? null : value);
}

const same = (a, b) => (a === ABSENT || b === ABSENT ? a === b : canonical(a) === canonical(b));

// The document as a map of units. Throws when the shape is not a policy at all: merging a file that is not
// a policy would produce a policy nobody wrote.
function unitsOf(doc, label) {
  const units = new Map();
  if (!isObject(doc)) throw new Error(`${label} is not a JSON object`);
  for (const key of Object.keys(doc)) {
    if (key === 'components') continue;
    units.set('top:' + key, doc[key]);
  }
  const components = doc.components;
  if (components === undefined) return units;
  if (!isObject(components)) throw new Error(`${label}: components is not an object`);
  for (const name of Object.keys(components)) {
    const entry = components[name];
    if (!isObject(entry)) {
      units.set('component:' + name, entry);
      continue;
    }
    const rest = {};
    let hasRest = false;
    for (const key of Object.keys(entry)) {
      if (key === 'capabilities') continue;
      rest[key] = entry[key];
      hasRest = true;
    }
    if (hasRest) units.set('component:' + name, rest);
    const capabilities = entry.capabilities;
    if (capabilities === undefined) continue;
    if (!isObject(capabilities)) throw new Error(`${label}: components.${name}.capabilities is not an object`);
    for (const capability of Object.keys(capabilities)) units.set('rule:' + name + '/' + capability, capabilities[capability]);
  }
  return units;
}

function componentsOf(out) {
  if (!isObject(out.components)) out.components = {};
  return out.components;
}

// Put one unit's value back into the document being built. Existing keys keep their position (JS objects
// keep insertion order), so the merged file reads like the node's own file with the new rules in it.
function setUnit(out, id, value) {
  const split = id.indexOf(':');
  const kind = id.slice(0, split);
  const tail = id.slice(split + 1);
  if (kind === 'top') {
    out[tail] = value;
    return;
  }
  if (kind === 'component') {
    const components = componentsOf(out);
    if (!isObject(value)) {
      components[tail] = value;
      return;
    }
    const entry = isObject(components[tail]) ? components[tail] : (components[tail] = {});
    for (const key of Object.keys(entry)) if (key !== 'capabilities' && !(key in value)) delete entry[key];
    for (const key of Object.keys(value)) if (key !== 'capabilities') entry[key] = value[key];
    return;
  }
  if (kind === 'rule') {
    const slash = tail.indexOf('/');
    const name = tail.slice(0, slash);
    const capability = tail.slice(slash + 1);
    const components = componentsOf(out);
    if (!isObject(components[name])) components[name] = {};
    if (!isObject(components[name].capabilities)) components[name].capabilities = {};
    components[name].capabilities[capability] = value;
    return;
  }
  throw new Error('unknown unit ' + id);
}

function deleteUnit(out, id, emptied) {
  const split = id.indexOf(':');
  const kind = id.slice(0, split);
  const tail = id.slice(split + 1);
  if (kind === 'top') {
    delete out[tail];
    return;
  }
  if (!isObject(out.components)) return;
  if (kind === 'component') {
    const entry = out.components[tail];
    if (!isObject(entry)) return;
    for (const key of Object.keys(entry)) if (key !== 'capabilities') delete entry[key];
    emptied.add(tail);
    return;
  }
  if (kind === 'rule') {
    const slash = tail.indexOf('/');
    const name = tail.slice(0, slash);
    const capability = tail.slice(slash + 1);
    const entry = out.components[name];
    if (!isObject(entry) || !isObject(entry.capabilities)) return;
    delete entry.capabilities[capability];
    emptied.add(name);
  }
}

// A component the release dropped must not be left behind as `"name": {}`: an empty entry still counts as
// "named" to a reader, and the deploy's `policy_unlisted_components` listing would stop mentioning it.
function pruneEmptied(out, emptied) {
  for (const name of emptied) {
    const entry = out.components?.[name];
    if (isObject(entry) && Object.keys(entry).length === 0) delete out.components[name];
  }
}

const clone = (value) => JSON.parse(JSON.stringify(value));

// The allow entries `theirs` has for one rule and `ours` does not. Used for the hint an additions-only
// merge prints, so the operator is told the one-line edit instead of discovering it as a refused write.
function missingEntries(ours, theirs) {
  if (!isObject(ours) || !isObject(theirs)) return [];
  const mine = Array.isArray(ours.allow) ? ours.allow.map(String) : [];
  const shipped = Array.isArray(theirs.allow) ? theirs.allow.map(String) : [];
  return shipped.filter((entry) => !mine.includes(entry));
}

function mergeThreeWay(base, ours, theirs) {
  // Ours' order first (the node's own reading order), then the release's new units, then anything only the
  // base had - which can only be a unit this merge deletes, and deleting needs no position.
  const ids = [
    ...ours.units.keys(),
    ...[...theirs.units.keys()].filter((id) => !ours.units.has(id)),
    ...[...base.units.keys()].filter((id) => !ours.units.has(id) && !theirs.units.has(id)),
  ];
  const out = clone(ours.document);
  const emptied = new Set();
  const applied = [];
  const conflicts = [];
  let nodeEdits = 0;
  for (const id of ids) {
    const b = base.units.has(id) ? base.units.get(id) : ABSENT;
    const o = ours.units.has(id) ? ours.units.get(id) : ABSENT;
    const t = theirs.units.has(id) ? theirs.units.get(id) : ABSENT;
    if (!same(o, b)) nodeEdits += 1;
    let result;
    if (same(o, b)) {
      result = t;
      if (!same(t, b)) applied.push({ id, how: b === ABSENT ? 'added' : t === ABSENT ? 'removed' : 'changed' });
    } else if (same(o, t) || same(t, b)) {
      result = o;
    } else {
      result = o;
      conflicts.push(id);
    }
    if (result === ABSENT) deleteUnit(out, id, emptied);
    else if (!same(result, o)) setUnit(out, id, result);
  }
  pruneEmptied(out, emptied);
  return { document: out, applied, conflicts, nodeEdits };
}

function mergeAdditions(ours, theirs) {
  const out = clone(ours.document);
  const applied = [];
  const hints = [];
  for (const [id, t] of theirs.units) {
    const o = ours.units.has(id) ? ours.units.get(id) : ABSENT;
    if (o === ABSENT) {
      setUnit(out, id, t);
      applied.push({ id, how: 'added' });
      continue;
    }
    if (same(o, t) || !id.startsWith('rule:')) continue;
    const missing = missingEntries(o, t);
    if (missing.length) hints.push({ id, missing });
  }
  return { document: out, applied, conflicts: [], hints };
}

function readJson(path, role) {
  let text;
  try {
    text = readFileSync(path, 'utf8');
  } catch (error) {
    throw Object.assign(new Error(`cannot read ${role} ${path}: ${error.code || error.message}`), { exit: 1 });
  }
  try {
    return JSON.parse(text);
  } catch {
    // The message text of a broken file is not printed: a policy file can carry an operator's notes, and
    // this is a log line.
    throw Object.assign(new Error(`${role} ${path} is not valid JSON`), { exit: role === 'ours' ? 3 : 4 });
  }
}

function parseArgs(argv) {
  const args = { additionsOnly: false };
  for (let i = 0; i < argv.length; i += 1) {
    const flag = argv[i];
    const take = () => {
      const value = argv[i + 1];
      if (value === undefined || value.startsWith('--')) throw new Error(`${flag} needs a value`);
      i += 1;
      return value;
    };
    switch (flag) {
      case '--ours': args.ours = take(); break;
      case '--theirs': args.theirs = take(); break;
      case '--base': args.base = take(); break;
      case '--out': args.out = take(); break;
      case '--summary': args.summary = take(); break;
      case '--base-label': args.baseLabel = take(); break;
      case '--verify': args.verify = take(); break;
      case '--additions-only': args.additionsOnly = true; break;
      default: throw new Error(`unknown argument ${flag}`);
    }
  }
  return args;
}

function summaryLines(result, args) {
  const lines = [
    `mode=${args.base && !args.additionsOnly ? 'three-way' : 'additions-only'}`,
    `base=${args.baseLabel || 'none'}`,
    `changed=${result.changed ? 1 : 0}`,
    `node_edits=${result.nodeEdits ?? 0}`,
  ];
  if (result.applied.length) lines.push('applied=' + result.applied.map((entry) => `${entry.id} (${entry.how})`).join(', '));
  for (const id of result.conflicts) lines.push('conflict=' + id);
  for (const hint of result.hints || []) lines.push('hint=' + hint.id + ' the release also allows ' + hint.missing.join(' '));
  return lines;
}

function report(result, args) {
  const out = [];
  for (const entry of result.applied) out.push(`applied ${entry.id} (${entry.how})`);
  for (const id of result.conflicts) out.push(`conflict ${id} (both sides changed it; the node's version is kept)`);
  for (const hint of result.hints || []) {
    out.push(`hint ${hint.id}: the release also allows ${hint.missing.join(' ')}; the node's rule is kept as written`);
  }
  if (!result.applied.length && !result.conflicts.length) out.push('nothing to apply (the node file already carries every rule this release ships)');
  return out;
}

function main(argv) {
  let args;
  try {
    args = parseArgs(argv);
  } catch (error) {
    process.stderr.write(`policy-merge: ${error.message}\n`);
    return 1;
  }
  if (args.verify) {
    try {
      readJson(args.verify, 'ours');
      return 0;
    } catch (error) {
      process.stderr.write(`policy-merge: ${error.message}\n`);
      return 1;
    }
  }
  if (!args.ours || !args.theirs) {
    process.stderr.write('policy-merge: --ours and --theirs are required\n');
    return 1;
  }
  try {
    const oursDoc = readJson(args.ours, 'ours');
    const theirsDoc = readJson(args.theirs, 'theirs');
    const ours = { document: oursDoc, units: unitsOf(oursDoc, 'ours') };
    const theirs = { document: theirsDoc, units: unitsOf(theirsDoc, 'theirs') };
    const baseDoc = args.base && !args.additionsOnly ? readJson(args.base, 'base') : null;
    const merged = baseDoc === null
      ? mergeAdditions(ours, theirs)
      : mergeThreeWay({ document: baseDoc, units: unitsOf(baseDoc, 'base') }, ours, theirs);
    const changed = canonical(merged.document) !== canonical(oursDoc);
    const result = { ...merged, changed };
    if (args.summary) writeFileSync(args.summary, summaryLines(result, args).join('\n') + '\n');
    if (changed && args.out) writeFileSync(args.out, JSON.stringify(merged.document, null, 2) + '\n');
    for (const line of report(result, args)) process.stdout.write(line + '\n');
    return 0;
  } catch (error) {
    process.stderr.write(`policy-merge: ${error.message}\n`);
    return error.exit || 1;
  }
}

process.exitCode = main(process.argv.slice(2));
