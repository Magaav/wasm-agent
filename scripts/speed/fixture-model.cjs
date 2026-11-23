#!/usr/bin/env node
// THE MODEL THE SPEED BOARD MEASURES AGAINST: one loopback process, no upstream, no credential.
//
// The first-token row is "Enter -> the first byte the model sends back", and only the model can time its
// own first byte. So this fixture answers an OpenAI-shaped request at once - it writes the first SSE
// chunk before it does anything else - and appends one line per request with the WALL clock at the
// moment the request arrived and the moment its first byte left: same machine, same clock as the probe,
// so the probe subtracts them and keeps no clock of its own to be wrong about.
//
// It never contacts anything: no upstream request, no key (any non-empty key is accepted and never
// logged), and it listens on 127.0.0.1 only. Its log line carries no prompt text.
//
//   node scripts/speed/fixture-model.cjs --log <file>     (prints "port <n>" on stdout, then serves)
'use strict';
const http = require('node:http');
const fs = require('node:fs');

function arg(name) {
  const index = process.argv.indexOf(name);
  return index > 0 ? process.argv[index + 1] : '';
}
const log_path = arg('--log');

function record(entry) {
  if (!log_path) return;
  try { fs.appendFileSync(log_path, JSON.stringify(entry) + '\n'); } catch { /* a log that cannot be written is not a data path */ }
}

const server = http.createServer((req, res) => {
  if (req.method === 'GET') { res.writeHead(200, { 'content-type': 'application/json' }); res.end('{"ok":true}'); return; }
  const received = Date.now();
  let body = '';
  req.on('data', part => { body += part; });
  req.on('end', () => {
    let input = {};
    try { input = JSON.parse(body || '{}'); } catch { input = {}; }
    const stream = input.stream === true;
    const text = 'fixture reply';
    if (!stream) {
      record({ received_ms: received, first_byte_ms: Date.now(), stream: false });
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ id: 'chatcmpl-fixture', object: 'chat.completion', model: input.model || 'fixture',
        choices: [{ index: 0, message: { role: 'assistant', content: text }, finish_reason: 'stop' }] }));
      return;
    }
    res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache', connection: 'keep-alive' });
    // THE FIRST BYTE FIRST: nothing is computed before it, so what this row measures is the route's cost
    // and not the fixture's thinking.
    res.write('data: ' + JSON.stringify({ id: 'chatcmpl-fixture', object: 'chat.completion.chunk',
      choices: [{ index: 0, delta: { role: 'assistant', content: 'fi' }, finish_reason: null }] }) + '\n\n');
    record({ received_ms: received, first_byte_ms: Date.now(), stream: true });
    res.write('data: ' + JSON.stringify({ id: 'chatcmpl-fixture', object: 'chat.completion.chunk',
      choices: [{ index: 0, delta: { content: 'xture' }, finish_reason: null }] }) + '\n\n');
    res.write('data: ' + JSON.stringify({ id: 'chatcmpl-fixture', object: 'chat.completion.chunk',
      choices: [{ index: 0, delta: {}, finish_reason: 'stop' }] }) + '\n\n');
    res.write('data: [DONE]\n\n');
    res.end();
  });
});

server.listen(0, '127.0.0.1', () => {
  process.stdout.write('port ' + server.address().port + '\n');
});
