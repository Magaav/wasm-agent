#!/usr/bin/env node
// Fake node: /subagents from a spec file, /health, /chat appending every submitted wake to a file.
const fs = require('node:fs'); const http = require('node:http');
const server = http.createServer((request, response) => {
  let body = ''; request.on('data', (c) => { body += c; });
  request.on('end', () => {
    const spec = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
    if (request.url === '/health') { response.setHeader('content-type', 'application/json'); response.end(JSON.stringify({ok: true, current: null})); return; }
    if (request.url === '/chat') { const p = JSON.parse(body);
      fs.appendFileSync(process.argv[4], JSON.stringify({thread: p.thread, text: p.text}) + '\n');
      response.writeHead(200, {'Content-Type': 'text/event-stream'}); response.end('data: {"type":"reply","text":"fixture"}\n\ndata: {"type":"done"}\n\n'); return; }
    if (request.url === '/subagents') { const call = body ? JSON.parse(body) : {};
      response.setHeader('content-type', 'application/json');
      if ((call.action || 'list') === 'list') { response.end(JSON.stringify({subagents: spec.map((c) => c.task)})); return; }
      const found = spec.find((c) => c.task.subagent_id === call.id);
      if (!found) { response.end(JSON.stringify({error: 'unknown_subagent'})); return; }
      response.end(JSON.stringify({...found.task, completion: found.completion})); return; }
    response.writeHead(404); response.end();
  });
});
server.listen(0, '127.0.0.1', () => { fs.writeFileSync(process.argv[3], String(server.address().port)); process.stdout.write('listening\n'); });
