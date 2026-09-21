// Local provider fixture for the foreground cancellation test.
//
//   node scripts/mock-provider-silent.cjs <port>
//
// It answers in three shapes, chosen by a marker in the request body:
//
//   SILENT-HEADERS  accept the request, send nothing at all - the client is
//                   blocked waiting for response headers
//   SILENT-BODY     send the response headers, then no body bytes - the client
//                   is blocked reading the body
//   DELAYED         a healthy 2.5s pause before the first token, then a normal
//                   answer, so a cancellation mechanism that polls with a tiny
//                   read timeout would wrongly cut a healthy run short
//
// Any other request echoes the last `RUN-MARKER-<word>` token, the way the
// isolation fixture does, so a resumed/queued run is identifiable by content.
const http = require('node:http');

const port = Number(process.argv[2]);
let calls = 0;
let silentHeaders = 0;
let silentBody = 0;
let delayed = 0;

const server = http.createServer((req, res) => {
  if (req.method === 'GET') {
    if (req.url === '/calls') {
      res.setHeader('content-type', 'application/json');
      res.end(JSON.stringify({ calls, headers: silentHeaders, body: silentBody, delayed }));
      return;
    }
    res.end('ready');
    return;
  }
  let body = '';
  req.on('data', (chunk) => { body += chunk; });
  req.on('end', () => {
    calls += 1;
    // The marker of the *current* turn is the last one: the conversation history
    // is sent too, so an earlier turn's marker must not decide this response.
    const markers = body.match(/RUN-MARKER-[A-Za-z0-9-]+/g) || [];
    const marker = markers.length ? markers[markers.length - 1] : 'RUN-MARKER-ok';
    if (marker === 'RUN-MARKER-SILENT-HEADERS') {
      silentHeaders += 1;
      // Accept and say nothing: the read that must be interruptible is the one
      // waiting for the response headers.
      return;
    }
    if (marker === 'RUN-MARKER-SILENT-BODY') {
      silentBody += 1;
      res.writeHead(200, { 'content-type': 'text/event-stream' });
      res.flushHeaders();
      // Headers are out; no body bytes follow.
      return;
    }
    const delay = marker === 'RUN-MARKER-DELAYED' ? 2500 : 0;
    if (delay) delayed += 1;
    setTimeout(() => {
      if (res.writableEnded) return;
      res.writeHead(200, { 'content-type': 'text/event-stream' });
      const usage = { prompt_tokens: 10, completion_tokens: marker.length, total_tokens: 10 + marker.length };
      res.write('data: ' + JSON.stringify({ id: 'mock', choices: [{ delta: { content: marker }, finish_reason: null }] }) + '\n\n');
      res.write('data: ' + JSON.stringify({ id: 'mock', choices: [{ delta: {}, finish_reason: 'stop' }], usage }) + '\n\n');
      res.write('data: [DONE]\n\n');
      res.end();
    }, delay);
  });
});

server.listen(port, '127.0.0.1');
