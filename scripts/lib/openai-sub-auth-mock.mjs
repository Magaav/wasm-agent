// The fixture the subscription credential's tests talk to: OpenAI's auth host, locally.
//
// Why a server rather than a stubbed `host.http`: the property this lane has to prove is that two
// *processes* refreshing one rotating token spend it once. A stub lives inside one interpreter, so
// it can only answer that question by assuming it. This one is real HTTP on 127.0.0.1, shared by
// every process the test starts.
//
// It reproduces the measured contracts it stands in for (pi 0.87.1): the form-encoded token
// endpoint with `grant_type=refresh_token|authorization_code`, the device-code pair
// (`usercode` -> `{device_auth_id, user_code, interval}`, `token` -> 403 while pending, then
// `{authorization_code, code_verifier}`), and a 200 that always carries
// `{access_token, refresh_token, expires_in}` with a JWT access token whose
// `https://api.openai.com/auth.chatgpt_account_id` claim is set.
//
// Two behaviours exist for evidence rather than realism:
//   * it refuses to answer a refresh token it has already spent, with the provider's own
//     `400 invalid_grant` - so a double-spend shows up as the server's error, not as an
//     assertion in our test;
//   * it appends one line per request to `<dir>/posts.jsonl`, and each token response's new
//     refresh token fingerprint to `<dir>/issued.jsonl`. The count in that file is the
//     single-flight evidence, and the fingerprint lets a test prove the store holds the *new*
//     rotating token without either side ever printing the token.
//
// Usage: node scripts/lib/openai-sub-auth-mock.mjs --dir <state-dir> [--delay-ms 0]
//        [--device-pending-polls 2] [--fail-refresh <status>] [--epoch <n>]
// Prints `ready <port>` on stdout once it is listening; kills itself on SIGTERM/SIGINT.
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';

const options = {};
const argv = process.argv.slice(2);
for (let index = 0; index < argv.length; index += 1) {
  const name = argv[index];
  if (!name.startsWith('--')) continue;
  const next = argv[index + 1];
  if (next === undefined || next.startsWith('--')) { options[name.slice(2)] = 'true'; continue; }
  options[name.slice(2)] = next;
  index += 1;
}
const dir = options.dir;
if (!dir) { process.stderr.write('openai-sub-auth-mock: --dir is required\n'); process.exit(2); }
fs.mkdirSync(dir, { recursive: true });
const delayMs = Number(options['delay-ms'] || 0);
const devicePendingPolls = Number(options['device-pending-polls'] ?? 2);
// A refresh that answers this status instead of tokens: the taxonomy's `refresh_rejected:<status>`
// case, provokable on purpose.
const failRefresh = options['fail-refresh'] ? Number(options['fail-refresh']) : null;
const accountId = options['account-id'] || 'acct-fixture-0001';

const postsPath = path.join(dir, 'posts.jsonl');
const issuedPath = path.join(dir, 'issued.jsonl');
// The test seeds the token its fixture store already holds here - a file, never an argument, so a
// credential of any kind stays out of a command line even in a fixture (the rule this module is
// built around applies to its tests too).
const seedPath = path.join(dir, 'seed.json');
let currentRefresh = null;
const seeded = () => {
  try { return JSON.parse(fs.readFileSync(seedPath, 'utf8')); } catch { return null; }
};
let issued = 0;
let devicePolls = 0;

const sha = text => crypto.createHash('sha256').update(String(text)).digest('hex');
const fingerprint = text => sha(text).slice(0, 12);
const b64url = value => Buffer.from(JSON.stringify(value)).toString('base64url');
function accessToken(expiresIn) {
  return `${b64url({ alg: 'none', typ: 'JWT' })}.${b64url({
    'https://api.openai.com/auth': { chatgpt_account_id: accountId },
    exp: Math.floor(Date.now() / 1000) + expiresIn,
  })}.fixture-signature`;
}
function record(line) { fs.appendFileSync(postsPath, `${JSON.stringify(line)}\n`); }
function form(text) {
  const fields = {};
  for (const pair of String(text || '').split('&')) {
    if (!pair) continue;
    const [name, ...rest] = pair.split('=');
    fields[decodeURIComponent(name)] = decodeURIComponent(rest.join('='));
  }
  return fields;
}
function answer(response, status, body) {
  const text = typeof body === 'string' ? body : JSON.stringify(body);
  response.writeHead(status, { 'Content-Type': 'application/json' });
  response.end(text);
}
function tokenPayload(expiresIn = 3600) {
  issued += 1;
  const refresh = `R-${issued}-${crypto.randomBytes(24).toString('base64url')}`;
  const access = accessToken(expiresIn);
  currentRefresh = refresh;
  fs.appendFileSync(issuedPath, `${JSON.stringify({
    at: Date.now(), refresh_fingerprint: fingerprint(refresh), access_fingerprint: fingerprint(access),
    expires_in: expiresIn, account_id: accountId,
  })}\n`);
  return { access_token: access, refresh_token: refresh, expires_in: expiresIn };
}

const server = http.createServer((request, response) => {
  const chunks = [];
  request.on('data', chunk => chunks.push(chunk));
  request.on('end', () => {
    const body = Buffer.concat(chunks).toString('utf8');
    const url = new URL(request.url || '/', 'http://127.0.0.1');
    const respond = () => handle(request, response, url, body);
    if (delayMs > 0 && url.pathname === '/oauth/token') setTimeout(respond, delayMs);
    else respond();
  });
});

function handle(request, response, url, body) {
  if (request.method === 'GET' && url.pathname === '/__health') {
    return answer(response, 200, { ok: true, posts: fs.existsSync(postsPath)
      ? fs.readFileSync(postsPath, 'utf8').split('\n').filter(Boolean).length : 0 });
  }
  if (request.method !== 'POST') return answer(response, 405, { error: 'method_not_allowed' });
  if (url.pathname === '/oauth/token') {
    const fields = form(body);
    record({ at: Date.now(), path: url.pathname, grant_type: fields.grant_type,
      client_id: fields.client_id, has_refresh: Boolean(fields.refresh_token),
      refresh_fingerprint: fields.refresh_token ? fingerprint(fields.refresh_token) : null,
      code_fingerprint: fields.code ? fingerprint(fields.code) : null,
      code_verifier_present: Boolean(fields.code_verifier), redirect_uri: fields.redirect_uri || null,
      content_type: String(request.headers['content-type'] || '') });
    if (failRefresh && fields.grant_type === 'refresh_token') {
      return answer(response, failRefresh, { error: 'invalid_grant' });
    }
    if (fields.grant_type === 'refresh_token') {
      // Provider semantics, and the reason this lane exists: only the newest issued refresh token is
      // valid, so a second process spending the same one is refused with `400 invalid_grant`. The
      // seeded token is the store's current one until the first refresh replaces it.
      const seed = seeded();
      const valid = fields.refresh_token && (fields.refresh_token === currentRefresh
        || (currentRefresh === null && fields.refresh_token === seed));
      if (!valid) return answer(response, 400, { error: 'invalid_grant' });
      return answer(response, 200, tokenPayload());
    }
    if (fields.grant_type === 'authorization_code') {
      if (!fields.code || !fields.code_verifier) return answer(response, 400, { error: 'invalid_request' });
      return answer(response, 200, tokenPayload());
    }
    return answer(response, 400, { error: 'unsupported_grant_type' });
  }
  if (url.pathname === '/api/accounts/deviceauth/usercode') {
    const fields = JSON.parse(body || '{}');
    record({ at: Date.now(), path: url.pathname, client_id: fields.client_id || null,
      content_type: String(request.headers['content-type'] || '') });
    if (fields.client_id !== 'app_EMoamEEZ73f0CkXaXp7hrann') {
      return answer(response, 400, { error: 'invalid_client' });
    }
    return answer(response, 200, { device_auth_id: `DEVICE-${crypto.randomUUID()}`,
      user_code: 'FIXTURE-CODE', interval: 1 });
  }
  if (url.pathname === '/api/accounts/deviceauth/token') {
    devicePolls += 1;
    record({ at: Date.now(), path: url.pathname, poll: devicePolls, body: form(body) });
    if (devicePolls <= devicePendingPolls) {
      // Both spellings the provider uses while the human has not finished.
      return answer(response, devicePolls === 1 ? 403 : 400,
        devicePolls === 1 ? { error: 'deviceauth_authorization_pending' }
          : { error: { code: 'deviceauth_authorization_pending' } });
    }
    return answer(response, 200, { authorization_code: `CODE-${devicePolls}`,
      code_verifier: `VERIFIER-${devicePolls}` });
  }
  return answer(response, 404, { error: 'not_found' });
}

server.listen(Number(options.port || 0), '127.0.0.1', () => {
  process.stdout.write(`ready ${server.address().port}\n`);
});
for (const signal of ['SIGTERM', 'SIGINT']) {
  process.on(signal, () => { server.close(); process.exit(0); });
}
