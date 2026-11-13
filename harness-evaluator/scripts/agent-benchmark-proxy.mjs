// The benchmark agents see only a dummy key. This forwarder adds the real key
// after their requests leave the disposable, internal-only Docker network.
import http from 'node:http';
import https from 'node:https';
import { fileURLToPath } from 'node:url';

export const DUMMY_KEY = 'benchmark-placeholder';
const ROUTE = '/zen/go/v1/';

export function createProxyServer({ apiKey, upstream = new URL('https://opencode.ai'),
  expectedKey = DUMMY_KEY } = {}) {
  if (!apiKey) throw new Error('BENCHMARK_PROXY_API_KEY is required');
  const transport = upstream.protocol === 'https:' ? https : upstream.protocol === 'http:' ? http : null;
  if (!transport) throw new Error('unsupported benchmark upstream protocol');
  return http.createServer((request, response) => {
    if (!request.url?.startsWith(ROUTE) || !['GET', 'POST'].includes(request.method)) {
      response.writeHead(404).end();
      return;
    }
    if (request.headers.authorization !== `Bearer ${expectedKey}`) {
      response.writeHead(401).end();
      return;
    }
    const headers = { ...request.headers, host: upstream.host,
      authorization: `Bearer ${apiKey}` };
    delete headers.connection;
    delete headers['proxy-connection'];
    const forwarded = transport.request(new URL(request.url, upstream), {
      method: request.method, headers,
    }, upstreamResponse => {
      response.writeHead(upstreamResponse.statusCode || 502, upstreamResponse.headers);
      upstreamResponse.pipe(response);
    });
    forwarded.on('error', () => {
      if (!response.headersSent) response.writeHead(502);
      response.end();
    });
    request.on('aborted', () => forwarded.destroy());
    request.pipe(forwarded);
  });
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  const server = createProxyServer({ apiKey: process.env.BENCHMARK_PROXY_API_KEY });
  server.listen(8080, '0.0.0.0');
  const lifetime = Number(process.env.BENCHMARK_PROXY_MAX_SECONDS || 900);
  setTimeout(() => server.close(), lifetime * 1000).unref();
}
