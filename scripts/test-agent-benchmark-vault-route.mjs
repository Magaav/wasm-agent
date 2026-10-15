// Real vault implementation, fake provider and synthetic secrets ONLY. No solver inference.
import fs from 'node:fs';
import path from 'node:path';
import http from 'node:http';
import cp from 'node:child_process';
import crypto from 'node:crypto';
import zlib from 'node:zlib';
import assert from 'node:assert/strict';
import {fileURLToPath} from 'node:url';
import {createVaultSubscriptionRoute, responseUsage, readModelRouteJournal} from './agent-benchmark-model-route.mjs';
import {isolatedEnvironment} from './agent-benchmark-environment.mjs';
const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const [out] = process.argv.slice(2);
assert(out && path.isAbsolute(out) && !fs.existsSync(out), 'fresh evidence root required');
fs.mkdirSync(out, {recursive: true});
const wait = ms => new Promise(r => setTimeout(r, ms));
const digest = b => crypto.createHash('sha256').update(b).digest('hex');
let checks = 0;
const check = (value, note) => { assert(value, note); checks++; };
const observed = [], routes = [], streams = new Set();
let redirectHits = 0;
const trap = http.createServer((req, res) => { redirectHits++; res.end('redirect should never arrive'); });
await new Promise(r => trap.listen(0, '127.0.0.1', r));
const terminal = {type: 'response.completed', response: {status: 'completed', usage: {
  input_tokens: 100, output_tokens: 20, input_tokens_details: {cached_tokens: 40}, output_tokens_details: {reasoning_tokens: 5}}}};
const provider = http.createServer(async (req, res) => {
  const chunks = []; for await (const b of req) chunks.push(b);
  const raw = Buffer.concat(chunks), body = JSON.parse(raw);
  observed.push({path: req.url, headers: req.headers, body, wire_sha256: digest(raw)});
  const behavior = body.input[0]?.content;
  if (behavior === 'redirect') { res.writeHead(307, {location: 'http://127.0.0.1:' + trap.address().port + '/steal'}); res.end('redirect retained'); return; }
  if (behavior === 'http-error') { res.writeHead(503); res.end('synthetic provider unavailable'); return; }
  res.writeHead(200, {'content-type': 'text/event-stream', 'set-cookie': 'never-forward=1'});
  if (behavior === 'heartbeat' || behavior === 'abandon' || behavior === 'partial') {
    res.write(': observed-prefix\n\n');
    const timer = setInterval(() => res.write(': heartbeat\n\n'), 15); streams.add(timer);
    res.on('close', () => { clearInterval(timer); streams.delete(timer); });
    if (behavior === 'partial') setTimeout(() => res.destroy(), 45);
    return;
  }
  if (behavior === 'incomplete') { res.end('data: {"type":"response.incomplete"}\n\n'); return; }
  const event = structuredClone(terminal);
  if (behavior === 'missing-usage') delete event.response.usage;
  if (behavior === 'bad-usage') event.response.usage.input_tokens_details.cached_tokens = 101;
  if (behavior === 'huge') { res.end(Buffer.alloc(33 * 1024 * 1024, 120)); return; }
  const wire = Buffer.from('data: ' + JSON.stringify(event) + '\n\n');
  res.end(wire);
});
await new Promise(r => provider.listen(0, '127.0.0.1', r));
const python = process.env.WA_BENCHMARK_PYTHON || (process.platform === 'win32' ? 'python' : 'python3');
const child = cp.spawn(python, ['-B', path.join(repo, 'scripts/fixtures/benchmark-vault.py'), path.join(repo, 'vault/wa_vault.py'),
  path.join(out, 'vault-data'), 'http://127.0.0.1:' + provider.address().port], {
  env: isolatedEnvironment(out), stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true});
let stdout = '', stderr = '';
child.stdout.on('data', b => stdout += b); child.stderr.on('data', b => stderr += b);
const closed = new Promise(resolve => { child.on('error', error => resolve({error: error.code})); child.on('close', (code, signal) => resolve({code, signal})); });
let ready;
try {
  for (let n = 0; n < 200; n++) { try { ready = JSON.parse(stdout.trim().split(/\r?\n/)[0]); } catch {} if (ready) break; await wait(10); }
  assert(ready?.synthetic_only, 'actual synthetic vault ready: ' + stderr);
  const vaultUrl = 'http://127.0.0.1:' + ready.port;
  check((await (await fetch(vaultUrl + '/status')).json()).providers['openai-sub'].configured, 'actual vault is configured');
  function arm(name, extra = {}) { return {arm: name, handle: crypto.randomBytes(32).toString('hex'), maxRequests: 8,
    maxPromptTotal: 1000, maxOutputTotal: 1000, maxMilliseconds: 10000, ...extra}; }
  async function make(name, arms, endpoint = vaultUrl) {
    const route = createVaultSubscriptionRoute({vaultUrl: endpoint, root: path.join(out, name), arms});
    await new Promise(r => route.server.listen(0, '127.0.0.1', r)); routes.push(route);
    const url = a => 'http://127.0.0.1:' + route.server.address().port + '/arms/' + a.handle + '/openai-sub/codex/responses';
    return {route, url};
  }
  const body = content => ({model: 'gpt-6.1-sol', reasoning: {effort: 'low'}, stream: true,
    input: [{role: 'user', content}], tools: [], prompt_cache_key: 'caller-controlled'});
  const send = (url, value, headers = {}) => fetch(url, {method: 'POST', headers: {'content-type': 'application/json', ...headers}, body: JSON.stringify(value)});
  const arms = ['pi', 'wasm-current', 'node-v1', 'rust-v2'].map(n => arm(n));
  const {route, url} = await make('common', arms);
  for (const a of arms) {
    const data = Buffer.from(JSON.stringify(body('normal'))), compressed = zlib.zstdCompressSync(data);
    const response = await fetch(url(a), {method: 'POST', headers: {'content-encoding': 'zstd',
      authorization: 'Bearer CALLER_SECRET', cookie: 'CALLER_COOKIE', host: 'caller.invalid',
      'chatgpt-account-id': 'CALLER_ACCOUNT', 'x-vault-token': 'CALLER_ADMIN', 'x-forwarded-host': 'evil.invalid'}, body: compressed});
    check(response.status === 200 && (await response.text()).includes('response.completed'), 'each arm traverses actual vault');
    check(!response.headers.has('set-cookie') && !response.headers.has('location'), 'unsafe response headers absent');
    const attempt = route.inspect().find(s => s.arm === a.arm).attempts[0];
    check(fs.readFileSync(path.join(out, 'common', attempt.client_wire.name)).equals(compressed), 'original compressed wire exact');
    check(fs.readFileSync(path.join(out, 'common', attempt.client.name)).equals(data), 'decoded bytes exact');
    check(attempt.prepared.sha256 === observed.at(-1).wire_sha256, 'vault forwards prepared request bytes unchanged');
  }
  check(observed.length === 4 && observed.every(r => r.path === '/codex/responses'), 'fixed subscription upstream path');
  check(observed.every(r => r.headers.authorization === 'Bearer BENCHMARK_SYNTHETIC_ACCESS_ONLY'
    && r.headers['chatgpt-account-id'] === 'benchmark-synthetic-account' && !r.headers.cookie && !r.headers['x-vault-token']
    && !r.headers['x-forwarded-host'] && r.headers.host === '127.0.0.1:' + provider.address().port), 'vault owns credentials, host and identity');
  check(observed.every(r => r.headers.originator === 'codex-cli' && r.headers['user-agent'] === 'codex-cli'
    && r.headers['openai-beta'] === 'responses=experimental' && r.headers['session-id'] === r.headers.session_id
    && r.headers['x-client-request-id'] === r.headers.session_id), 'fixed measured subscription headers for every arm');
  check(new Set(observed.map(r => r.body.prompt_cache_key)).size === 4
    && observed.every(r => r.body.prompt_cache_key === r.headers.session_id && r.body.prompt_cache_key !== 'caller-controlled'), 'arm-specific session/cache scopes');
  const usage = route.inspect()[0].attempts[0].usage;
  check(usage.prompt_total === 100 && usage.uncached_input === 60 && usage.cache_read === 40 && usage.output === 20 && usage.reasoning === 5 && usage.cache_write === null, 'disjoint usage, reasoning is output subset');
  check(route.inspect().every(s => s.actual_cost === null) && !route.paid_ready, 'subscription dollars unknown and CLI admission not granted');
  for (const value of [{...body('normal'), model: 'wrong'}, {...body('normal'), reasoning: {effort: 'high'}}, {...body('normal'), previous_response_id: 'hidden-history'}]) {
    const n = observed.length; check((await send(url(arms[0]), value)).status === 400 && observed.length === n, 'pin/continuation drift refused before vault');
  }
  for (const suffix of ['?upstream=evil', '/../status', '/login', '/wham/usage']) {
    check((await fetch(url(arms[0]) + suffix, {method: 'POST', body: '{}'})).status === 404, 'no alternate route/admin/query surface');
  }
  for (const behavior of ['redirect', 'http-error', 'partial', 'incomplete', 'missing-usage', 'bad-usage', 'huge']) {
    const a = arm(behavior), x = await make(behavior, [a]);
    const response = await send(x.url(a), body(behavior)); await response.text(); await wait(30);
    const s = x.route.inspect()[0], attempt = s.attempts[0], n = observed.length;
    check(s.halted && s.unknown_usage === 1 && s.provider_attempts === 1 && attempt.usage === null, behavior + ': unknown usage halted');
    check(attempt.response.bytes > 0, behavior + ': observed response retained');
    check((await send(x.url(a), body('normal'))).status === 429 && observed.length === n, behavior + ': no replay');
    check(x.route.events.filter(e => e.phase === 'end' && e.id === attempt.id).length === 1, behavior + ': finalized once');
  }
  check(redirectHits === 0, 'neither vault nor relay follows redirects');
  const h = arm('heartbeat', {maxMilliseconds: 2000, maxRequestMilliseconds: 180}), heartbeat = await make('deadline', [h]);
  const before = performance.now(); await (await send(heartbeat.url(h), body('heartbeat'))).text();
  const hs = heartbeat.route.inspect()[0];
  check(performance.now() - before < 1500 && hs.attempts[0].termination === 'stream_deadline', 'absolute stream deadline not extended by heartbeat');
  check(hs.halted && hs.attempts[0].response.bytes > 0, 'deadline retains partial response and unknown usage');

  const u = arm('upload', {maxMilliseconds: 3000, maxRequestMilliseconds: 180}), upload = await make('upload', [u]);
  const partial = Buffer.from('{"model":"gpt-6.1-sol",');
  const raw = http.request(upload.url(u), {method: 'POST', headers: {'content-length': 1000}});
  raw.on('error', () => {}); raw.on('response', r => r.resume()); raw.write(partial);
  await wait(30); const n = observed.length;
  check((await send(upload.url(u), body('normal'))).status === 409, 'upload reserves inflight before awaiting bytes');
  const trickle = setInterval(() => raw.write(' '), 15); await wait(240); clearInterval(trickle); raw.destroy(); await wait(20);
  const us = upload.route.inspect()[0], ua = us.attempts[0];
  check(ua.termination === 'upload_deadline' && !ua.upstream_dispatched && observed.length === n, 'absolute slow upload deadline before vault');
  check(fs.readFileSync(path.join(out, 'upload', ua.client_wire.name)).subarray(0, partial.length).equals(partial), 'partial failed upload bytes retained');
  check(us.unknown_usage === 0 && upload.route.events.filter(e => e.phase === 'end').length === 1, 'undispatched upload is not unknown provider spend; finalized once');
  const aborted = http.request(upload.url(u), {method: 'POST', headers: {'content-length': 1000}});
  aborted.on('error', () => {}); aborted.write('partial-abandoned'); await wait(25); aborted.destroy(); await wait(25);
  check(upload.route.inspect()[0].attempts[1].client_wire.bytes === 17, 'aborted upload preserved');

  const s1 = arm('first', {maxMilliseconds: 90}), s2 = arm('second', {maxMilliseconds: 90});
  const serial = await make('serial', [s1, s2]); await wait(130);
  check(!serial.route.inspect().some(s => s.activated), 'construction/status does not activate clocks');
  await (await send(serial.url(s1), body('normal'))).text(); await wait(130);
  check((await send(serial.url(s2), body('normal'))).status === 200, 'later serial arm starts its own clock');
  serial.route.activate(s2.handle); await wait(110);
  check((await send(serial.url(s2), body('normal'))).status === 429, 'explicit activation is idempotent, no clock reset');

  const capped = arm('capped', {maxPromptTotal: 90, maxOutputTotal: 10}), caps = await make('caps', [capped]);
  await (await send(caps.url(capped), body('normal'))).text();
  const cs = caps.route.inspect()[0], count = observed.length;
  check(cs.overshoot.prompt_total === 10 && cs.overshoot.output === 10, 'one-response token overshoot explicit');
  check((await send(caps.url(capped), body('normal'))).status === 429 && observed.length === count, 'no second request after reported-token ceiling');
  const limited = arm('limited', {maxRequests: 1}), requestLimit = await make('requests', [limited]);
  await (await send(requestLimit.url(limited), body('normal'))).text();
  check((await send(requestLimit.url(limited), body('normal'))).status === 429, 'experiment request ceiling enforced');

  const abandon = arm('abandon'), abandoning = await make('abandon', [abandon]);
  const abandoned = http.request(abandoning.url(abandon), {method: 'POST', headers: {'content-type': 'application/json'}}, res => {
    res.on('data', () => abandoned.destroy()); res.on('error', () => {});
  }); abandoned.on('error', () => {}); abandoned.end(JSON.stringify(body('abandon'))); await wait(80);
  const as = abandoning.route.inspect()[0];
  check(as.halted && as.attempts[0].termination === 'downstream_abandoned' && as.attempts[0].response.bytes > 0, 'downstream disconnect retains partial response and halts');
  check(abandoning.route.events.filter(e => e.phase === 'end').length === 1, 'disconnect and upstream errors finalize once');

  for (const options of [{credential: 'not-allowed'}, {model: 'wrong'}, {reasoning: 'high'}, {vaultUrl: vaultUrl + '/other'}, {vaultUrl: vaultUrl + '?override=1'}]) {
    assert.throws(() => createVaultSubscriptionRoute({vaultUrl, root: path.join(out, 'must-not-create'), arms, ...options})); checks++;
  }
  for (const usage of [{input_tokens: -1, output_tokens: 1}, {input_tokens: 1.5, output_tokens: 1}, {input_tokens: Number.MAX_SAFE_INTEGER, output_tokens: 1},
    {input_tokens: 10, output_tokens: 2, total_tokens: 1}, {input_tokens: 10, output_tokens: 2, output_tokens_details: {reasoning_tokens: 3}}]) {
    check(responseUsage({usage}) === null, 'invalid/fractional/overflow/inconsistent usage unknown');
  }
  const unavailable = http.createServer(); await new Promise(r => unavailable.listen(0, '127.0.0.1', r));
  const unavailableUrl = 'http://127.0.0.1:' + unavailable.address().port; await new Promise(r => unavailable.close(r));
  const failedArm = arm('connect-failed'), failed = await make('connect-failed', [failedArm], unavailableUrl);
  await (await send(failed.url(failedArm), body('normal'))).text();
  const failedState = failed.route.inspect()[0];
  check(failedState.halted && failedState.unknown_usage === 1 && failedState.attempts[0].termination === 'request_failed'
    && failedState.attempts[0].response.bytes === 0, 'connection failure retains empty observed response and unknown dispatch intent');
  check((await send(failed.url(failedArm), body('normal'))).status === 429, 'connection failure never replayed');

  const journal = readModelRouteJournal(path.join(out, 'common'));
  check(journal.complete && journal.complete_provider_usage && journal.provider_attempts === 4
    && journal.prompt_total === 400 && journal.output === 80 && journal.actual_cost === null, 'offline complete journal readback covers all four arms');
  check(!readModelRouteJournal(path.join(out, 'partial')).complete_provider_usage, 'failed provider attempt makes total usage unknown');
  const cli = cp.spawnSync(process.execPath, [path.join(repo, 'scripts/agent-benchmark.mjs'), '--route-journal', path.join(out, 'common')],
    {env: isolatedEnvironment(out), encoding: 'utf8'});
  fs.writeFileSync(path.join(out, 'journal-cli.stdout'), cli.stdout); fs.writeFileSync(path.join(out, 'journal-cli.stderr'), cli.stderr);
  check(cli.status === 0 && JSON.parse(cli.stdout).provider_attempts === 4 && !cli.stdout.includes('CALLER_SECRET'), 'runner exposes metadata-only offline journal readback');
  const incompleteRoot = path.join(out, 'incomplete-journal'); fs.mkdirSync(incompleteRoot);
  const firstIntent = route.events.filter(e => e.phase === 'configuration' || ['activation', 'admitted', 'start'].includes(e.phase)
    && (e.id === '0001' || e.phase === 'activation' && e.arm === 'pi'));
  fs.writeFileSync(path.join(incompleteRoot, 'events.jsonl'), firstIntent.map(JSON.stringify).join('\n') + '\n');
  const incomplete = readModelRouteJournal(incompleteRoot);
  check(!incomplete.complete && incomplete.pending.length === 1 && incomplete.prompt_total === null && !incomplete.replayed,
    'crash/dispatch intent remains unknown; never replayed');
  const corruptRoot = path.join(out, 'corrupt-journal'); fs.cpSync(path.join(out, 'common'), corruptRoot, {recursive: true});
  fs.appendFileSync(path.join(corruptRoot, route.inspect()[0].attempts[0].client_wire.name), 'corrupt');
  assert.throws(() => readModelRouteJournal(corruptRoot), /integrity/); checks++;
  const duplicateRoot = path.join(out, 'duplicate-journal'); fs.cpSync(path.join(out, 'common'), duplicateRoot, {recursive: true});
  fs.appendFileSync(path.join(duplicateRoot, 'events.jsonl'), JSON.stringify(route.events.find(e => e.phase === 'end')) + '\n');
  assert.throws(() => readModelRouteJournal(duplicateRoot), /duplicate/); checks++;

  for (const r of routes) {
    r.dispose();
    const ends = r.events.filter(e => e.phase === 'end');
    check(r.inspect().every(s => !s.inflight) && new Set(ends.map(e => e.id)).size === ends.length, 'all admitted attempts settled exactly once');
  }
  const combinedMetadata = routes.map(r => JSON.stringify(r.events)).join('\n');
  check(!combinedMetadata.includes('BENCHMARK_SYNTHETIC_ACCESS_ONLY') && !combinedMetadata.includes('CALLER_SECRET'), 'metadata excludes credentials and arbitrary caller headers');
  fs.writeFileSync(path.join(out, 'receipt.json'), JSON.stringify({ok: true, checks, skipped: 0, paid_calls: 0,
    vault_source_sha256: digest(fs.readFileSync(path.join(repo, 'vault/wa_vault.py'))), observed_provider_requests: observed.length,
    isolation: 'actual vault process/header seam; same-user fixture is NOT OS credential isolation',
    actual_cost: null, paid_ready: false, routes: routes.map(r => r.inspect())}, null, 2));
  fs.writeFileSync(path.join(out, 'provider-observed.json'), JSON.stringify(observed, null, 2));
  console.log(JSON.stringify({ok: true, checks, skipped: 0, paid_calls: 0, evidence: out}));
} finally {
  for (const r of routes) { r.dispose(); await new Promise(resolve => r.server.close(resolve)); }
  child.kill(); const exit = await closed;
  fs.writeFileSync(path.join(out, 'vault.stdout'), stdout); fs.writeFileSync(path.join(out, 'vault.stderr'), stderr);
  fs.writeFileSync(path.join(out, 'vault-exit.json'), JSON.stringify(exit));
  for (const t of streams) clearInterval(t);
  provider.closeAllConnections(); await new Promise(r => provider.close(r));
  trap.closeAllConnections(); await new Promise(r => trap.close(r));
}
