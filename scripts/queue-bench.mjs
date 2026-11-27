#!/usr/bin/env node
// WHAT THE QUEUE COSTS ON THE PATH WHERE THE MODEL USED TO SIT: a submit, and a verdict read back.
//
// `bash scripts/queue-bench.mjs [--n 20] [--db <file>]`
//
// The number that matters is not throughput (one request at a time, by design) but the TURN-FREE part: how long
// a session waits to be told "request #7, position 2". The baseline for the landing itself is
// `_orch/landing-times.tsv` from the v0 train - lua branches 2-3 s, compiled ones 279-492 s - and the queue
// cannot change that: it changes WHO waits. This script measures the part it can.
//
// It writes into a temp journal, never the live one, and prints a table plus one verdict line.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {execFileSync} from 'node:child_process';

const argv = process.argv.slice(2);
const flag = (name, fallback) => { const i = argv.indexOf(`--${name}`); return i >= 0 ? argv[i + 1] : fallback; };
const n = Number(flag('n', 20));
const work = fs.mkdtempSync(path.join(process.env.TMPDIR || os.tmpdir(), 'wa-queue-bench-'));
const dbFile = flag('db', path.join(work, 'journal.db'));
const home = path.join(work, 'home');
fs.mkdirSync(path.join(home, 'lane'), {recursive: true});
const repo = execFileSync('git', ['rev-parse', '--show-toplevel'], {encoding: 'utf8'}).trim();
const sha = execFileSync('git', ['-C', repo, 'rev-parse', 'HEAD'], {encoding: 'utf8'}).trim();
const queue = path.join(repo, 'scripts', 'queue.mjs');

const times = [];
for (let i = 0; i < n; i += 1) {
  const started = process.hrtime.bigint();
  execFileSync(process.execPath, [queue, 'submit', `change/bench-${i}`, sha, 'bench', '--repo', repo, '--db', dbFile],
    {encoding: 'utf8', env: {...process.env, WASM_AGENT_HOME: home, TMPDIR: work}});
  times.push(Number(process.hrtime.bigint() - started) / 1e6);
}
const sorted = [...times].sort((a, b) => a - b);
const pct = (p) => sorted[Math.min(sorted.length - 1, Math.floor((p / 100) * sorted.length))];
const bytes = fs.statSync(dbFile).size;

console.log('queue bench (submit path, one process per call)');
console.log(`  n=${n}  min=${sorted[0].toFixed(1)} ms  p50=${pct(50).toFixed(1)} ms  p95=${pct(95).toFixed(1)} ms  max=${sorted[sorted.length - 1].toFixed(1)} ms`);
console.log(`  journal ${bytes} bytes for ${n} request(s)`);
console.log('  baseline for the landing itself (_orch/landing-times.tsv): lua 2-3 s, compiled 279-492 s');
console.log(`queue bench ok (${n} submits, p50 ${pct(50).toFixed(1)} ms)`);
