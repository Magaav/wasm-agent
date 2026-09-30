#!/usr/bin/env node
// The disk floor's own test: the refusal text, the numbers in it, and the one wiring that matters.
//
// Requirement 1 is "refuse, and say the numbers", so this test asserts the numbers: the refusal has to
// name the floor it wanted and the free space it found, because that sentence is the only signal a gate
// that dies ten seconds into a build ever produced. The rest is the contract around it - a deliberate
// floor is the only way past it, a bad argument is refused rather than defaulted, the `--json` shape an
// alarm would read is stable, and the gate calls this *before* its first `cargo` line so a refusal happens
// before any work is paid for.
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');

const root = path.resolve(__dirname, '..');
const bash = process.platform === 'win32' ? path.join(process.env.ProgramFiles || 'C:/Program Files', 'Git/bin/bash.exe') : 'bash';
const source = fs.readFileSync(path.join(root, 'scripts/check-disk-floor.sh'), 'utf8');
const declaredFloor = Number(/^FLOOR_BYTES=(\d+)$/m.exec(source)[1]);
const HUGELY_ABOVE_ANY_DISK = '9223372036854775807';

const floor = (...args) => spawnSync(bash, ['scripts/check-disk-floor.sh', ...args], { cwd: root, encoding: 'utf8', timeout: 30000 });

let checks = 0;
const count = () => { checks += 1; };

// 1. the floor it declares is the floor it prints (a constant that drifts from its own output is a lie)
const healthy = floor('--floor-bytes', '1');
assert.ifError(healthy.error); count();
assert.equal(healthy.status, 0, healthy.stdout + healthy.stderr); count();
assert.match(healthy.stdout, /ok:\s+\S+ GiB >= the \S+ GiB a run needs/); count();
assert.match(healthy.stdout, /floor: [\d.]+ GiB \(\d+ B\)/); count();

// 2. the default floor is the measured one, and it is above the tiny floor above
const declared = floor('--floor-bytes', String(declaredFloor));
assert.equal(declared.status, 0, declared.stdout + declared.stderr); count();
assert.match(declared.stdout, new RegExp(`floor: [\\d.]+ GiB \\(${declaredFloor} B\\)`)); count();

// 3. THE REFUSAL: a floor above the free space refuses, and names both numbers
const refused = floor('--floor-bytes', HUGELY_ABOVE_ANY_DISK);
assert.equal(refused.status, 1, refused.stdout + refused.stderr); count();
assert.match(refused.stderr, /needs ~[\d.]+ GiB free space and has [\d.]+ GiB \(\d+ B needed, \d+ B available on /); count();
assert.match(refused.stdout, /free:\s+[\d.]+ GiB of [\d.]+ GiB on /); count();

// 4. a refused run says where to look next, so the refusal is actionable
assert.match(refused.stderr, /reclaim-disk\.sh --report/); count();

// 5. the shape an alarm would read
const json = floor('--json', '--floor-bytes', '1');
assert.equal(json.status, 0, json.stdout + json.stderr); count();
const parsed = JSON.parse(json.stdout);
for (const field of ['floor_bytes', 'available_bytes', 'total_bytes', 'mount', 'path', 'ok', 'method']) {
  assert.ok(Object.prototype.hasOwnProperty.call(parsed, field), `--json is missing ${field}`);
  count();
}
assert.equal(parsed.floor_bytes, 1); count();
assert.ok(parsed.available_bytes > 0 && parsed.total_bytes >= parsed.available_bytes); count();
const jsonRefused = floor('--json', '--floor-bytes', HUGELY_ABOVE_ANY_DISK);
assert.equal(jsonRefused.status, 1); count();
assert.equal(JSON.parse(jsonRefused.stdout).ok, false); count();

// 6. a bad argument is refused, never defaulted
assert.equal(floor('--floor-bytes', 'plenty').status, 2); count();
assert.equal(floor('--path', path.join(root, 'scripts', 'check-disk-floor.sh')).status, 2); count();
assert.equal(floor('--nonsense').status, 2); count();

// 7. the gate asks before it pays. The preflight has to be ahead of the first build AND ahead of the
// environment fence, so an ambient variable cannot move the floor the gate uses.
const gate = fs.readFileSync(path.join(root, 'scripts/test.sh'), 'utf8').split('\n');
const preflight = gate.findIndex(line => line.includes('scripts/check-disk-floor.sh'));
const firstBuild = gate.findIndex(line => /^cargo build/.test(line));
const fence = gate.findIndex(line => line.includes('compgen -e'));
assert.ok(preflight > 0, 'scripts/test.sh does not call scripts/check-disk-floor.sh'); count();
assert.ok(preflight < firstBuild, 'the preflight must run before the gate\'s first build'); count();
assert.ok(preflight < fence, 'the preflight must run before the environment fence, not under it'); count();

console.log(`disk floor ok (${checks} checks, 0 skipped; refusal names ${parsed.available_bytes} B free against a ${declaredFloor} B floor)`);
