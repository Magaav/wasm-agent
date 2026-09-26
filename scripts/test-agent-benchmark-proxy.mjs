#!/usr/bin/env node
// Prove that an agent-visible credential cannot become the upstream credential.
import assert from 'node:assert/strict';
import http from 'node:http';
import { once } from 'node:events';
import { createProxyServer, DUMMY_KEY } from './agent-benchmark-proxy.mjs';

const realKey = 'only-the-forwarder-knows-this-test-key';
let observed;
const upstream = http.createServer(async (request, response) => {
  let body = '';
  for await (const part of request) body += part;
  observed = { url: request.url, authorization: request.headers.authorization, body };
  response.writeHead(200, { 'content-type': 'text/event-stream' });
  response.write('data: first\n\n');
  response.end('data: second\n\n');
});
upstream.listen(0, '127.0.0.1');
await once(upstream, 'listening');
const proxy = createProxyServer({ apiKey: realKey,
  upstream: new URL(`http://127.0.0.1:${upstream.address().port}`) });
proxy.listen(0, '127.0.0.1');
await once(proxy, 'listening');
const base = `http://127.0.0.1:${proxy.address().port}`;
try {
  const response = await fetch(`${base}/zen/go/v1/chat/completions`, {
    method: 'POST', headers: { authorization: `Bearer ${DUMMY_KEY}` }, body: '{"model":"test"}',
  });
  assert.equal(response.status, 200);
  assert.equal(await response.text(), 'data: first\n\ndata: second\n\n');
  assert.deepEqual(observed, { url: '/zen/go/v1/chat/completions',
    authorization: `Bearer ${realKey}`, body: '{"model":"test"}' });
  assert.equal((await fetch(`${base}/zen/go/v1/models`)).status, 401);
  assert.equal((await fetch(`${base}/outside`, {
    headers: { authorization: `Bearer ${DUMMY_KEY}` },
  })).status, 404);
  console.log('benchmark proxy ok (credential isolated; stream preserved)');
} finally {
  proxy.close();
  upstream.close();
}
