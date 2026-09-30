#!/usr/bin/env node
// The reclaim pass's own test: the trees it must never prune, on fixtures where the answer is known.
//
// The whole value of a pass that deletes build output is the list of trees it refuses. This fixture builds
// a real git repository with five registered worktrees and a real session store beside it, and asserts:
//
//   * a managed session worktree whose session has ENDED is the only one pruned, and its bytes are measured;
//   * a LIVE session's worktree is kept and the reason says so;
//   * a tree with no session row is refused (ownership unproven is not permission);
//   * the canonical checkout is kept - it is the only tree on `main`;
//   * a tree outside the managed area (a lane, or the node's own worktree) is kept, even when it holds the
//     biggest target of all;
//   * in `--apply` mode the pruned tree's `rust/target` is gone and the tree, its branch and every other
//     target are untouched;
//   * a temp family this repository mints is expired when stale and kept when fresh.
//
// Nothing here touches the live node: every path is under one temporary root, which is deleted at the end.
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const assert = require('node:assert/strict');
const { execFileSync, spawnSync } = require('node:child_process');

const root = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-reclaim-fixture-'));
const repo = path.join(root, 'canonical');
const stateDir = path.join(root, 'state');
const tempDir = path.join(root, 'temp');
const dbPath = path.join(root, 'memory.db');
const git = (cwd, ...args) => execFileSync('git', args, { cwd, stdio: 'pipe' });
const cleanId = id => id.replace(/[^\w-]/g, '');
const mkdir = dir => fs.mkdirSync(dir, { recursive: true });

// 64 KiB of build output per tree, so a pruned target's measured size is not zero.
function giveTarget(tree, kib = 64) {
  const target = path.join(tree, 'rust', 'target');
  mkdir(target);
  fs.writeFileSync(path.join(target, 'thing.bin'), Buffer.alloc(kib * 1024, 7));
  return target;
}

const sessions = [
  { id: 'fixture-a:ended', ended: 1790000000 },
  { id: 'fixture-b:live', ended: null },
  { id: 'fixture-c:unrecorded', ended: 1790000000, recorded: false },
];
const trees = {};
let checks = 0;
const count = () => { checks += 1; };

const run = (...args) => spawnSync(process.execPath, [path.join(__dirname, 'reclaim-disk.mjs'), ...args], { cwd: repo, encoding: 'utf8', timeout: 120000 });

try {
  mkdir(stateDir); mkdir(tempDir);
  git(root, 'init', '-q', '--initial-branch=main', 'canonical');
  git(repo, 'config', 'core.autocrlf', 'false');
  git(repo, 'config', 'user.email', 'fixture@example.invalid');
  git(repo, 'config', 'user.name', 'fixture');
  mkdir(path.join(repo, 'scripts'));
  fs.writeFileSync(path.join(repo, 'scripts', 'mint.sh'), '#!/usr/bin/env bash\nD="$(mktemp -d "${TMPDIR:-/tmp}/wa-fixture-family-XXXXXX")"\nrm -rf "$D"\n');
  fs.writeFileSync(path.join(repo, 'README.md'), 'fixture\n');
  git(repo, 'add', '.'); git(repo, 'commit', '-qm', 'fixture');
  const canonicalTarget = giveTarget(repo);

  // one managed worktree per session shape, under the state dir, plus a lane tree outside it
  for (const session of sessions) {
    const clean = cleanId(session.id);
    const tree = path.join(stateDir, `wa-worktree-${clean}`);
    git(repo, 'worktree', 'add', '-q', '-b', `change/wa-session-${clean}`, tree);
    trees[session.id] = { tree, target: giveTarget(tree) };
  }
  const lane = path.join(root, 'lane-tree');
  git(repo, 'worktree', 'add', '-q', '-b', 'lane-branch', lane);
  const laneTarget = giveTarget(lane, 256);

  // the session store the pass reads, with the real schema's columns
  const { DatabaseSync } = require('node:sqlite');
  const db = new DatabaseSync(dbPath);
  db.exec(`CREATE TABLE sessions (id TEXT PRIMARY KEY, ended_at REAL, worktree TEXT NOT NULL DEFAULT '', workspace_state TEXT NOT NULL DEFAULT 'unbound', workspace_branch TEXT NOT NULL DEFAULT '');
CREATE TABLE runs (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, ended_at REAL);`);
  const insert = db.prepare('INSERT INTO sessions(id, ended_at, worktree, workspace_state, workspace_branch) VALUES (?,?,?,?,?)');
  for (const session of sessions) {
    if (session.recorded === false) continue;
    insert.run(session.id, session.ended, trees[session.id].tree, 'allocated', `change/wa-session-${cleanId(session.id)}`);
  }
  db.close();

  // one stale family entry and one fresh one
  const stale = path.join(tempDir, 'wa-fixture-family-stale01');
  const fresh = path.join(tempDir, 'wa-fixture-family-fresh01');
  mkdir(stale); fs.writeFileSync(path.join(stale, 'x'), 'x');
  mkdir(fresh); fs.writeFileSync(path.join(fresh, 'x'), 'x');
  const old = new Date(Date.now() - 48 * 3600 * 1000);
  fs.utimesSync(stale, old, old);
  const unrelated = path.join(tempDir, 'not-ours-stale');
  mkdir(unrelated); fs.utimesSync(unrelated, old, old);

  const common = ['--repo', repo, '--state-dir', stateDir, '--temp-dir', tempDir, '--db', dbPath, '--report', path.join(root, 'report.json')];

  // ── report: every verdict, nothing removed ─────────────────────────────────────────────────────
  const report = run(...common);
  assert.ifError(report.error);
  assert.equal(report.status, 0, report.stdout + report.stderr); count();
  const ended = trees['fixture-a:ended'].tree;
  const live = trees['fixture-b:live'].tree;
  const unrecorded = trees['fixture-c:unrecorded'].tree;
  assert.match(report.stdout, new RegExp(`PRUNE ${path.basename(ended)}\\s+disposable`)); count();
  assert.match(report.stdout, new RegExp(`KEEP ${path.basename(live)}\\s+live_session`)); count();
  assert.match(report.stdout, /REFUSE wa-worktree-fixture-cunrecorded {2}missing_session_record/); count();
  assert.match(report.stdout, /KEEP canonical {2}canonical_worktree/); count();
  assert.match(report.stdout, /KEEP lane-tree {2}outside_managed_area/); count();
  assert.match(report.stdout, /disk that would be freed: 64 KB across 1 target/); count();
  assert.ok(fs.existsSync(trees['fixture-a:ended'].target), 'report mode must not remove anything'); count();
  assert.match(report.stdout, /wa-fixture-family\*\s+n=1\s+1 B\s+oldest=48h\s+minted by scripts\/mint\.sh/); count();
  assert.match(report.stdout, /KEEP\s+wa-fixture-family-fresh01\s+— fresh/); count();
  const parsed = JSON.parse(fs.readFileSync(path.join(root, 'report.json'), 'utf8'));
  assert.equal(parsed.apply, false); count();
  assert.equal(parsed.targets.find(t => t.name === path.basename(ended)).bytes, 64 * 1024); count();

  // ── apply: the ended session's target goes, nothing else does ─────────────────────────────────
  const applied = run('--apply', ...common);
  assert.equal(applied.status, 0, applied.stdout + applied.stderr); count();
  assert.equal(fs.existsSync(trees['fixture-a:ended'].target), false, 'the ended session\'s target should be gone'); count();
  assert.equal(fs.existsSync(ended), true, 'the tree itself must survive'); count();
  assert.equal(git(repo, 'branch', '--list', 'change/wa-session-fixture-aended').toString().trim().length > 0, true); count();
  for (const [label, target] of [['live session', trees['fixture-b:live'].target], ['unrecorded tree', trees['fixture-c:unrecorded'].target], ['canonical', canonicalTarget], ['lane tree', laneTarget]]) {
    assert.equal(fs.existsSync(target), true, `${label} target must survive --apply`); count();
  }
  assert.equal(fs.existsSync(stale), false, 'the stale family entry should be gone'); count();
  assert.equal(fs.existsSync(fresh), true, 'the fresh family entry must survive'); count();
  assert.equal(fs.existsSync(unrelated), true, 'an entry no tracked script claims must survive'); count();

  console.log(`reclaim pass ok (${checks} checks, 0 skipped; pruned an ended session's target, kept the live, unrecorded, canonical and lane targets)`);
} finally {
  fs.rmSync(root, { recursive: true, force: true });
}
