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
//   * a Rust crate     - every Cargo.toml under rust/ except the workspace root (a nested one counts:
//                        rust/wa-fake-kernel/fixture is a package of its own);
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
//   * co-change is path-based: two modules whose files a commit touches. A commit that touches a crate
//     and its test fixture under another path still counts as one module each.
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
      if (entry.isDirectory()) { stack.push(p); continue; }
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
function moduleOfPath(rel) {
  const parts = rel.split('/');
  if (parts[0] === 'modules' && parts.length > 1) return 'feature:' + parts[1];
  if (parts[0] === 'rust' && parts.length > 2) {
    if (parts[1] === 'components') return 'component:' + parts[2];
    return 'crate:' + parts[1];
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
const pairs = new Map();
for (const files of commits) {
  const mods = [...new Set(files.map(moduleOfPath).filter(Boolean))].sort();
  for (let i = 0; i < mods.length; i++) {
    for (let j = i + 1; j < mods.length; j++) {
      const key = mods[i] + ' + ' + mods[j];
      pairs.set(key, (pairs.get(key) || 0) + 1);
    }
  }
}
const mergeCandidates = [...pairs.entries()]
  .filter(([, n]) => commits.length && n / commits.length > CO_CHANGE_THRESHOLD)
  .sort((a, b) => b[1] - a[1]);
const hottest = [...pairs.entries()].sort((a, b) => b[1] - a[1]).slice(0, 3);

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
  const tooSoon = days !== null && days < COOLDOWN_DAYS && since !== null && since < COOLDOWN_COMMITS;
  decisions.push({ mod: mod.kind + ':' + mod.name, days, since, tooSoon, decision: mod.decision });
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
  Math.round(CO_CHANGE_THRESHOLD * 100) + '% of the last ' + CO_CHANGE_WINDOW + ' commit(s) (' + gitNote + ')');
for (const [pair, n] of mergeCandidates) {
  p('module-report:   FLAG merge-candidate: ' + pair + ' (' + n + '/' + commits.length + ' commits, ' +
    Math.round((n / commits.length) * 100) + '%)');
}
if (!mergeCandidates.length && hottest.length) {
  p('module-report:   hottest: ' + hottest.map(([pair, n]) => pair + ' ' + n + '/' + commits.length).join('; '));
}
p('module-report: decision  ' + decisions.length + ' recorded; cooldown ' + COOLDOWN_DAYS + ' day(s) or ' +
  COOLDOWN_COMMITS + ' commit(s) (a reversal needs a new measurement before then)');
for (const d of decisions) {
  p('module-report:   ' + d.mod + ': ' + (d.decision.kind || '?') + ' on ' + (d.decision.date || '?') +
    (d.days !== null ? ' (' + d.days + ' day(s) ago' : '') +
    (d.since !== null ? ', ' + d.since + ' commit(s) ago' : '') + ')' +
    (d.decision.measurement ? ' - ' + d.decision.measurement : '') +
    (d.tooSoon ? '   [FLAG too soon to reverse]' : ''));
}
console.log(out.join('\n'));
// Flags, not failures: the exit code says the report ran, never that the tree is wrong.
process.exit(0);
