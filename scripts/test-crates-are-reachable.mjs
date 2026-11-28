#!/usr/bin/env node
// A CRATE UNDER rust/ THAT CARGO CANNOT BUILD IS A CRATE NOBODY CAN TEST (orphan-crate row, 27/11).
//
// WHAT HAPPENED: `cargo test -p wa-mesh` refused with "package ID specification `wa-mesh` did not match any packages"
// while the directory sat there with a full test suite in it and `scripts/bench-mesh.sh` still asked for it - and the 435
// `wa-mesh-test-*` directories in /tmp came from rows that could no longer run. Before that, a landing (`26dcbb41`) had
// deleted workspace members and another (`a60425be`) had to put them back: nothing checked either way, so a crate could
// leave the build silently in both directions.
//
// The rule, derived from cargo's own rules and not from a list someone types: a crate directory under `rust/` is
// REACHABLE when
//   * it is named in `rust/Cargo.toml`'s members, or
//   * a reachable crate depends on it by path (cargo builds path dependencies of members), or
//   * it declares its own `[workspace]` (deliberately standalone, like `rust/components/*`).
// Anything else cannot be built by `cargo -p` nor by `--manifest-path` ("believes it's in a workspace when it's not"),
// so its tests cannot run. And a script that asks cargo for `-p <name>` where `<name>` is unreachable is the same
// defect from the other side.

import fs from 'node:fs';
import path from 'node:path';

const RUST = 'rust';
const membersSrc = fs.readFileSync(path.join(RUST, 'Cargo.toml'), 'utf8');
const memberBlock = membersSrc.match(/members\s*=\s*\[([\s\S]*?)\]/);
if (!memberBlock) {
  console.error('crates are reachable: FAIL - rust/Cargo.toml has no members list to read');
  process.exit(1);
}
const members = new Set([...memberBlock[1].matchAll(/"([^"]+)"/g)].map((m) => m[1]));

const dirs = fs
  .readdirSync(RUST, { withFileTypes: true })
  .filter((e) => e.isDirectory() && fs.existsSync(path.join(RUST, e.name, 'Cargo.toml')))
  .map((e) => e.name);

const manifest = (dir) => fs.readFileSync(path.join(RUST, dir, 'Cargo.toml'), 'utf8');
const pathDeps = (dir) =>
  [...manifest(dir).matchAll(/path\s*=\s*"\.\.\/([A-Za-z0-9_.-]+)"/g)].map((m) => m[1]);

// Reachability: members, then everything a reachable crate pulls in by path.
const reachable = new Set(members);
const queue = [...members];
while (queue.length) {
  const dir = queue.pop();
  if (!dirs.includes(dir)) continue;
  for (const dep of pathDeps(dir)) {
    if (!reachable.has(dep)) {
      reachable.add(dep);
      queue.push(dep);
    }
  }
}

const standalone = new Set(dirs.filter((dir) => /^\s*\[workspace\]/m.test(manifest(dir))));
const fail = [];
for (const dir of dirs) {
  if (reachable.has(dir) || standalone.has(dir)) continue;
  fail.push(`${RUST}/${dir}: cargo cannot build it (not a member, not a path dependency of a member, no [workspace] of its own) - so nothing can test it`);
}

// The other side: a script asking cargo for a package that cannot be built.
for (const dir of ['scripts', 'factory']) {
  if (!fs.existsSync(dir)) continue;
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (!entry.isFile() || !/\.(sh|mjs|lua)$/.test(entry.name)) continue;
    if (!/^test-/.test(entry.name)) continue;
    const file = path.join(dir, entry.name);
    const body = fs.readFileSync(file, 'utf8');
    // A comment may name a command; it does not run one.
    const code = body.split('\n').filter((line) => !/^\s*(?:#|--|\/\/)/.test(line)).join('\n');
    for (const m of code.matchAll(/cargo\s+(?:test|build)\b[^\n]*?-p\s+([a-z0-9-]+)/g)) {
      const name = m[1];
      if (!reachable.has(name)) fail.push(`${file}: asks cargo for -p ${name}, which cargo cannot build in this workspace`);
    }
  }
}

if (fail.length) {
  console.error('crates are reachable: FAIL');
  for (const line of fail) console.error('  ' + line);
  process.exit(1);
}
console.log(`crates are reachable ok (${dirs.length} crate(s) under rust/, ${reachable.size} reachable through the workspace, ${standalone.size} deliberately standalone)`);
