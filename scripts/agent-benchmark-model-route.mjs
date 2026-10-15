// Candidate four-arm Responses transport. Paid CLI admission is deliberately separate.
// Vault mode never accepts a credential: only the fixed vault attaches subscription secrets.
import http from 'node:http';
import https from 'node:https';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import assert from 'node:assert/strict';
import zlib from 'node:zlib';
import {StringDecoder} from 'node:string_decoder';

export const subscriptionPins = Object.freeze({model: 'gpt-6.1-sol', reasoning: 'low'});
const sha = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const integer = n => Number.isSafeInteger(n) && n >= 0;
const requestBound = 8 * 1024 * 1024, responseBound = 32 * 1024 * 1024;
const loopback = url => url.protocol === 'http:' && ['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname);

export function responseUsage(value) {
  const u = value?.usage;
  if (!u || !integer(u.input_tokens) || !integer(u.output_tokens)
      || !integer(u.input_tokens + u.output_tokens)) return null;
  if (u.total_tokens !== undefined && u.total_tokens !== u.input_tokens + u.output_tokens) return null;
  const cached = u.input_tokens_details?.cached_tokens, reasoning = u.output_tokens_details?.reasoning_tokens;
  if (cached !== undefined && (!integer(cached) || cached > u.input_tokens)) return null;
  if (reasoning !== undefined && (!integer(reasoning) || reasoning > u.output_tokens)) return null;
  return {prompt_total: u.input_tokens, cache_read: cached ?? null,
    uncached_input: cached === undefined ? null : u.input_tokens - cached,
    output: u.output_tokens, reasoning: reasoning ?? null, cache_write: null};
}

// Controller-only configuration, never a solver-supplied endpoint or credential.
// HTTP is appropriate only on the later isolated private network; TLS otherwise.
export function createVaultSubscriptionRoute({vaultUrl, ...options}) {
  const base = new URL(vaultUrl);
  assert(['http:', 'https:'].includes(base.protocol) && base.pathname === '/' && !base.search
    && !base.hash && !base.username && !base.password, 'fixed vault origin required');
  assert(options.mode === undefined && options.upstream === undefined && options.credential === undefined,
    'vault owns upstream selection and credentials');
  return createSharedModelRoute({...subscriptionPins, ...options, mode: 'vault-subscription',
    upstream: new URL('/openai-sub/codex/responses', base).href});
}

export function createSharedModelRoute({mode, upstream, credential, model, reasoning, root, arms}) {
  assert(['model-free', 'vault-subscription'].includes(mode), 'unsupported transport mode');
  const target = new URL(upstream), vaulted = mode === 'vault-subscription';
  assert(!target.username && !target.password && !target.hash && !target.search, 'fixed upstream without URL credentials/query required');
  if (vaulted) {
    assert(['http:', 'https:'].includes(target.protocol) && target.pathname === '/openai-sub/codex/responses', 'fixed vault subscription endpoint required');
    assert(credential === undefined, 'subscription credential must remain in vault');
  } else {
    assert(loopback(target), 'model-free upstream must be loopback');
    assert(typeof credential === 'string' && credential, 'explicit synthetic transport credential required');
  }
  assert(model === subscriptionPins.model && reasoning === subscriptionPins.reasoning, 'exact gpt-6.1-sol/low pins required');
  assert(Array.isArray(arms) && arms.length, 'explicit experiment arms required');
  const scopes = new Map(), names = new Set();
  for (const arm of arms) {
    assert(typeof arm.arm === 'string' && /^[a-z0-9-]{1,64}$/.test(arm.arm) && !names.has(arm.arm), 'unique arm name required');
    assert(/^[a-f0-9]{64}$/.test(arm.handle) && !scopes.has(arm.handle), 'unique arm route handle');
    assert([arm.maxRequests, arm.maxPromptTotal, arm.maxOutputTotal, arm.maxMilliseconds]
      .every(n => integer(n) && n > 0), 'explicit experiment-only controls required');
    assert(arm.maxRequestMilliseconds === undefined || integer(arm.maxRequestMilliseconds) && arm.maxRequestMilliseconds > 0,
      'positive absolute request deadline required');
    names.add(arm.arm);
    scopes.set(arm.handle, {...arm, requests: 0, provider_attempts: 0, prompt_total: 0, output: 0,
      unknown_usage: 0, inflight: false, halted: false, started: null, attempts: []});
  }
  assert(path.isAbsolute(root) && !fs.existsSync(root), 'fresh private route evidence required');
  fs.mkdirSync(root, {recursive: true, mode: 0o700});
  let serial = 0, disposed = false;
  const events = [], active = new Set();
  function log(value) {
    const fd = fs.openSync(path.join(root, 'events.jsonl'), 'a', 0o600);
    try { fs.writeFileSync(fd, JSON.stringify(value) + '\n'); fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
    events.push(value);
  }
  function capture(name) {
    const fd = fs.openSync(path.join(root, name), 'wx', 0o600), hash = crypto.createHash('sha256');
    let bytes = 0, closed = false, ref;
    return {
      append(chunk) { assert(!closed); fs.writeFileSync(fd, chunk); fs.fsyncSync(fd); hash.update(chunk); bytes += chunk.length; },
      close() { if (!closed) { fs.closeSync(fd); closed = true; ref = {name, bytes, sha256: hash.digest('hex')}; } return ref; },
    };
  }
  function persist(name, bytes) { const c = capture(name); c.append(bytes); return c.close(); }
  const elapsed = s => s.started === null ? 0 : performance.now() - s.started;
  const exhausted = s => disposed || s.halted || s.requests >= s.maxRequests || s.prompt_total >= s.maxPromptTotal
    || s.output >= s.maxOutputTotal || elapsed(s) >= s.maxMilliseconds;
  function activate(handle) {
    const s = scopes.get(handle); assert(s && !disposed, 'known active experiment arm required');
    if (s.started === null) { s.started = performance.now(); log({phase: 'activation', arm: s.arm, at: Date.now()}); }
  }
  function inspect() {
    return [...scopes.values()].map(s => ({arm: s.arm, requests: s.requests, provider_attempts: s.provider_attempts,
      prompt_total: s.prompt_total, output: s.output, unknown_usage: s.unknown_usage,
      inflight: s.inflight, halted: s.halted, activated: s.started !== null, attempts: structuredClone(s.attempts),
      limits: {requests: s.maxRequests, prompt_total: s.maxPromptTotal, output: s.maxOutputTotal,
        milliseconds: s.maxMilliseconds, request_milliseconds: s.maxRequestMilliseconds ?? s.maxMilliseconds},
      overshoot: {prompt_total: Math.max(0, s.prompt_total - s.maxPromptTotal), output: Math.max(0, s.output - s.maxOutputTotal)},
      token_control: 'reported-after-response; at most one response overshoot; no hard-dollar cap', actual_cost: null}));
  }
  log({phase: 'configuration', version: 1, mode, model, reasoning, upstream_sha256: sha(Buffer.from(target.href)),
    controls: [...scopes.values()].map(s => ({arm: s.arm, maxRequests: s.maxRequests, maxPromptTotal: s.maxPromptTotal,
      maxOutputTotal: s.maxOutputTotal, maxMilliseconds: s.maxMilliseconds, maxRequestMilliseconds: s.maxRequestMilliseconds ?? s.maxMilliseconds}))});
  const server = http.createServer(async (req, res) => {
    const refuse = (status, code, arm = null) => {
      log({phase: 'refused', status, code, arm});
      if (!res.destroyed) { res.writeHead(status, {'content-type': 'application/json'}); res.end(JSON.stringify({error: {code}})); }
    };
    const match = /^\/arms\/([a-f0-9]{64})\/(status|openai-sub\/codex\/responses)$/.exec(req.url ?? '');
    const scope = match && scopes.get(match[1]);
    if (!scope) return refuse(404, 'benchmark_route_denied');
    if (match[2] === 'status' && req.method === 'GET') {
      // Transport presence only, not vault credential presence or model entitlement.
      res.writeHead(200, {'content-type': 'application/json'});
      res.end(JSON.stringify({providers: {'openai-sub': {configured: true, enabled: !exhausted(scope), account_id: 'benchmark-brokered'}}, transport_only: true}));
      return;
    }
    if (match[2] !== 'openai-sub/codex/responses' || req.method !== 'POST') return refuse(404, 'benchmark_route_denied', scope.arm);
    if (scope.inflight) return refuse(409, 'benchmark_arm_request_inflight', scope.arm);
    if (exhausted(scope)) return refuse(429, 'benchmark_budget_or_unknown_usage', scope.arm);

    // Reservation and arm-local activation precede the FIRST await (including uploads).
    scope.inflight = true; activate(match[1]);
    const id = String(++serial).padStart(4, '0'), started = performance.now();
    const deadline = Math.min(scope.started + scope.maxMilliseconds, started + (scope.maxRequestMilliseconds ?? scope.maxMilliseconds));
    const attempt = {id, arm: scope.arm, status: null, upstream_dispatched: false, client_wire: null,
      client: null, prepared: null, response: null, usage: null, first_byte_ms: null, elapsed_ms: null, termination: null};
    scope.attempts.push(attempt);
    const upload = capture(id + '.client.wire');
    let responseCapture, upstreamRequest, reply, ended = false, parsed, decodedBytes, timer;
    const chunks = [], terminals = [], decoder = new StringDecoder('utf8');
    let uploadLength = 0, responseLength = 0, text = '';
    log({phase: 'admitted', id, arm: scope.arm, at: Date.now(), started_monotonic_ms: started,
      absolute_deadline_monotonic_ms: deadline, original_path: id + '.client.wire'});
    function finish(termination, code = null, localStatus = 502) {
      if (ended) return;
      ended = true; clearTimeout(timer); active.delete(cancel);
      attempt.termination = termination; attempt.elapsed_ms = performance.now() - started;
      attempt.client_wire = upload.close();
      attempt.response = responseCapture ? responseCapture.close() : persist(id + '.response', Buffer.alloc(0));
      const terminal = terminals.length === 1 ? terminals[0] : null;
      attempt.usage = attempt.upstream_dispatched && attempt.status === 200 && termination === 'terminal_complete'
        && terminal?.status === 'completed' ? responseUsage(terminal) : null;
      if (attempt.usage && integer(scope.prompt_total + attempt.usage.prompt_total) && integer(scope.output + attempt.usage.output)) {
        scope.prompt_total += attempt.usage.prompt_total; scope.output += attempt.usage.output;
      } else if (attempt.upstream_dispatched) { attempt.usage = null; scope.unknown_usage++; scope.halted = true; }
      scope.inflight = false;
      log({phase: 'end', ...attempt, error_code: code});
      if (!res.destroyed && !res.writableEnded) {
        if (!res.headersSent) res.writeHead(localStatus, {'content-type': 'application/json'});
        res.end();
      }
      reply?.destroy(); upstreamRequest?.destroy();
    }
    const cancel = () => finish('route_shutdown'); active.add(cancel);
    timer = setTimeout(() => {
      finish(attempt.upstream_dispatched ? 'stream_deadline' : 'upload_deadline', null, 408);
      req.destroy();
    }, Math.max(1, deadline - performance.now()));
    req.on('aborted', () => finish(attempt.upstream_dispatched ? 'downstream_abandoned' : 'upload_aborted'));
    res.on('close', () => { if (!res.writableFinished) finish('downstream_abandoned'); });
    try {
      for await (const chunk of req) {
        if (ended) return;
        upload.append(chunk); chunks.push(chunk); uploadLength += chunk.length;
        assert(uploadLength <= requestBound, 'request_bound');
      }
      if (ended) return;
      const original = Buffer.concat(chunks), encoding = req.headers['content-encoding'];
      assert(!encoding || encoding === 'zstd', 'content_encoding');
      decodedBytes = encoding === 'zstd' ? zlib.zstdDecompressSync(original, {maxOutputLength: requestBound}) : original;
      attempt.client = persist(id + '.decoded.json', decodedBytes);
      parsed = JSON.parse(decodedBytes.toString('utf8'));
      assert(parsed && typeof parsed === 'object' && !Array.isArray(parsed), 'request_shape');
      assert(parsed.model === model && parsed.reasoning?.effort === reasoning && parsed.stream === true, 'model_reasoning_stream_pin');
      assert(Array.isArray(parsed.input) && (!parsed.tools || Array.isArray(parsed.tools)), 'input_tool_shape');
      assert(parsed.previous_response_id === undefined, 'provider_continuation');
      assert(vaulted || !decodedBytes.includes(Buffer.from(credential)), 'synthetic_credential_exposure');
      if (performance.now() >= deadline) {
        finish('upload_deadline', null, 408); return;
      }
      // Do not carry ANY caller headers: cookie, Host, auth, forwarding or identity.
      // Route and cache keys are controller-owned; original bytes remain untouched.
      const routing = sha(Buffer.from(scope.handle));
      const wire = Buffer.from(JSON.stringify({...parsed, prompt_cache_key: routing}));
      persist(id + '.client.json', decodedBytes); // existing observation adapter compatibility
      attempt.prepared = persist(id + '.upstream.json', wire);
      responseCapture = capture(id + '.response');
      if (performance.now() >= deadline) { finish('upload_deadline', null, 408); return; }
      // Durable intent BEFORE the external effect. Failure after this point is unknown,
      // never a license to retry (including connection failure before response headers).
      attempt.upstream_dispatched = true; scope.requests++; scope.provider_attempts++;
      log({phase: 'start', ...attempt, model, reasoning, content_encoding: encoding ?? null,
        routing_scope_hash: routing, response_path: id + '.response'});
      if (performance.now() >= deadline) { finish('dispatch_deadline', null, 408); return; }
      upstreamRequest = (target.protocol === 'https:' ? https : http).request(target, {method: 'POST', agent: false, headers: {
        'content-type': 'application/json', accept: 'text/event-stream', 'content-length': wire.length,
        authorization: 'Bearer ' + (vaulted ? 'wa-vault-brokered' : credential),
        originator: 'codex-cli', 'user-agent': 'codex-cli', 'openai-beta': 'responses=experimental',
        session_id: routing, 'session-id': routing, 'x-client-request-id': routing,
      }}, response => {
        reply = response;
        if (ended) { reply.destroy(); return; }
        attempt.status = reply.statusCode;
        if (!res.destroyed) res.writeHead(reply.statusCode ?? 502, {'content-type': reply.headers['content-type'] ?? 'application/octet-stream'});
        reply.on('data', chunk => {
          if (ended) return;
          try {
            if (attempt.first_byte_ms === null) attempt.first_byte_ms = performance.now() - started;
            responseCapture.append(chunk); responseLength += chunk.length;
            if (performance.now() >= deadline) { finish('stream_deadline'); return; }
            if (responseLength > responseBound) { finish('response_bound'); return; }
            text += decoder.write(chunk);
            for (;;) {
              const boundary = /\r?\n\r?\n/.exec(text); if (!boundary) break;
              const frame = text.slice(0, boundary.index); text = text.slice(boundary.index + boundary[0].length);
              const data = frame.split(/\r?\n/).filter(s => s.startsWith('data:')).map(s => s.slice(5).trimStart()).join('\n');
              if (!data || data === '[DONE]') continue;
              let event; try { event = JSON.parse(data); } catch { continue; }
              if (event.type === 'response.completed' && event.response) terminals.push(event.response);
              if (['response.failed', 'response.incomplete', 'error'].includes(event.type)) {
                if (!res.destroyed) res.write(chunk); finish('provider_failed'); return;
              }
            }
            if (!res.destroyed) res.write(chunk);
            if (terminals.length) finish('terminal_complete');
          } catch { scope.halted = true; finish('evidence_failed'); }
        });
        reply.on('end', () => finish('eof'));
        reply.on('error', error => finish('read_failed', error.code ?? null));
        reply.on('aborted', () => finish('aborted'));
      });
      upstreamRequest.on('error', error => finish('request_failed', error.code ?? null));
      upstreamRequest.end(wire);
    } catch (error) {
      // Validation errors are codes, not arbitrary caller/provider strings in metadata.
      const code = error.code === 'ERR_ASSERTION' ? error.message : error.code ?? 'invalid_upload';
      finish(attempt.upstream_dispatched ? 'request_failed' : 'validation_refused', code, 400);
    }
  });
  // Node's generic socket idle timers are NOT the experiment deadline.
  server.requestTimeout = 0; server.timeout = 0;
  function dispose() { disposed = true; for (const cancel of [...active]) cancel(); server.closeAllConnections(); }
  return {server, inspect, events, activate, dispose, mode, paid_ready: false,
    isolation: 'transport/header separation only; OS/container isolation requires separate proof'};
}

// Offline/restart readback, never replay. A dispatch intent without an end remains
// unknown even if the connection may never have reached the provider. This covers
// every observed HTTP attempt (including retry/summary requests), not just finals.
export function readModelRouteJournal(root) {
  const events = fs.readFileSync(path.join(root, 'events.jsonl'), 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse);
  const admitted = new Map(), started = new Map(), ended = new Map();
  for (const event of events) {
    const map = event.phase === 'admitted' ? admitted : event.phase === 'start' ? started : event.phase === 'end' ? ended : null;
    if (!map) continue;
    assert(typeof event.id === 'string' && !map.has(event.id), 'duplicate/invalid attempt identity');
    map.set(event.id, event);
  }
  for (const [id, e] of [...started, ...ended]) assert(admitted.has(id) && admitted.get(id).arm === e.arm, 'unmatched attempt boundary');
  const verify = ref => {
    if (!ref) return;
    assert(/^[a-zA-Z0-9._-]+$/.test(ref.name) && /^[a-f0-9]{64}$/.test(ref.sha256) && integer(ref.bytes), 'invalid capture reference');
    const bytes = fs.readFileSync(path.join(root, ref.name));
    assert(bytes.length === ref.bytes && sha(bytes) === ref.sha256, 'capture integrity mismatch');
  };
  for (const [id, e] of ended) {
    assert(e.upstream_dispatched === started.has(id), 'dispatch journal mismatch');
    assert(e.client_wire && e.response && (!e.upstream_dispatched || e.client && e.prepared), 'missing capture reference');
    if (e.upstream_dispatched) assert(JSON.stringify(e.prepared) === JSON.stringify(started.get(id).prepared), 'prepared intent drift');
    for (const name of ['client_wire', 'client', 'prepared', 'response']) verify(e[name]);
    if (e.usage !== null) {
      const u = e.usage;
      assert(integer(u.prompt_total) && integer(u.output) && integer(u.prompt_total + u.output), 'invalid normalized usage');
      for (const key of ['cache_read', 'cache_write', 'uncached_input', 'reasoning']) assert(u[key] === null || integer(u[key]), 'invalid disjoint usage');
      assert(u.reasoning === null || u.reasoning <= u.output, 'reasoning is an output subset');
      assert(u.cache_read === null || u.cache_read <= u.prompt_total, 'cache is a prompt subset');
    }
  }
  const pending = [...admitted.keys()].filter(id => !ended.has(id));
  const attempts = [...admitted].map(([id, e]) => ended.get(id) ?? {id, arm: e.arm,
    upstream_dispatched: started.has(id), termination: null, usage: null, state: 'unsettled-do-not-replay'});
  const providers = attempts.filter(a => a.upstream_dispatched);
  const complete = pending.length === 0;
  const prompt = providers.reduce((sum, a) => sum + (a.usage?.prompt_total ?? 0), 0);
  const output = providers.reduce((sum, a) => sum + (a.usage?.output ?? 0), 0);
  const usageKnown = complete && providers.every(a => a.usage !== null) && integer(prompt) && integer(output);
  return {complete, pending, attempts, provider_attempts: providers.length,
    complete_provider_usage: usageKnown, prompt_total: usageKnown ? prompt : null, output: usageKnown ? output : null,
    actual_cost: null, replayed: false};
}
