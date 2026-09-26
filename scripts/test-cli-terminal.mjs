// Opt-in real Orca terminal test. Build wa first, then run this script.
// --activate additionally tests the resize when a background tab is activated.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';
import assert from 'node:assert/strict';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-cli-terminal-'));
const binary = path.join(root, 'rust', 'target', 'release', process.platform === 'win32' ? 'wa.exe' : 'wa');
const cli = process.env.ORCA_CLI_COMMAND || (process.env.ORCA_DEV_REPO_ROOT ? 'orca-dev' : process.platform === 'linux' ? 'orca-ide' : 'orca');
const verdict = path.join(scratch, 'verdict.json');
const handles = [];
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
function orca(...args) {
  const result = spawnSync(cli, [...args, '--json'], {encoding:'utf8', windowsHide:true, timeout:15000});
  if (result.error) throw result.error;
  const payload = JSON.parse(result.stdout);
  assert(payload.ok, JSON.stringify(payload.error));
  return payload.result;
}
async function stage(name, timeout = 30000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    if (fs.existsSync(verdict)) {
      const data = JSON.parse(fs.readFileSync(verdict, 'utf8'));
      if (data.stage === name) return data;
    }
    await pause(100);
  }
  throw Error(`terminal did not reach ${name}; evidence: ${scratch}`);
}
function frame(handle, name) {
  const result = orca('terminal', 'read', '--terminal', handle, '--screen');
  fs.writeFileSync(path.join(scratch, `${name}.json`), JSON.stringify(result, null, 2));
  const lines = result.terminal.tail;
  assert(lines.some(line => line.trim() === '> draft'), `${name}: first draft row missing`);
  assert(lines.some(line => line.trim() === 'kept'), `${name}: second draft row missing`);
  const footer = lines.at(-1);
  for (const value of ['6 rounds', '1 tool', '120.4k', 'CH75.2%', 'ctx 10.0%/272.0k'])
    assert(footer.includes(value), `${name}: footer missing ${value}: ${footer}`);
  return lines;
}
try {
  assert(fs.existsSync(binary), `build ${binary} first`);
  const environment = {
    WASM_AGENT_HOME:path.join(scratch, 'home'), WASM_AGENT_LUA_ROOT:root,
    WA_SCRIPT:path.join(root, 'scripts', 'test-cli-terminal.lua'), WA_CLI_PROBE_OUT:verdict,
  };
  const launcher = path.join(scratch, process.platform === 'win32' ? 'probe.cmd' : 'probe.sh');
  const quote = value => `'${value.replaceAll("'", "'\\''")}'`;
  fs.writeFileSync(launcher, process.platform === 'win32'
    ? '@echo off\r\n' + Object.entries(environment).map(([key,value]) => `set "${key}=${value}"\r\n`).join('') + `"${binary}"\r\n`
    : '#!/bin/sh\n' + Object.entries(environment).map(([key,value]) => `export ${key}=${quote(value)}\n`).join('') + `exec ${quote(binary)}\n`, {mode:0o700});
  const created = orca('terminal', 'create', '--worktree', `path:${root}`, '--title', 'CLI CONTRACT PROBE', '--command', launcher);
  const handle = created.terminal.handle;
  handles.push(handle);
  await stage('ready'); // Sending before raw input is ready tests the launcher, not the editor.
  orca('terminal', 'send', '--terminal', handle, '--text', 'first\x1b\rsecond', '--enter');
  await stage('running');
  orca('terminal', 'send', '--terminal', handle, '--text', 'draft\x1b\rkept');
  if (process.argv.includes('--activate')) orca('terminal', 'switch', '--terminal', handle);
  await pause(2000);
  frame(handle, 'running');
  await stage('idle');
  const lines = frame(handle, 'idle');
  assert(lines.some(line => line.includes('Rendered answer')), 'rendered heading missing');
  assert(!lines.some(line => line.includes('## Rendered answer')), 'raw Markdown heading');
  assert(lines.some(line => line.includes('│') && line.includes("print('proof')")), 'code block missing');
  orca('terminal', 'send', '--terminal', handle, '--enter');
  const settled = await stage('pass');
  assert.equal(settled.text, 'draft\nkept');
  console.log(`CLI terminal PASS: multiline input, draft survives blocked output, Markdown, running/idle footer${process.argv.includes('--activate') ? ', tab resize' : ''}; evidence: ${scratch}`);
} finally {
  for (const handle of handles) orca('terminal', 'close', '--terminal', handle);
}
