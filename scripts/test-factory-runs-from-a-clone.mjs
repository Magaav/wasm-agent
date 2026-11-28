#!/usr/bin/env node
// A FACTORY SERVICE RUNS THE CLONE'S factory/ SCRIPT, NEVER A HAND COPY (factory-is-small-and-tested, 27/11).
//
// WHAT HAPPENED: the health loop executed ~/Work/missions/_orch/health-loop.sh - a copy - so queues #123 and #142 landed on
// main and changed nothing for three hours: the loop that judges a landing was running code from the day the copy was
// made. `factory/clone.sh` + `factory/units.sh` make that impossible for a NEW unit; this row makes it visible for the
// ones that already exist, on the machine that owns them.
//
// It reads the user's systemd units (this is a node row, not a portable library check) and refuses any unit whose
// ExecStart names a factory script through a path that is not inside a clone - `_orch`, a checkout, a home copy. A machine
// with no such unit says so and passes: nothing to police there.

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const factoryDir = 'factory';
const scripts = new Set(fs.readdirSync(factoryDir).filter((f) => f.endsWith('.sh')));
const unitDirs = [
  path.join(process.env.XDG_CONFIG_HOME || path.join(os.homedir(), '.config'), 'systemd', 'user'),
  '/etc/systemd/system',
];

const units = [];
for (const dir of unitDirs) {
  if (!fs.existsSync(dir)) continue;
  for (const name of fs.readdirSync(dir)) {
    if (!/^(orch|factory)-.*\.service$/.test(name)) continue;
    units.push({ file: path.join(dir, name), name });
  }
}

// The ten units that still point at a hand copy TODAY, each with the reason it is still there. The list can only shrink:
// `factory/units.sh --apply` replaces them, and a NEW unit that points outside a clone fails here by name.
const BASELINE = 'factory/units-baseline.txt';
const tolerated = new Set();
if (fs.existsSync(BASELINE)) {
  for (const line of fs.readFileSync(BASELINE, 'utf8').split('\n')) {
    if (!line.trim() || line.startsWith('#')) continue;
    const [unit, why] = line.split('\t');
    if (!unit || !why) {
      console.error(`factory runs from a clone: FAIL - baseline line without unit and reason: ${line.slice(0, 80)}`);
      process.exit(1);
    }
    tolerated.add(unit);
  }
}

const fail = [];
let checked = 0;
let toleratedHits = 0;
for (const unit of units) {
  const body = fs.readFileSync(unit.file, 'utf8');
  const exec = (body.match(/^ExecStart=(.*)$/m) || [])[1];
  if (!exec) continue;
  const script = path.basename(exec.trim().split(/\s+/).pop());
  if (!scripts.has(script)) continue;
  checked += 1;
  // A clone is the only thing a service may run: the path must sit inside a directory that IS a git clone of this repo.
  const dir = exec.trim().split(/\s+/).pop().replace(/^%h\//, os.homedir() + '/');
  let inside = null;
  for (let d = path.dirname(dir); d !== path.dirname(d); d = path.dirname(d)) {
    if (fs.existsSync(path.join(d, '.git'))) { inside = d; break; }
  }
  if (!inside) {
    if (tolerated.has(unit.name)) { toleratedHits += 1; continue; }
    fail.push(`${unit.name}: ExecStart runs ${script} from ${dir}, which is not inside a git clone (a hand copy is not a service; see factory/units.sh)`);
  }
}

// The list the operator asked for: `_orch` copies that have a factory/ twin, so a stale copy is visible by name.
const orch = path.join(os.homedir(), 'Work', 'missions', '_orch');
let twins = [];
if (fs.existsSync(orch)) {
  twins = fs.readdirSync(orch).filter((f) => scripts.has(f));
}

// A FACTORY SERVICE THAT LOOPS MUST REFRESH BETWEEN ITERATIONS (27/11): ExecStartPre runs once, so a loop kept running the
// code it started with and q#178 sat unused for 45 minutes. WHICH services are loops is not a list typed here: it is the
// `shape` column of factory/units.sh, so the two cannot drift.
const unitsScript = fs.readFileSync(path.join(factoryDir, 'units.sh'), 'utf8');
const loopScripts = [];
for (const line of unitsScript.split('\n')) {
  const m = line.match(/^([a-z0-9-]+)\|([a-z0-9-]+\.sh)\|(loop|timer)\|/);
  if (m && m[3] === 'loop') loopScripts.push(m[2]);
}
if (loopScripts.length === 0) {
  fail.push('factory/units.sh names no loop-shaped service, so the refresh rule would check nothing');
}
for (const script of loopScripts) {
  if (!scripts.has(script)) continue;
  const body = fs.readFileSync(path.join(factoryDir, script), 'utf8');
  if (!body.includes('wa_factory_refresh_self')) {
    fail.push(`factory/${script} is a loop-shaped service with no wa_factory_refresh_self: with only ExecStartPre it runs the code it started with (factory/lib/refresh-self.sh)`);
  }
}

if (fail.length) {
  console.error('factory runs from a clone: FAIL');
  for (const line of fail) console.error('  ' + line);
  process.exit(1);
}
const note = units.length === 0
  ? 'no factory unit on this machine'
  : `${checked - toleratedHits} of ${checked} factory unit(s) already run a script inside a clone`;
console.log(`factory runs from a clone ok (${note}; ${toleratedHits} unit(s) still on a hand copy, each named in ${BASELINE}; ${twins.length} hand cop${twins.length === 1 ? 'y' : 'ies'} in _orch have a factory twin)`);
