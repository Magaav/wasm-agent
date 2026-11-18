#!/usr/bin/env node
// The module map: what this tree is made of, what each part costs and which ones say why they exist.
//
// WHY. ARCHITECTURE.md ("Modules over the monolith") keeps a seam for a MEASURED win and states the
// thresholds both ways: split when a change's rebuild drops by 30% or the part swaps without a restart;
// merge when two modules move together in >70% of the last 50 commits and neither records a win. Those
// are claims about numbers, so this file prints the numbers: per module its size, what it cost to
// build in this run, and the `win` line from its manifest.
//
// FLAGS, NOT FAILURES. Nothing here fails a landing. A module without a win line, a pair that always
// moves together, a split recorded 3 days ago: each is printed and the exit code stays 0. A report that
// could block would be argued with instead of read (scripts/lib/build-times.sh says the same about
// build times), and then nobody would look at it.
//
// WHAT IS A MODULE (the definition the counts use, so they can be checked):
//   * a Rust crate     - every Cargo.toml under rust/ except the workspace root (a nested one counts
//                        AS ITSELF: rust/wa-fake-kernel/fixture is a package of its own, it is the
//                        module its files belong to, and its lines are not also the parent's);
//   * a WASM component - every directory under rust/components/ (it is also a crate; it is counted
//                        ONCE, here, because a component is what a deploy pins and swaps);
//   * a feature        - every directory under modules/ that carries a module.json (docs/MODULES.md).
//
// THE MANIFEST. A module's manifest is, by kind: modules/<id>/module.json (feature),
// rust/components/<name>/manifest.json (component), <crate>/module.json (crate - a convention this
// report introduces; none exists in the tree today and every crate is flagged until one does). The two
// keys this report reads, both optional:
//   "win": "balanced-shard: 41s -> 6s to rebuild ..."      the measured win, in one line
//   "decision": {"kind": "split", "date": "2026-11-18",    the last split or merge, with its
//                "commit": "<sha>", "measurement": "..."}  measurement - this is what the 30-day /
//                                                          100-commit cooldown reads
//
// WHAT IT DOES NOT COVER, because a map read for more than it says is worse than no map:
//   * "build time" is the wall clock of a build THIS run performed for that module
//     (--timings, the ledger scripts/lib/build-times.sh fills). A module nothing rebuilt prints "-":
//     an unmeasured module is not a fast one.
//   * co-change is path-based, and a pair's share is the commits that touched EITHER of the two: two
//     modules that always move together read 100%, not n/50. A pair needs two shared commits to be a
//     merge flag at all (one shared commit is 1/1 = 100% and no pattern - measured on this tree's own
//     wa-mesh + wa-rendezvous), and a commit that touches a nested crate counts for that crate (the
//     deepest module holding the file), not for its parent.
//   * a merge is argued only where NEITHER module records a win - a module that states what it is
//     worth is not one a report hands to a merge, however it moves.
//   * the size is source lines (rs, lua, js/mjs/cjs/ts, html, css, wit) - not what the code does.
//
//   node scripts/module-report.mjs [--timings <tsv>] [--root <dir>] [--rows N] [--no-git]
//
// `--rows` defaults to 0, which prints every module; `--timings` defaults to the baseline ledger
// (docs/measurements/module-build-times.tsv) and scripts/fast.sh passes this run's own.
//
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

function flag(name, fallback) {
  const i = process.argv.indexOf('--' + name);
  return i >= 0 && process.argv[i + 1] !== undefined ? process.argv[i + 1] : fallback;
}
const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(flag('root', path.resolve(HERE, '..')));
// The build-time ledger scripts/lib/build-times.sh fills during a fast run. A run outside the fast path
// falls back to the ledger recorded with the baseline (docs/measurements/module-build-times.tsv), so the
// build column still says what each module cost to compile instead of a column of '-'.
const TIMINGS_ARG = flag('timings', '');
const TIMINGS = TIMINGS_ARG || path.resolve(ROOT, 'docs', 'measurements', 'module-build-times.tsv');
const TIMINGS_SOURCE = TIMINGS_ARG
  ? 'this run\u2019s ledger'
  : 'the recorded baseline (' + path.relative(ROOT, TIMINGS) + ')';
// 0 = every module, which is the report's contract: per module, its size, its build time and its win
// line. A narrowed view is the reader's choice (`--rows N`), never the default - a map that hides rows is
// quoted later as if the hidden ones did not exist.
const ROWS = Number(flag('rows', '0'));
const USE_GIT = !process.argv.includes('--no-git');
const SOURCE = /\.(rs|lua|mjs|cjs|js|ts|html|css|wit)$/;
const CO_CHANGE_WINDOW = 50;
const CO_CHANGE_THRESHOLD = 0.70;
// Measured on this tree when the denominator moved to "the commits that touch either module": the
// only pair over the line was wa-mesh + wa-rendezvous, in ONE commit of fifty - 1/1 under the new
// denominator, 100%, and no pattern at all. A pair that moved together once is one commit, so a merge
// needs at least two shared commits; the share of every pair is still reported, and the flagged ones
// print the raw count next to it.
const CO_CHANGE_MIN_COMMITS = 2;
const COOLDOWN_DAYS = 30;
const COOLDOWN_COMMITS = 100;

function subdirs(dir) {
  try {
    return fs.readdirSync(dir, { withFileTypes: true })
      .filter((e) => e.isDirectory() && !e.name.startsWith('.'))
      .map((e) => e.name).sort();
  } catch { return []; }
}
function walkCargoToml(dir, out) {
  let entries;
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return out; }
  for (const entry of entries.sort((a, b) => (a.name < b.name ? -1 : 1))) {
    if (entry.name === 'target' || entry.name === 'node_modules' || entry.name.startsWith('.')) continue;
    const p = path.join(dir, entry.name);
    if (entry.isDirectory()) walkCargoToml(p, out);
    else if (entry.name === 'Cargo.toml') out.push(p);
  }
  return out;
}
// A nested module is counted ONCE, as itself. Without this, rust/wa-fake-kernel's size included
// rust/wa-fake-kernel/fixture and rust/wa-fake-kernel/fixture's size counted the same lines again -
// two rows quoting one set of files.
function measureSize(dir) {
  let lines = 0, bytes = 0;
  const stack = [dir];
  while (stack.length) {
    const cur = stack.pop();
    let entries;
    try { entries = fs.readdirSync(cur, { withFileTypes: true }); } catch { continue; }
    for (const entry of entries) {
      if (entry.name.startsWith('.') || entry.name === 'target' || entry.name === 'node_modules') continue;
      const p = path.join(cur, entry.name);
      if (entry.isDirectory()) {
        if (p !== dir && moduleDirs.has(p)) continue;   // its own row counts it
        stack.push(p); continue;
      }
      if (!SOURCE.test(entry.name)) continue;
      let text;
      try { text = fs.readFileSync(p, 'utf8'); } catch { continue; }
      bytes += Buffer.byteLength(text);
      let n = 0;
      for (let i = 0; i < text.length; i++) if (text.charCodeAt(i) === 10) n++;
      lines += n + (text.length && !text.endsWith('\n') ? 1 : 0);
    }
  }
  return { lines, bytes };
}
function readManifest(file) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return null; }
}

// ---- the modules ---------------------------------------------------------------------------------
const modules = [];
for (const id of subdirs(path.join(ROOT, 'modules'))) {
  const dir = path.join(ROOT, 'modules', id);
  const manifest = path.join(dir, 'module.json');
  if (!fs.existsSync(manifest)) continue;   // a directory without a manifest is not a module
  modules.push({ kind: 'feature', name: id, dir, manifest });
}
for (const name of subdirs(path.join(ROOT, 'rust', 'components'))) {
  const dir = path.join(ROOT, 'rust', 'components', name);
  modules.push({ kind: 'component', name, dir, manifest: path.join(dir, 'manifest.json') });
}
for (const toml of walkCargoToml(path.join(ROOT, 'rust'), [])) {
  const dir = path.dirname(toml);
  const rel = path.relative(path.join(ROOT, 'rust'), dir).split(path.sep).join('/');
  if (rel === '') continue;                         // the workspace root is not a module
  if (rel.split('/')[0] === 'components') continue; // counted above, once, as a component
  modules.push({ kind: 'crate', name: rel, dir, manifest: path.join(dir, 'module.json') });
}

// Every module's directory, before anything walks the tree: a file is attributed to the DEEPEST
// module that holds it, and a nested module's lines are not also its parent's.
const moduleDirs = new Set();
const moduleDirKey = new Map();
for (const mod of modules) {
  moduleDirKey.set(path.relative(ROOT, mod.dir).split(path.sep).join('/'), mod.kind + ':' + mod.name);
  moduleDirs.add(path.resolve(mod.dir));
}
const moduleDirsByDepth = [...moduleDirKey.keys()].sort((a, b) => b.length - a.length);

// ---- what each one states and what it cost -------------------------------------------------------
const timings = new Map();
if (TIMINGS && fs.existsSync(TIMINGS)) {
  for (const raw of fs.readFileSync(TIMINGS, 'utf8').split('\n')) {
    const line = raw.trim();
    if (!line || line.startsWith('#')) continue;
    const [kind, name, ms, note] = line.split('\t');
    if (!name) continue;
    timings.set(kind + ':' + name, { ms: Number(ms) || 0, note: note || '' });
  }
}
for (const mod of modules) {
  const manifest = mod.manifest && fs.existsSync(mod.manifest) ? readManifest(mod.manifest) : null;
  mod.manifestPath = manifest ? path.relative(ROOT, mod.manifest).split(path.sep).join('/') : '';
  mod.win = manifest && typeof manifest.win === 'string' ? manifest.win.trim() : '';
  mod.decision = manifest && manifest.decision && typeof manifest.decision === 'object' ? manifest.decision : null;
  const size = measureSize(mod.dir);
  mod.lines = size.lines;
  mod.bytes = size.bytes;
  const timing = timings.get(mod.kind + ':' + mod.name) ||
    timings.get(mod.kind + ':' + mod.name.split('/').pop());
  mod.ms = timing ? timing.ms : null;
}

// ---- co-change: which modules move together ------------------------------------------------------
function git(args_) {
  return execFileSync('git', ['-C', ROOT, ...args_], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] });
}
// The module a file belongs to is the DEEPEST module directory it sits under, not the first path
// component: rust/wa-fake-kernel/fixture/src/lib.rs belongs to the nested crate and not to its parent
// (which is how nested crates used to be counted under the parent and never on their own).
function moduleOfPath(rel) {
  for (const dir of moduleDirsByDepth) {
    if (rel === dir || rel.startsWith(dir + '/')) return moduleDirKey.get(dir);
  }
  return '';
}
let commits = [];
let gitNote = 'not read (--no-git)';
if (USE_GIT) {
  try {
    const MARK = String.fromCharCode(1);
    const out = git(['log', '-' + CO_CHANGE_WINDOW, '--name-only', '--pretty=format:' + MARK]);
    commits = out.split(MARK)
      .map((block) => block.split('\n').map((s) => s.trim()).filter(Boolean))
      .filter((files) => files.length > 0);
    gitNote = commits.length + ' commit(s) read';
  } catch (e) {
    gitNote = 'no git history here (' + String(e.message || e).split('\n')[0] + ')';
  }
}
// A pair's share is measured against the commits that COULD have moved it - the ones touching either
// module - never against all 50. Dividing by the window made a pair that moved in every relevant
// commit read as 1/50, which is the number that buried the rule's own question. And a merge is only
// argued where neither module records a win: a module that states what it is worth is not one the
// report should hand to a merge.
const pairs = new Map();
const touched = new Map();
for (const files of commits) {
  const mods = [...new Set(files.map(moduleOfPath).filter(Boolean))].sort();
  for (const mod of mods) touched.set(mod, (touched.get(mod) || 0) + 1);
  for (let i = 0; i < mods.length; i++) {
    for (let j = i + 1; j < mods.length; j++) {
      const key = mods[i] + ' + ' + mods[j];
      pairs.set(key, (pairs.get(key) || 0) + 1);
    }
  }
}
// Commits touching both count once: |A ∪ B| = |A| + |B| - |A ∩ B|.
const ofEither = (pair, n) => pair.split(' + ').reduce((sum, m) => sum + (touched.get(m) || 0), 0) - n;
const winOf = new Map(modules.map((m) => [m.kind + ':' + m.name, m.win]));
const recordsWin = (pair) => pair.split(' + ').some((m) => (winOf.get(m) || '').length > 0);
const ranked = [...pairs.entries()]
  .map(([pair, n]) => {
    const of = ofEither(pair, n);
    return { pair, n, of, share: of > 0 ? n / of : 0, win: recordsWin(pair) };
  })
  .sort((a, b) => b.share - a.share || b.n - a.n);
const overLine = ranked.filter((r) => commits.length && r.n >= CO_CHANGE_MIN_COMMITS && r.share > CO_CHANGE_THRESHOLD);
const mergeCandidates = overLine.filter((r) => !r.win);
const heldBack = overLine.filter((r) => r.win);
const hottest = ranked.slice(0, 3);

// ---- the decision record: the cooldown, made visible ---------------------------------------------
function daysSince(date) {
  const then = Date.parse(date + 'T00:00:00Z');
  if (Number.isNaN(then)) return null;
  return Math.floor((Date.now() - then) / 86400000);
}
function commitsSince(commit) {
  if (!USE_GIT || !commit) return null;
  try { return Number(git(['rev-list', '--count', commit + '..HEAD']).trim()); } catch { return null; }
}
const decisions = [];
for (const mod of modules) {
  if (!mod.decision) continue;
  const days = mod.decision.date ? daysSince(mod.decision.date) : null;
  const since = commitsSince(mod.decision.commit);
  // Both ends of the cooldown have to be short for a reversal to be too soon - but an UNKNOWN commit
  // count is not a satisfied one: without git (or without a commit in the record) the count is
  // unverified, and a report that reads that as "clear" is the fail-open this flag exists to stop.
  // A record with NO DATE is unverified the same way, and was the other half of that fail-open: the age
  // came out null and 'days < COOLDOWN_DAYS' was false, so a decision nobody could date read as one
  // that had cleared the 30 days. It is neither inside nor outside: it is FLAGGED, by name, here.
  const unverified = days === null;
  const tooSoon = !unverified && days < COOLDOWN_DAYS && (since === null || since < COOLDOWN_COMMITS);
  decisions.push({ mod: mod.kind + ':' + mod.name, days, since, unverified, tooSoon, decision: mod.decision });
}

// ---- the report ----------------------------------------------------------------------------------
const count = (kind) => modules.filter((m) => m.kind === kind).length;
const withWin = modules.filter((m) => m.win).length;
const noWin = modules.filter((m) => !m.win);
const out = [];
const p = (s) => out.push(s);
p('module-report: ' + modules.length + ' modules = ' + count('crate') + ' crate(s), ' +
  count('component') + ' component(s), ' + count('feature') + ' feature(s)');
p('module-report: win       ' + withWin + '/' + modules.length + ' state a measured win; ' +
  (noWin.length ? noWin.length + ' flagged (no manifest or no `win` line)' : 'none flagged'));
const built = modules.filter((m) => m.ms !== null);
// The ledger is this run's own when scripts/fast.sh passed one, and the recorded baseline otherwise; the
// line says which, because "a build time" from nowhere is a remembered figure, not a measurement.
p('module-report: build     ' + built.length + '/' + modules.length + ' with a build time from ' +
  TIMINGS_SOURCE + (built.length ? '' : ' (- means not compiled here, not fast)'));
p('module-report:   ' + 'module'.padEnd(34) + 'lines'.padStart(9) + '  build   win');
const sorted = [...modules].sort((a, b) => b.lines - a.lines);
const shown = ROWS > 0 ? sorted.slice(0, ROWS) : sorted;
for (const mod of shown) {
  const build = mod.ms === null ? '-' : (mod.ms / 1000).toFixed(1) + 's';
  p('module-report:   ' + (mod.kind + ':' + mod.name).padEnd(34) +
    String(mod.lines).padStart(9) + '  ' + build.padStart(6) + '  ' +
    (mod.win ? 'win: ' + mod.win : 'FLAG no win'));
}
if (sorted.length > shown.length) {
  p('module-report:   ... ' + (sorted.length - shown.length) + ' more by size (--rows 0 for all)');
}
if (noWin.length) {
  const names = noWin.slice(0, 6).map((m) => m.kind + ':' + m.name).join(', ');
  p('module-report:   FLAG no-win: ' + names + (noWin.length > 6 ? ', (+' + (noWin.length - 6) + ' more)' : ''));
}
p('module-report: co-change ' + mergeCandidates.length + ' pair(s) over ' +
  Math.round(CO_CHANGE_THRESHOLD * 100) + '% of the commits touching either module, in at least ' +
  CO_CHANGE_MIN_COMMITS + ' of them, neither recording a win (' + gitNote + ')');
for (const r of mergeCandidates) {
  p('module-report:   FLAG merge-candidate: ' + r.pair + ' (' + r.n + '/' + r.of +
    ' commits that touch either, ' + Math.round(r.share * 100) + '%)');
}
if (heldBack.length) {
  p('module-report:   ' + heldBack.length + ' pair(s) over the line record a win, so no merge is argued: ' +
    heldBack.slice(0, 3).map((r) => r.pair).join('; ') + (heldBack.length > 3 ? ' (+' + (heldBack.length - 3) + ' more)' : ''));
}
if (!mergeCandidates.length && hottest.length) {
  p('module-report:   hottest: ' + hottest.map((r) => r.pair + ' ' + r.n + '/' + r.of).join('; '));
}
const unverifiedCount = decisions.filter((d) => d.unverified).length;
p('module-report: decision  ' + decisions.length + ' recorded; cooldown ' + COOLDOWN_DAYS + ' day(s) or ' +
  COOLDOWN_COMMITS + ' commit(s) (a reversal needs a new measurement before then)' +
  (unverifiedCount ? '; ' + unverifiedCount + ' with no date, flagged unverified' : ''));
for (const d of decisions) {
  // The age is printed only when it is known: a record with no date (or one whose commit count cannot
  // be read) has nothing to say in brackets, and printing an empty pair of them read as "0 days ago".
  const aged = [];
  if (d.days !== null) aged.push(d.days + ' day(s) ago');
  if (d.since !== null) aged.push(d.since + ' commit(s) ago');
  p('module-report:   ' + d.mod + ': ' + (d.decision.kind || '?') + ' on ' + (d.decision.date || '?') +
    (aged.length ? ' (' + aged.join(', ') + ')' : '') +
    (d.decision.measurement ? ' - ' + d.decision.measurement : '') +
    (d.unverified ? '   [FLAG unverified: no date in the record, so its cooldown cannot be read]' : '') +
    (d.tooSoon ? '   [FLAG too soon to reverse]' : ''));
}
console.log(out.join('\n'));
// Flags, not failures: the exit code says the report ran, never that the tree is wrong.
process.exit(0);
