// IS THIS MODULE THE ONE THAT WAS RUN? Ask it by REAL PATH.
//
// Measured 24/11 on \`work\`, and it cost a whole install: \`wa update\` (build 7865a08e -> 5bb28d8a) ran
// scripts/deploy.sh, which pins the commit and builds in a pinned worktree under
// \`/tmp/wa-deploy-pins/<sha>\` - a SYMLINK to \`/home/agent/.wasm-agent/pins/<sha>\` on that node. The host
// build then invoked \`node /tmp/wa-deploy-pins/<sha>/scripts/codemode-build.mjs build <root>\`, whose
// entry guard compared \`path.resolve(process.argv[1])\` (which does NOT resolve symlinks) with
// \`fileURLToPath(import.meta.url)\` (which Node has already canonicalized). They never matched: the
// module loaded, printed NOTHING, ran cargo NEVER, and exited 0. deploy.sh's \`|| fail\` saw success,
// wa-host.log stayed empty ("compiled 0 crate(s)"), the sentinel built for 340 s, and the deploy died
// with "no built binary at .../release/wa" after 361 s - with no line anywhere saying what went wrong.
//
// So every entry guard in this tree asks \`isMain(import.meta.url)\`, and this is the one implementation
// (scripts/test-main-module-entry.mjs keeps copies of the old idiom out).
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export function realPath(value) {
  try { return fs.realpathSync(value); } catch { return path.resolve(String(value)); }
}

export function isMain(importMetaUrl, argv1 = process.argv[1]) {
  if (!argv1) return false;
  try { return realPath(argv1) === realPath(fileURLToPath(importMetaUrl)); } catch { return false; }
}
