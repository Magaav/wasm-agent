#!/usr/bin/env node
// A ROW THAT WRITES A REPOSITORY OWNS ITS ENVIRONMENT (factory-is-small-and-tested, 27/11).
//
// WHAT HAPPENED: `scripts/test-peer-update-installs.sh` and `factory/test-daily-line.sh` built scratch repositories with
// `git init` and `git config user.name row`. Run from a suite started by a git hook - which exports GIT_DIR,
// GIT_INDEX_FILE and GIT_WORK_TREE to every child - those writes landed in the SHARED repository instead of the row's
// scratch directory. The same incident one layer down as 24/11's session commits landing in another worktree.
//
// The rule: any row that writes repository state must clear those names first, through the one helper
// (`scripts/lib/git-env.sh`: `wa_git` / `wa_git_isolate`), or state why it does not. Reading (`git rev-parse`) is not
// the rule: a read cannot move another repository's HEAD.

import fs from 'node:fs';
import path from 'node:path';

const ROOTS = ['scripts', 'factory'];
// The three the incident named, and only them: git init, git config and git commit write into whatever repository
// git resolves - and a read the row makes of its own tree is not the rule.
const WRITE = /\bgit\s+(?:-C\s+(?:"[^"]*"|\S+)\s+)?(?:init|config|commit)\b/;
const COMMENT = /^\s*(?:#|\/\/|--)/;
const CLEARS = [/lib\/git-env\.sh/, /unset[^\n]*GIT_DIR/, /env\s+-u\s+GIT_DIR/];

// A row may keep its own answer, but only by naming it here with the reason.
const KEEPS = {
  // The two signing rows are held by the landing queue for the orchestrator's read (their change is the shim alone, +5
  // lines each). Their shims travel in `change/git-env-signing-rows`, so this branch can land the helper, the guard and the
  // other 35 rows now; this entry is what keeps the guard honest about the two it does not cover yet, and it goes away with
  // that branch.
  'scripts/test-land-signing.sh': {
    why: "HELD: this row's git shim is in change/git-env-signing-rows, waiting on the orchestrator's read of a signing row",
  },
  'scripts/test-release-signing.sh': {
    why: "HELD: this row's git shim is in change/git-env-signing-rows, waiting on the orchestrator's read of a signing row",
  },
  // The queue's own-row run has no built components or binaries, and these two rows need them: their shims travel in
  // change/git-env-signing-rows with the signing rows, so this branch does not carry two rows that are red for their own
  // environment rather than for anything in the change.
  'scripts/test-component-pins.sh': {
    why: "HELD: this row's shim travels in change/git-env-signing-rows - the row needs built components the queue does not have",
  },
  'scripts/test-publish-artifacts.sh': {
    why: "HELD: this row's shim travels in change/git-env-signing-rows - the row needs built binaries the queue does not have",
  },
  'scripts/test-git-env-isolation.sh': {
    why: 'this row IS the incident: it starts two nodes UNDER a redirect on purpose and then proves they stay apart; its own reads go through the helper',
  },
};

function files(dir, out = []) {
  if (!fs.existsSync(dir)) return out;
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) files(full, out);
    else if (/^test-.*\.(sh|lua|mjs)$/.test(entry.name)) out.push(full);
  }
  return out;
}

const fail = [];
let checked = 0;
const helper = fs.existsSync('scripts/lib/git-env.sh') ? fs.readFileSync('scripts/lib/git-env.sh', 'utf8') : null;
if (helper === null) fail.push("scripts/lib/git-env.sh is missing: the one place that clears git's redirect does not exist");
else {
  for (const name of ['GIT_DIR', 'GIT_INDEX_FILE', 'GIT_WORK_TREE', 'GIT_COMMON_DIR']) {
    if (!helper.includes(name)) fail.push(`scripts/lib/git-env.sh does not clear ${name}`);
  }
}

for (const file of ROOTS.flatMap((root) => files(root))) {
  if (file.startsWith('scripts/lib/')) continue;
  const body = fs.readFileSync(file, 'utf8');
  const lines = body.split('\n');
  // A row only counts when it RUNS the command: a bash row does, and a lua/js row does when it executes a shell
  // (os.execute, io.popen, host.bash, execFile, spawn). A command string a fixture HANDS to the agent is data, not a
  // write this row performs.
  const EXEC = /os\.execute|io\.popen|host\.bash|execFile|execSync|spawn\(/;
  const runsShell = file.endsWith('.sh') || EXEC.test(body);
  if (!runsShell) continue;
  const hit = lines.findIndex((line) => WRITE.test(line) && !COMMENT.test(line)
    && (file.endsWith('.sh') || /os\.execute|io\.popen|host\.bash|execFile|execSync|spawn\(/.test(line)));
  if (hit === -1) continue;
  checked += 1;
  const cleared = CLEARS.some((pattern) => pattern.test(body));
  if (!cleared && !(file in KEEPS)) {
    fail.push(`${file}:${hit + 1} runs a git command that writes repository state without clearing GIT_DIR: ${lines[hit].trim().slice(0, 80)}`);
  }
  if (!cleared && file in KEEPS && !KEEPS[file].why) fail.push(`${file}: a KEEP with no reason`);
}

if (fail.length) {
  console.error('rows clear git env: FAIL');
  for (const line of fail) console.error('  ' + line);
  process.exit(1);
}
console.log(`rows clear git env ok (${checked} row(s) that write repository state, each clearing git's redirect or named in the KEEP list)`);
