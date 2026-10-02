#!/usr/bin/env node
// Falsification controls for the reviewer's probe: "a check that never runs and a check that passes
// look identical". Each mutation reverts ONE thing this delivery introduced, in a disposable copy of
// ui/ (never the repository's ui/), and my probe must report the matching failure. A mutation that
// produces no failure means the probe is blind to that claim and the pass is worthless.
import fs from 'node:fs';
import path from 'node:path';
import {execFileSync} from 'node:child_process';

const root = process.cwd();
const tmp = path.join(process.env.TEMP || '/tmp', 'wa-review-mutants');
const mutations = [
  {name: 'canvas-floor-250 (claim 1)', expect: /readable transcript height|keep a real box/,
    file: 'style.css', from: 'grid-auto-rows:minmax(360px,1fr)', to: 'grid-auto-rows:minmax(250px,1fr)'},
  {name: 'header-wrap-clip (claim 2)', expect: /must not clip the header vertically|ellipsized/,
    file: 'style.css',
    from: '.agent-pane-head { padding:var(--space); flex-wrap:nowrap; max-height:44px; overflow:hidden; }',
    to: '.agent-pane-head { padding:var(--space); flex-wrap:wrap; max-height:44px; overflow:hidden; }'},
  {name: 'header-no-ellipsis (claim 2)', expect: /ellipsized/,
    file: 'style.css',
    from: '.agent-pane-head strong { flex:none; max-width:45%; overflow:hidden; white-space:nowrap; text-overflow:ellipsis; }',
    to: '.agent-pane-head strong { flex:none; max-width:45%; overflow:hidden; }'},
  {name: 'action-row-31px (claim 3)', expect: /height of the append-file control/,
    file: 'style.css', from: 'height:30px; padding:0 var(--pad)', to: 'height:31px; padding:0 var(--pad)'},
  {name: 'pane-only-artifacts (claim 4)', expect: /Earlier messages|restate completion/,
    file: 'components.js', from: "+ '</header>';",
    to: "+ '</header><button type=\"button\" class=\"agent-earlier\" hidden>Earlier messages</button>';"},
  {name: 'lane-key-ignored (claim 5)', expect: /lanes must be keyed|must hold its own children/,
    file: 'app.js',
    from: "const key=String(session.workspace_branch || '') || String(session.worktree || '') || MAIN_LANE;",
    to: "const key=MAIN_LANE;"}
];

const results = [];
for (const mutation of mutations) {
  const dir = path.join(tmp, mutation.name.split(' ')[0]);
  fs.rmSync(dir, {recursive: true, force: true});
  fs.mkdirSync(dir, {recursive: true});
  fs.cpSync(path.join(root, 'ui'), dir, {recursive: true});
  const target = path.join(dir, mutation.file);
  const text = fs.readFileSync(target, 'utf8');
  if (!text.includes(mutation.from)) { results.push({mutation: mutation.name, error: 'pattern not found'}); continue; }
  fs.writeFileSync(target, text.replace(mutation.from, mutation.to));
  let payload;
  try {
    const raw = execFileSync(process.execPath,
      ['review/ui-subagent-chat/observe.mjs', '--ui', dir, '--probe', 'review/ui-subagent-chat/probe-claims.js',
        '--out', path.join(tmp, 'out-' + mutation.name.split(' ')[0]), '--window', '1280x900', '--scale', '1', '--allow-fail'],
      {cwd: root, encoding: 'utf8', maxBuffer: 32 * 1024 * 1024, timeout: 300000});
    payload = JSON.parse(raw.slice(raw.indexOf('{')));
  } catch (error) {
    results.push({mutation: mutation.name, error: String(error.message).slice(0, 200)});
    continue;
  }
  const text2 = payload.probeText || '';
  const failures = (text2.split('| FAILURES: ')[1] || '').split(' || FACTS')[0];
  results.push({mutation: mutation.name, status: payload.probeStatus,
    caught: mutation.expect.test(failures),
    failures: failures.split(' ;; ').map(line => line.slice(0, 150))});
}
console.log(JSON.stringify(results, null, 2));
