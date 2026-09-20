// Deterministic, localhost-only fixture. Never contacts a real provider.
const http = require('node:http');
const fs = require('node:fs');
const server = http.createServer((req, res) => {
  let body = '';
  req.on('data', part => { body += part; });
  req.on('end', () => {
    if (req.headers.authorization !== 'Bearer fixture-key') {
      res.writeHead(401, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ error: 'fixture-key must never appear in diagnostics' }));
      return;
    }
    let input;
    try { input = JSON.parse(body); } catch { res.writeHead(400); res.end(); return; }
    let message = { role: 'assistant', content: 'OK' };
    let reason = 'stop';
    const ask = input.messages.find(m => m.role === 'user' && typeof m.content === 'string' && m.content.startsWith('FIXTURE_WRITE|'));
    if (ask && !input.messages.some(m => m.role === 'tool')) {
      const [, path, content] = ask.content.split('|');
      message = { role: 'assistant', content: '', tool_calls: [{
        id: 'fixture-write', type: 'function',
        function: { name: 'write', arguments: JSON.stringify({ path, content }) },
      }] };
      reason = 'tool_calls';
    }
    const usage = { prompt_tokens: 10, completion_tokens: 4, total_tokens: 14 };
    if (input.stream) {
      const delta = message.tool_calls
        ? { tool_calls: message.tool_calls.map((call, index) => ({ index, ...call })) }
        : { content: message.content };
      res.writeHead(200, { 'content-type': 'text/event-stream' });
      res.end('data: ' + JSON.stringify({ id: 'fixture', choices: [{ delta, finish_reason: reason }], usage }) + '\n\ndata: [DONE]\n\n');
    } else {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ id: 'fixture', choices: [{ message, finish_reason: reason }], usage }));
    }
  });
});
server.listen(0, '127.0.0.1', () => fs.writeFileSync(process.argv[2], String(server.address().port)));
