// Independent reviewer's fixture: a token endpoint that COUNTS what the module does.
// Written from scratch (not the producer's scripts/lib/openai-sub-auth-mock.mjs) so the count is
// not the delivery's own instrument.
//
//   node mock.mjs --dir <state-dir> [--delay-ms N] [--fail-refresh <status>] [--pending-polls N]
//   prints: ready <port>
//
// State: <dir>/seed.txt holds the refresh token the store starts with (a file, never argv).
// Counters are append-only files: <dir>/posts.jsonl, <dir>/issued.jsonl. Only fingerprints and
// lengths are ever written, never a token value.
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';

const opt = {};
const argv = process.argv.slice(2);
for (let i = 0; i < argv.length; i += 1) {
  if (!argv[i].startsWith('--')) continue;
  const next = argv[i + 1];
  if (next === undefined || next.startsWith('--')) { opt[argv[i].slice(2)] = 'true'; continue; }
  opt[argv[i].slice(2)] = next; i += 1;
}
if (!opt.dir) { process.stderr.write('mock: --dir required\n'); process.exit(2); }
const dir = opt.dir;
fs.mkdirSync(dir, { recursive: true });
const delayMs = Number(opt['delay-ms'] || 0);
const failRefresh = opt['fail-refresh'] ? Number(opt['fail-refresh']) : null;
const pendingPolls = Number(opt['pending-polls'] ?? 1);
const accountId = opt['account-id'] || 'acct-reviewer-0001';

const fp = t => crypto.createHash('sha256').update(String(t)).digest('hex').slice(0, 12);
const b64 = v => Buffer.from(JSON.stringify(v)).toString('base64url');
const access = () => `${b64({ alg: 'none', typ: 'JWT' })}.${b64({
  'https://api.openai.com/auth': { chatgpt_account_id: accountId },
  exp: Math.floor(Date.now() / 1000) + 3600,
})}.reviewer`;

const seedPath = path.join(dir, 'seed.txt');
const seed = () => { try { return fs.readFileSync(seedPath, 'utf8').trim(); } catch { return null; } };
let currentRefresh = seed();
let polls = 0;
let issuedCount = 0;

const log = (file, obj) => fs.appendFileSync(path.join(dir, file), `${JSON.stringify(obj)}\n`);
const form = text => Object.fromEntries(String(text || '').split('&').filter(Boolean)
  .map(p => { const i = p.indexOf('='); const k = i < 0 ? p : p.slice(0, i);
    return [decodeURIComponent(k), decodeURIComponent(i < 0 ? '' : p.slice(i + 1))]; }));

const server = http.createServer((req, res) => {
  let body = '';
  req.on('data', c => { body += c; });
  req.on('end', async () => {
    const url = new URL(req.url, 'http://127.0.0.1');
    if (url.pathname === '/oauth/token') {
      const fields = form(body);
      const grant = fields.grant_type || '';
      const presented = fields.refresh_token || fields.code || '';
      log('posts.jsonl', { path: url.pathname, grant_type: grant, presented_fp: fp(presented),
        body_len: body.length });
      if (grant === 'refresh_token') {
        if (failRefresh) {
          res.writeHead(failRefresh, { 'content-type': 'application/json' });
          res.end(JSON.stringify({ error: 'invalid_grant',
            detail: 'Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ4In0.sig' }));
          return;
        }
        // The provider's own single-use rule: a token that was already spent is refused.
        if (presented !== currentRefresh) {
          res.writeHead(400, { 'content-type': 'application/json' });
          res.end(JSON.stringify({ error: 'invalid_grant' }));
          return;
        }
        if (delayMs) await new Promise(r => setTimeout(r, delayMs));
        issuedCount += 1;
        const next = `R${issuedCount}-${crypto.randomUUID()}`;
        currentRefresh = next;
        log('issued.jsonl', { issued: issuedCount, refresh_fp: fp(next) });
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ access_token: access(), refresh_token: next, expires_in: 3600 }));
        return;
      }
      if (grant === 'authorization_code') {
        issuedCount += 1;
        const next = `R${issuedCount}-${crypto.randomUUID()}`;
        currentRefresh = next;
        log('issued.jsonl', { issued: issuedCount, refresh_fp: fp(next), grant });
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ access_token: access(), refresh_token: next, expires_in: 3600 }));
        return;
      }
      res.writeHead(400, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ error: 'unsupported_grant_type' }));
      return;
    }
    if (url.pathname === '/api/accounts/deviceauth/usercode') {
      log('posts.jsonl', { path: url.pathname, body_len: body.length });
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ device_auth_id: 'MOCK-DEVICE', user_code: 'MOCK-CODE', interval: 0 }));
      return;
    }
    if (url.pathname === '/api/accounts/deviceauth/token') {
      polls += 1;
      log('posts.jsonl', { path: url.pathname, poll: polls });
      if (polls <= pendingPolls) {
        res.writeHead(403, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'deviceauth_authorization_pending' }));
        return;
      }
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ authorization_code: 'MOCK-AUTH-CODE', code_verifier: 'MOCK-VERIFIER' }));
      return;
    }
    res.writeHead(404, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ error: 'not_found', path: url.pathname }));
  });
});
server.listen(0, '127.0.0.1', () => {
  process.stdout.write(`ready ${server.address().port}\n`);
});
