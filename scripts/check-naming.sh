#!/usr/bin/env bash
# No old name survives.
#
# ARCHITECTURE.md section 6 renamed three things that had been sharing two words: `session_turns()`
# returned *messages*, `turn_id` identified a *run* in one place and a *message* in another, and the UI
# said "this turn" meaning the run. A rename that leaves both names in the tree is worse than not doing
# it - the next reader cannot tell which is current, and every grep finds two answers - so this is a
# check in the suite, not a convention in a document.
#
# It greps for the old *names*, never for the word "turn": section 6 keeps that word for one speaker's
# contribution, so "a turn with an image" is still the right sentence and must not fail this.
#
# Three things are allowed, and each says why:
#   * a line carrying `naming-check: allow` - used where a name must stay (see the marker in
#     `rust/wa-host/src/host.rs`);
#   * `lua/core/memory.lua`'s `migrate_shape()`: a migration has to name what it moves. Those strings are
#     the *matcher* for rows written before this change, and changing them would stop matching them;
#   * `tests/naming-migration.lua`, which builds the old shape on purpose so it can be migrated, and
#     `ARCHITECTURE.md`, whose table records what things *were* called - that is its whole point.
set -euo pipefail
cd "$(dirname "$0")/.."

# One interpreter and one git invocation, not two grep processes per name per file.
# The old loop spawned tens of thousands of processes and exhausted MSYS fork resources
# during the orchestration baseline gate. Node is already required by test.sh.
node <<'NODE'
const fs = require('node:fs');
const { execFileSync } = require('node:child_process');
const names = [
  'session_turns', 'turn_id', 'turn_span', 'turns_fts', 'turns_session_idx', 'turns_time_idx',
  'FROM turns', 'INTO turns', 'UPDATE turns', 'DELETE FROM turns',
  'renderTurns', 'repaintTurns', 'turnBubble', 'turnPolling', 'turnStartedAt', 'turnId',
  'turn_count', 'parse_turn_body', 'run_turn', 'local_turn', 'search_turns',
  'turn-shape', 'the last turn failed',
  // These labels falsely described a tool/configuration preview as a provider request.
  'raw envelope', 'envelope the model sees', 'exact envelope sent',
  'each turn is one HTTP request', 'envelope-raw',
  // A node's execution threads are node-threads, not workers: "worker" is the delegated child
  // session (a subagent). These are spellings of the *thread*, so they must not come back. The word
  // "worker" is deliberately absent - it still means a subagent - and the four names that keep it on
  // purpose are named where they live: the `workers[]` alias for the installed sentinel, the
  // operator's `WASM_AGENT_WORKER*` env vars, the node-wide state key `worker` (serve.rs), and the
  // durable `worker:` operation-owner prefix (ui/app.js). `choose_worker` is not listed either:
  // `skills/code-graph/SKILL.md` uses it as an *example* query name, and a skill is out of scope.
  'workers_count', 'workers_spawned', 'workers_retired', 'control_workers', 'worker_count', 'worker_stalled',
  'live_worker_ids', 'worker_age_ms', 'worker_is_wedged', 'worker_busy_label', 'worker_session',
  'worker_run_id', 'spawn_worker', 'pick_run_worker', 'warm_read_workers', 'max_workers',
  'turn_worker_is_idle', 'worker_loop', 'worker_ui',
  'WORKER_BEATS', 'WORKER_BUSY', 'WORKER_SESSION', 'WORKER_RUN', 'WORKER_ID',
];
let scanned = 0, hits = 0;
const files = execFileSync('git', ['ls-files', '-z'], { encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 }).split('\0').filter(Boolean);
for (const file of files) {
  if (['scripts/check-naming.sh', 'ARCHITECTURE.md', 'tests/naming-migration.lua'].includes(file)
      || file.includes('target') || /\.(wasm|png|ico|bmp)$/.test(file)) continue;
  if (!fs.existsSync(file) || !fs.statSync(file).isFile()) continue;
  const lines = fs.readFileSync(file, 'utf8').split('\n');
  let inside = false;
  const visible = [];
  for (let index = 0; index < lines.length; index++) {
    const text = lines[index];
    if (file === 'lua/core/memory.lua') {
      if (/^local function migrate_shape\(\)/.test(text)) inside = true;
      if (inside && /^end$/.test(text)) { inside = false; continue; }
      if (inside) continue;
    }
    if (!text.includes('naming-check: allow')) visible.push({ number: index + 1, text });
  }
  scanned++;
  for (const name of names) {
    const found = visible.filter(line => line.text.includes(name));
    if (found.length) {
      hits++;
      console.log(`  FAIL ${file} still says ${name}`);
      for (const line of found.slice(0, 3)) console.log(`         ${line.number}:${line.text}`);
    }
  }
}
console.log(hits ? `naming FAILED (${hits} old name(s) left)` : `naming ok (${scanned} files, no old names)`);
process.exitCode = hits ? 1 : 0;
NODE
