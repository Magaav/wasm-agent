// A loopback stand-in for wa-vault's node-side door, so the vault seam can be measured without a
// vault: /status answers the presence-only body lua/core/vault.lua:47 expects.
//
//   node scripts/bench-seams-vault-stub.mjs <port>
//
// It answers one shape and nothing else, on 127.0.0.1 only, and prints the port it bound.
import http from 'node:http';
const port = Number(process.argv[2] || 0);
const body = JSON.stringify({ providers: { 'opencode-go': { configured: true, enabled: true } } });
const server = http.createServer((req, res) => {
  if (req.url === '/status') {
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(body);
    return;
  }
  res.writeHead(404, { 'content-type': 'application/json' });
  res.end(JSON.stringify({ error: { code: 'not_found', message: 'bench stub answers /status only' } }));
});
server.listen(port, '127.0.0.1', () => {
  process.stdout.write(String(server.address().port) + '\n');
});
