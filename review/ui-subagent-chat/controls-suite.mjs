#!/usr/bin/env node
// Falsification controls for the NEW durable claim-5 block and page-budget check in scripts/test-ui.ps1.
//
// "Can it pass with the behaviour removed?" is answered by reverting ONE thing at a time in a
// disposable copy of the tree's ui/ (never the delivery's own ui/), running the repository's own
// scripts/test-ui.ps1 from that copy, and reading its verdict line. A mutation that leaves it green is
// a hole the durable block does not close.
import fs from 'node:fs';
import path from 'node:path';
import {execFileSync} from 'node:child_process';

const root = process.cwd();
const tmp = path.join(process.env.TEMP || '/tmp', 'wa-review-suite-mutants');
const mutations = [
  {name: 's1-main-only-from-branch-again (lane block)', file: 'app.js',
    from: "{outcome:'main-only',state:ownCheckout ? 'no':'yes',",
    to: "{outcome:'main-only',state:lane.branch ? 'no':'yes',"},
  {name: 's2-adaptation-removed-again (budget check)', file: 'app.js',
    from: "if(!panePageBytes || !/invalid_session_byte_limit/.test(String(error.message))) throw error;",
    to: 'throw error;'},
  {name: 's3-one-lane-for-everything (lane block)', file: 'app.js',
    from: "const lane=task.lane || {key:UNRECORDED_LANE,label:UNRECORDED_LANE,checklist:[]};",
    to: "const lane={key:'one-lane',label:'one-lane',branch:'x',worktree:'',checklist:[]};"},
  {name: 's4-checklist-not-rendered (lane block)', file: 'components.js',
    from: "    for(const item of lane.checklist || []) {",
    to: "    for(const item of []) {"},
  {name: 's5-state-right-reason-wrong (lane block)', file: 'app.js',
    from: "      detail:ownCheckout ? 'this lane holds a checkout of its own ('+checkout+')'",
    to: "      detail:ownCheckout ? 'this lane holds no branch of its own: its children work in the node checkout'"},
  {name: 's6-lane-path-not-shown (lane block)', file: 'components.js',
    from: '    if(lane.worktree) {', to: '    if(false) {'},
  {name: 's7-production-refresh-stops-painting (seam)', file: 'app.js',
    from: '    if(painted!==pane.painted) {', to: '    if(false) {'},
  {name: 's2b-memo-only-changed (budget check control)', file: 'app.js',
    from: 'if(panePageBytes)request.byte_limit=panePageBytes;',
    to: 'request.byte_limit=40960;'}
];

const results = [];
for (const mutation of mutations) {
  const dir = path.join(tmp, mutation.name.split(' ')[0]);
  fs.rmSync(dir, {recursive: true, force: true});
  fs.mkdirSync(path.join(dir, 'scripts'), {recursive: true});
  fs.cpSync(path.join(root, 'ui'), path.join(dir, 'ui'), {recursive: true});
  fs.copyFileSync(path.join(root, 'scripts', 'test-ui.ps1'), path.join(dir, 'scripts', 'test-ui.ps1'));
  const target = path.join(dir, 'ui', mutation.file);
  const text = fs.readFileSync(target, 'utf8');
  if (!text.includes(mutation.from)) { results.push({mutation: mutation.name, error: 'pattern not found'}); continue; }
  fs.writeFileSync(target, text.replace(mutation.from, mutation.to));
  let output = '', status = 0;
  try {
    output = execFileSync('powershell',
      ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', path.join(dir, 'scripts', 'test-ui.ps1')],
      {cwd: dir, encoding: 'utf8', maxBuffer: 32 * 1024 * 1024, timeout: 600000, stdio: ['ignore', 'pipe', 'pipe']});
  } catch (error) {
    status = error.status ?? -1;
    output = String(error.stdout || '') + String(error.stderr || '');
  }
  const line = output.split(/\r?\n/).filter(text => text.trim()).slice(-1)[0] || '(no output)';
  results.push({mutation: mutation.name, exit: status, red: status !== 0 || /FAIL/.test(output),
    verdictLine: line.trim().slice(0, 220)});
}
console.log(JSON.stringify(results, null, 2));
