// Fixed TCP forwarder for benchmark model traffic. No agent code runs here.
// Agents reach this container as opencode.ai on an internal-only Docker network.
import net from 'node:net';

const server = net.createServer(client => {
  const upstream = net.connect({ host: 'opencode.ai', port: 443 });
  client.pipe(upstream);
  upstream.pipe(client);
  client.on('error', () => upstream.destroy());
  upstream.on('error', () => client.destroy());
  client.on('close', () => upstream.destroy());
  upstream.on('close', () => client.destroy());
});
server.listen(443, '0.0.0.0');
const lifetime = Number(process.env.BENCHMARK_PROXY_MAX_SECONDS || 900);
setTimeout(() => server.close(), lifetime * 1000).unref();
