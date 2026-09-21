// Local, credential-free provider for the run-isolation tests.
//
//   node scripts/mock-provider-isolation.cjs <port>
//
// Two properties the shared `mock-provider.cjs` deliberately does not have, because its 12s
// hold is what keeps the older concurrency fixture's health probes meaningful:
//
//   * it echoes `RUN-MARKER-<word>` from the request, so two overlapping runs are told apart by
//     their *content* rather than only by counting events - a cross-contaminated stream is
//     caught even if both runs happen to emit the same number of lines;
//   * it holds briefly and then streams one character at a time, so the two streams genuinely
//     interleave. A sink shared between runs is then visible as one stream carrying the other's
//     characters, not merely as a duplicated `done`.
const http = require('node:http');

const port = Number(process.argv[2]);
const holdMs = Number(process.env.MOCK_HOLD_MS || 1200);
const chunkMs = Number(process.env.MOCK_CHUNK_MS || 25);

const server = http.createServer((req, res) => {
  if (req.method === 'GET') { res.end('ready'); return; }
  let body = '';
  req.on('data', (chunk) => { body += chunk; });
  req.on('end', () => {
    // The marker travels in the user message, which is part of the prompt the node sends. The
    // conversation history is sent too, so take the *last* marker: that is the current user turn.
    const markers = body.match(/RUN-MARKER-[A-Za-z0-9]+/g) || [];
    const marker = markers.length ? markers[markers.length - 1] : 'ok';
    setTimeout(() => {
      res.writeHead(200, { 'content-type': 'text/event-stream' });
      let index = 0;
      const tick = () => {
        if (index < marker.length) {
          const delta = { id: 'mock-request', choices: [{ delta: { content: marker[index] }, finish_reason: null }] };
          res.write('data: ' + JSON.stringify(delta) + '\n\n');
          index += 1;
          setTimeout(tick, chunkMs);
          return;
        }
        const usage = {
          prompt_tokens: 10,
          completion_tokens: marker.length,
          total_tokens: 10 + marker.length,
          prompt_tokens_details: { cached_tokens: 0 },
        };
        const stop = { id: 'mock-request', choices: [{ delta: {}, finish_reason: 'stop' }], usage };
        res.write('data: ' + JSON.stringify(stop) + '\n\n');
        res.write('data: [DONE]\n\n');
        res.end();
      };
      tick();
    }, holdMs);
  });
});

server.listen(port, '127.0.0.1');
