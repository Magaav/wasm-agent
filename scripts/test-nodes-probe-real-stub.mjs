// The stub rendezvous + ONE reachable peer (review r2, B: a real-wa row with a stub peer).
//
// Every other probe row stubs the HOST, so it never leaves the process. This one answers HTTP: /nodes
// publishes exactly one peer whose /node/call returns capabilities, and the node under test is the real
// `wa` binary. A probe path that is wrong on the wire - no owner, wait_s the host ignores, an await of an
// id this caller does not own - fails here and nowhere else.
import http from 'node:http';
import fs from 'node:fs';

const portFile = process.argv[2];
const nodeId = 'ab'.repeat(32);
const otherId = 'cd'.repeat(32);
let calls = 0;

const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://127.0.0.1');
  let body = '';
  req.on('data', (c) => { body += c; });
  req.on('end', () => {
    if (url.pathname === '/nodes') {
      // TWO peers: one answers, one 404s. The row asserts the reachable one is reported reachable and the
      // other names its refusal - a probe path that answers everything the same way fails here.
      res.setHeader('content-type', 'application/json');
      res.end(JSON.stringify({ nodes: [
        { node_id: nodeId, public_key: '11'.repeat(32), name: 'stub-peer', role: 'master', online: true, endpoints: [] },
        { node_id: otherId, public_key: '22'.repeat(32), name: 'dead-peer', role: 'master', online: true, endpoints: [] },
      ] }));
      return;
    }
    if (url.pathname === '/lookup') {
      const id = url.searchParams.get('node_id');
      res.setHeader('content-type', 'application/json');
      if (id === nodeId) {
        res.end(JSON.stringify({ node_id: nodeId, public_key: '11'.repeat(32), name: 'stub-peer', role: 'master' }));
      } else if (id === otherId) {
        res.statusCode = 404;
        res.end(JSON.stringify({ error: 'unknown_node' }));
      } else {
        res.statusCode = 404;
        res.end(JSON.stringify({ error: 'unknown_node' }));
      }
      return;
    }
    if (url.pathname === '/node/call') {
      calls += 1;
      res.setHeader('content-type', 'application/json');
      // The peer answers capabilities. This is the answer the row asserts comes back.
      res.end(JSON.stringify({ ok: true, status: 200, content: JSON.stringify({ capabilities: ['bash', 'read'], reason: 'asked' }) }));
      return;
    }
    res.statusCode = 404;
    res.end('{}');
  });
});
server.listen(0, '127.0.0.1', () => {
  fs.writeFileSync(portFile, String(server.address().port));
});
