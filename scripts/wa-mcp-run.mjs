#!/usr/bin/env node
// wa's `run`, as an MCP stdio server - so a CLI launched by wa's provider can call back into wa's sandbox
// (mission claude-inside-wa, part B, route 1, decision (a)).
//
// THE ONE TOOL IS `run`, AND ITS DESCRIPTION IS READ FROM THE PRODUCT, NOT RETYPED: `lua/core/raw_code.lua`
// (name + description) is the single source the model already sees, and a second copy here would be a
// model-facing change nobody approved.
//
// WHAT IT DOES NOT DO YET, and says so by name: execute. A child process has no path into wa's in-process
// codemode sandbox today (measured: `wa --help` lists no verb that runs a script; `run` exists only inside a
// turn). `tools/call` therefore answers `wa_run_unreachable` with the reason, instead of answering "ok" for
// something that did not run - the failure this factory keeps paying for is the cheerful fake, not the refusal.

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(HERE, '..');

// One source for the tool's name and words.
function runDescriptor() {
  const src = readFileSync(resolve(ROOT, 'lua/core/raw_code.lua'), 'utf8');
  const name = (src.match(/name\s*=\s*"([^"]+)"/) || [])[1] || 'run';
  const m = src.match(/description\s*=\s*"((?:[^"\\]|\\.)*)"/);
  const raw = m ? JSON.parse(`"${m[1]}"`) : '';
  // Lua builds this description by CONCATENATION across lines, so the first literal is only its beginning: every
  // one ends with `:` or a space. Serving that truncated sentence would change what the model reads about the tool
  // (the one thing this mission may not do), so an incomplete read is refused BY NAME instead of shipped.
  if (!raw || /[:\s]$/.test(raw)) {
    throw new Error(
      'wa_run_description_incomplete: lua/core/raw_code.lua builds the run description across several literals, ' +
        'and this server only read the first one - refusing rather than serving a shortened description of the tool.'
    );
  }
  return { name, description: raw };
}

function send(message) {
  process.stdout.write(JSON.stringify(message) + '\n');
}

function answer(id, result) {
  send({ jsonrpc: '2.0', id, result });
}

function fail(id, code, message) {
  send({ jsonrpc: '2.0', id, error: { code, message } });
}

let buffer = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (chunk) => {
  buffer += chunk;
  let index;
  while ((index = buffer.indexOf('\n')) >= 0) {
    const line = buffer.slice(0, index).trim();
    buffer = buffer.slice(index + 1);
    if (!line) continue;
    let request;
    try {
      request = JSON.parse(line);
    } catch {
      fail(null, -32700, 'parse_error');
      continue;
    }
    handle(request);
  }
});

function handle(request) {
  const { id, method, params } = request;
  if (method === 'initialize') {
    return answer(id, {
      protocolVersion: (params && params.protocolVersion) || '2024-11-05',
      capabilities: { tools: {} },
      serverInfo: { name: 'wa-run', version: '0.1.0' },
    });
  }
  if (method === 'notifications/initialized' || method === 'initialized') return; // a notification, no reply
  if (method === 'tools/list') {
    const { name, description } = runDescriptor();
    return answer(id, {
      tools: [
        {
          name,
          description,
          inputSchema: {
            type: 'object',
            properties: { code: { type: 'string', description: 'The script to run.' } },
            required: ['code'],
          },
        },
      ],
    });
  }
  if (method === 'tools/call') {
    const name = params && params.name;
    if (name !== runDescriptor().name) {
      return fail(id, -32602, `unknown_tool: ${name}`);
    }
    return answer(id, {
      isError: true,
      content: [
        {
          type: 'text',
          text:
            'wa_run_unreachable: a child process has no path into wa codemode sandbox today. `wa --help` lists no ' +
            'verb that runs a script, and `run` executes only inside a turn. The missing piece is wa-side (a local ' +
            'socket or a `wa run-script` verb); until it exists this tool refuses by name rather than answering ok ' +
            'for something that did not run.',
        },
      ],
    });
  }
  return fail(id, -32601, `method_not_found: ${method}`);
}
