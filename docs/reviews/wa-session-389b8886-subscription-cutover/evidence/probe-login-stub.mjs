// Reviewer's never-authorizing stub for the device-login expiry path (did not author the delivery).
// The delivery's own mock authorises on the second poll, so it can never produce `flow_expired`;
// this one answers "authorization pending" forever, which is the only way to reach that branch.
// Usage: node probe-login-stub.mjs [--port 0]      prints `ready <port>` once listening.
import http from 'node:http';

const argv = process.argv.slice(2);
let port = 0;
for (let i = 0; i < argv.length; i += 1) {
  if (argv[i] === '--port') port = Number(argv[i + 1]);
}

const server = http.createServer((req, res) => {
  let body = '';
  req.on('data', (chunk) => { body += chunk; });
  req.on('end', () => {
    const url = new URL(req.url, 'http://127.0.0.1');
    if (url.pathname === '/api/accounts/deviceauth/usercode') {
      const payload = { device_auth_id: 'stub-device-auth', user_code: 'STUB-CODE-1', interval: 1 };
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify(payload));
      return;
    }
    if (url.pathname === '/api/accounts/deviceauth/token') {
      // always pending, never authorized
      res.writeHead(403, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ error: { code: 'deviceauth_authorization_pending' } }));
      return;
    }
    res.writeHead(404, { 'content-type': 'application/json' });
    res.end('{}');
  });
});

server.listen(port, '127.0.0.1', () => {
  process.stdout.write(`ready ${server.address().port}\n`);
});
