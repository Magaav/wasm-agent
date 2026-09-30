#!/usr/bin/env node
// One gate suite's wall time and the CPU charged inside its OWN process tree.
//
// WHAT THIS IS. `scripts/test.sh` invokes its suites as separate processes (scripts/test-*.lua through
// the `wa` binary, *.cjs, *.mjs, *.sh, *.ps1). Every one of them is a candidate for being moved,
// batched or parallelised later, and none of that may be decided from group-level timing: the phase
// table says "subagents: 243 s", not which of the seven suites in it is compute-bound and which is
// waiting on a model, a port or a lock. So each suite is measured on its own.
//
// HOW, AND WHY IT IS A LOWER BOUND. The command is spawned with this process as its parent and
// `scripts/lib/gate-lane-sample.ps1` - the same sampler the gate lane already uses for the whole gate -
// walks the parent links down from THAT pid every 500 ms, summing each process's user + kernel CPU
// ticks, and the last line written before the suite exits is the total charged to its tree. A child that
// starts and exits between two samples contributes only what was seen while it ran, which is why the
// figure is a LOWER BOUND and is labelled as one in the artifact. The sampler never outlives the suite:
// it is killed as soon as the child exits.
//
// WHAT IT MUST NOT CHANGE. The suite's argv, environment, stdio and exit code are the suite's: stdio is
// INHERITED, so the gate's own pipes and greps see exactly the bytes they saw before, and the wrapper
// writes nothing to stdout. The only environment it adds is the marker below, which stops a suite that
// spawns node/bash itself from starting a second sampler (`GATE_SUITE_SAMPLED`); such nested work is
// still charged to the suite that started it, through the parent links. A measurement failure never
// fails a suite: every sampler path is wrapped, and a missing CPU figure is recorded as null, not as 0.
//
// Usage (from the shims in scripts/lib/gate-shims, or directly):
//   node scripts/lib/gate-suite.mjs --name <label> -- <program> [args...]
// The record goes to $GATE_SUITES_JSONL, one JSON object per line.
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawn} from 'node:child_process';

const here = path.dirname(fileURLToPath(import.meta.url));
const argv = process.argv.slice(2);
const separator = argv.indexOf('--');
const options = {name: 'unnamed', out: String(process.env.GATE_SUITES_JSONL || '')};
for (let index = 0; index < separator; index += 1) {
  if (argv[index] === '--name') { options.name = argv[index + 1] ?? options.name; index += 1; }
  else if (argv[index] === '--out') { options.out = argv[index + 1] ?? options.out; index += 1; }
}
const command = argv.slice(separator + 1);
if (!command.length) {
  process.stderr.write('gate-suite: no command after --\n');
  process.exit(64);
}
const record = {name: options.name, command: command.join(' '), pid: null, wall_ms: null, cpu_ms: null,
  cpu_bound: 'lower bound', exit: null, sampled: false, started_at: new Date().toISOString()};
const started = Date.now();
// A sampler per suite: one powershell.exe start-up (~300 ms) per suite is charged to the gate's wall
// time, which is why the figure it produces is reported as a lower bound and why the aggregate is
// published beside the log rather than used to make any scheduling decision here.
const sampling = process.platform === 'win32' && !process.env.GATE_SUITE_SAMPLED && Boolean(options.out);
const child = spawn(command[0], command.slice(1), {stdio: 'inherit', windowsHide: true,
  env: {...process.env, GATE_SUITE_SAMPLED: '1'}});
record.pid = child.pid ?? null;
let sampler = null;
let samplerFile = null;
if (sampling && child.pid) {
  try {
    samplerFile = `${options.out}.${child.pid}.cpu.jsonl`;
    fs.rmSync(samplerFile, {force: true});
    sampler = spawn('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
      path.join(here, 'gate-lane-sample.ps1'), '-Root', String(child.pid), '-IntervalMs', '500',
      '-Out', samplerFile], {stdio: ['ignore', 'ignore', 'ignore'], windowsHide: true});
    sampler.unref();
    record.sampled = true;
  } catch { sampler = null; }
}
const forward = signal => { try { child.kill(signal); } catch { /* already gone */ } };
process.on('SIGTERM', () => forward('SIGTERM'));
process.on('SIGINT', () => forward('SIGINT'));
child.on('exit', (code, signal) => {
  record.wall_ms = Date.now() - started;
  record.exit = code === null ? `signal:${signal}` : code;
  if (sampler) { try { sampler.kill('SIGKILL'); } catch { /* gone */ } }
  if (samplerFile) {
    try {
      // The LARGEST total over the lines, not the last one, and the ticks are 100 ns. The sampler is
      // killed a moment after this child exits, so its last line can be taken when the walk finds an
      // empty tree and reports 0 - reading that line is why a 3-second CPU-burning suite first recorded
      // 0 CPU-s while its own sample file read \"t_ms 244: 937500 ... t_ms 3434: 4531250, then 0\".
      // Ticks are absolute per pid and summed over the tree, so the maximum is the tree's total.
      const lines = fs.readFileSync(samplerFile, 'utf8').split('\n').filter(Boolean);
      let best = null;
      let bestIndex = -1;
      for (let index = 0; index < lines.length; index += 1) {
        let line = null;
        try { line = JSON.parse(lines[index]); } catch { line = null; }
        if (!line || !Number.isFinite(line.cpu_ticks)) continue;
        if (best === null || line.cpu_ticks > best) { best = line.cpu_ticks; bestIndex = index; }
      }
      if (best !== null) record.cpu_ms = Math.round(best / 1e4);
      record.cpu_ticks_observed = best;
      record.cpu_sample_line = bestIndex;
      record.samples = lines.length;
    } catch { /* an unreadable sampler file is a missing figure, never a failed suite */ }
    try { fs.rmSync(samplerFile, {force: true}); } catch { /* keep the log clean */ }
  }
  if (options.out) {
    try { fs.appendFileSync(options.out, `${JSON.stringify(record)}\n`); } catch { /* never fatal */ }
  }
  process.exit(code === null ? 1 : code);
});
child.on('error', error => {
  process.stderr.write(`gate-suite: could not start ${command.join(' ')}: ${error.message}\n`);
  process.exit(127);
});
