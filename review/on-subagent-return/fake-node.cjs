#!/usr/bin/env node
// A fake /subagents endpoint for the review probe: it serves exactly the children in the spec file, so
// scripts/subagent-return-hook.mjs --observe runs its real code path (list -> status -> measure -> payload).
const fs = require('node:fs');
const http = require('node:http');
const spec = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const server = http.createServer((request, response) => {
  let body = '';
  request.on('data', (chunk) => { body += chunk; });
  request.on('end', () => {
    response.setHeader('content-type', 'application/json');
    if (request.url === '/subagents') {
      const call = body ? JSON.parse(body) : {};
      if ((call.action || 'list') === 'list') {
        response.end(JSON.stringify({subagents: spec.map((c) => c.task)}));
        return;
      }
      const found = spec.find((c) => c.task.subagent_id === call.id);
      if (!found) { response.end(JSON.stringify({error: 'unknown_subagent'})); return; }
      response.end(JSON.stringify({...found.task, completion: found.completion}));
      return;
    }
    response.writeHead(404); response.end();
  });
});
server.listen(0, '127.0.0.1', () => {
  fs.writeFileSync(process.argv[3], String(server.address().port));
  process.stdout.write(`listening ${server.address().port}\n`);
});
