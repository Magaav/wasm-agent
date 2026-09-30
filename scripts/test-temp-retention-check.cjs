#!/usr/bin/env node
// The temp-retention check's own test: real fixtures, real git, and the falsification of its one hole.
//
// A check nobody falsifies is a comment. This test runs `scripts/check-temp-retention.mjs` against a
// throwaway repository of scripts that mint temp families, and asserts both directions:
//
//   * a file that mints and never mentions it again FAILS, and names the file and the line;
//   * the same file with a removal path passes;
//   * the same file with `temp-retention: <reason>` passes and is reported as declared retention;
//   * a marker with no reason FAILS (a marker is not a decision);
//   * an entry already in the check's DEFERRED list is printed and is NOT fatal, which is what lets the
//     check be wired into the gate while 33 existing files still leak.
//
// Then the FALSIFICATION. The check's retention marker is prose: a file that keeps a temp family forever
// can pass by writing `temp-retention: keep` - which is the check passing something it should fail. The
// test asserts that hole is real (so nobody believes the check is stronger than it is) and then asserts the
// restored fixture fails again, so the hole is a known limitation rather than a broken check.
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const assert = require('node:assert/strict');
const { execFileSync, spawnSync } = require('node:child_process');

const root = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-retention-fixture-'));
const git = (...args) => execFileSync('git', args, { cwd: root, stdio: 'pipe' });
const put = (file, text) => {
  fs.mkdirSync(path.dirname(path.join(root, file)), { recursive: true });
  fs.writeFileSync(path.join(root, file), text);
};
const check = (status, pattern) => {
  const r = spawnSync(process.execPath, ['scripts/check-temp-retention.mjs'], { cwd: root, encoding: 'utf8', timeout: 30000 });
  assert.ifError(r.error);
  assert.equal(r.status, status, r.stdout + r.stderr);
  assert.match(r.stdout, pattern);
  return r.stdout;
};

let checks = 0;
const count = () => { checks += 1; };

try {
  git('init', '-q');
  git('config', 'core.autocrlf', 'false');
  put('scripts/check-temp-retention.mjs', fs.readFileSync(path.join(__dirname, 'check-temp-retention.mjs')));

  // 1. a mint with no mention of it anywhere else in the file: the leak that happened here
  put('scripts/leak.sh', '#!/usr/bin/env bash\nHOME_DIR="$(mktemp -d "${TMPDIR:-/tmp}/wa-leak-XXXXXX")"\necho "$HOME_DIR"\n');
  git('add', '.'); git('commit', '-qm', 'leak');
  const leaked = check(1, /FAIL\s+scripts\/leak\.sh mints a temp family and never bounds it/);
  assert.match(leaked, /2:mktemp/); count();

  // 2. the same mint with a removal path in the same file: passes, and says how
  put('scripts/leak.sh', '#!/usr/bin/env bash\nHOME_DIR="$(mktemp -d "${TMPDIR:-/tmp}/wa-leak-XXXXXX")"\ntrap \'rm -rf "$HOME_DIR"\' EXIT\necho "$HOME_DIR"\n');
  git('add', '.'); git('commit', '-qm', 'cleanup');
  const cleaned = check(0, /ok\s+scripts\/leak\.sh/);
  assert.match(cleaned, /removes via/); count();

  // 3. a declared retention with a reason: passes, printed as a decision
  put('scripts/leak.sh', '#!/usr/bin/env bash\n# Kept on purpose.\n# temp-retention: one directory per process, reused for the process lifetime\nHOME_DIR="$(mktemp -d "${TMPDIR:-/tmp}/wa-leak-XXXXXX")"\n');
  git('add', '.'); git('commit', '-qm', 'retain');
  const retained = check(0, /RETAIN scripts\/leak\.sh \(one directory per process/); count();

  // 4. the marker with no reason: not a decision, so not an excuse
  put('scripts/leak.sh', '#!/usr/bin/env bash\nHOME_DIR="$(mktemp -d "${TMPDIR:-/tmp}/wa-leak-XXXXXX")"\n# temp-retention:\n');
  git('add', '.'); git('commit', '-qm', 'empty marker');
  check(1, /FAIL\s+scripts\/leak\.sh declares a retention with no reason/); count();

  // 5. an existing offender is printed and is not fatal - the property that lets the check run in a gate
  put('scripts/leak.sh', '');
  put('scripts/test-subagents.cjs', "const fs = require('node:fs');\nconst home = fs.mkdtempSync(require('node:path').join(require('node:os').tmpdir(), 'wa-subagent-test-'));\n");
  git('add', '.'); git('commit', '-qm', 'deferred');
  const deferred = check(0, /DEFERRED scripts\/test-subagents\.cjs/);
  assert.match(deferred, /deferred/); count();

  // FALSIFICATION: the hole. An unbounded family plus a marker passes - the check cannot weigh a reason.
  put('scripts/unbounded.sh', '#!/usr/bin/env bash\n# temp-retention: kept forever, never removed, deliberately unbounded\nDIR="$(mktemp -d "${TMPDIR:-/tmp}/wa-forever-XXXXXX)"\n');
  git('add', '.'); git('commit', '-qm', 'unbounded with marker');
  const hole = check(0, /RETAIN scripts\/unbounded\.sh \(kept forever, never removed/);
  assert.ok(!/FAIL/.test(hole.split('\n').filter(l => l.includes('unbounded.sh')).join('\n')), 'the hole should show as a pass');
  count();

  // ...and restoring the fixture (no marker) fails it again, so the hole is the marker and not the check
  put('scripts/unbounded.sh', '#!/usr/bin/env bash\nDIR="$(mktemp -d "${TMPDIR:-/tmp}/wa-forever-XXXXXX)"\n');
  git('add', '.'); git('commit', '-qm', 'unbounded without marker');
  check(1, /FAIL\s+scripts\/unbounded\.sh mints a temp family and never bounds it/); count();

  console.log(`temp-retention check ok (${checks} checks, 0 skipped; the marker hole is asserted, not hidden)`);
} finally {
  fs.rmSync(root, { recursive: true, force: true });
}
