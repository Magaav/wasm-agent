// The MCP runtime a node spawns is one list, in four places: lua/core/mcp.lua (M.RUNTIME, what a node
// accepts as complete), scripts/install.sh and scripts/install.ps1 (what a fresh node gets) and
// scripts/deploy.sh (what every deploy ships). On 28/10 a node used a stale partial copy and every
// web_search died importing web-core.mjs. This fails when any list, or the real import graph, drifts.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
// fileURLToPath, not URL.pathname: on Windows the pathname is /C:/..., which resolves to C:\C:\... (30/10).
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const read = (file) => fs.readFileSync(path.join(root, file), 'utf8');
const sorted = (list) => [...new Set(list)].sort();

function closure(entries) {
  const seen = new Set();
  const walk = (file) => {
    if (seen.has(file)) return;
    seen.add(file);
    const source = read(path.join('scripts', file));
    for (const m of source.matchAll(/(?:from\s*|import\s*\(\s*|import\s+)["'](\.\/[^"']+)["']/g)) walk(m[1].slice(2));
  };
  entries.forEach(walk);
  return sorted([...seen]);
}

test('every MCP runtime list is the real import closure of the servers the node spawns', () => {
  const lua = sorted([...read('lua/core/mcp.lua').match(/M\.RUNTIME=\{([^}]*)\}/)[1].matchAll(/'([^']+)'/g)].map((m) => m[1]));
  const sh = sorted(read('scripts/install.sh').match(/MCP_RUNTIME="([^"]+)"/)[1].split(/\s+/));
  const ps = sorted([...read('scripts/install.ps1').matchAll(/"((?:mcp|web)[\w-]*\.mjs)"/g)].map((m) => m[1]));
  const deploy = read('scripts/deploy.sh');
  const deployData = sorted(deploy.match(/MCP_RUNTIME="([^"]+)"/)[1].split(/\s+/));
  const graph = closure(['mcp-client.mjs', 'mcp-session.mjs', 'mcp-web.mjs', 'mcp-whatsapp.mjs', 'mcp-mail.mjs']);
  assert.deepEqual(lua, graph, 'lua/core/mcp.lua M.RUNTIME');
  assert.deepEqual(sh, graph, 'scripts/install.sh MCP_RUNTIME');
  assert.deepEqual(deployData, graph, 'scripts/deploy.sh MCP_RUNTIME (the data-directory copy)');
  for (const file of graph) {
    assert.ok(ps.includes(file), `scripts/install.ps1 ships ${file}`);
    // The install copy: an explicit line, or the mcp-*.mjs glob of the pipeline block.
    assert.ok(deploy.includes(`scripts/${file}"`) || (file.startsWith('mcp-') && deploy.includes('"$ROOT"/scripts/mcp-*.mjs')),
      `scripts/deploy.sh ships ${file} into the install`);
  }
});
