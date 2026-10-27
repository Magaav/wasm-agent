#!/usr/bin/env node
// Obtain a Gmail refresh token from a terminal, for one mail-mcp account segment.
//
// The consent click is the one step a program cannot do: Google requires a human at the browser. Everything
// around it is scripted here - PKCE, the loopback redirect, the code exchange, identifying WHICH account
// consented, and writing the `MAIL_OAUTH2_<SEG>_*` lines mail-mcp reads. No token is ever printed.
//
//   node scripts/mail-auth.mjs --segment WORK --client client_secret.json [--redirect http://localhost:8080]
//                              [--write-env <file>] [--timeout 300]
//
// Both Google client kinds work, because both run the same authorization-code flow:
//
//   "Desktop app"  (`installed`) - loopback redirect, any port, no redirect URI to register first.
//   "Web application" (`web`)     - the redirect URI must already be registered, exactly, on the client;
//                                   pass it as `--redirect` (Google documents http://localhost:8080).
//
// This is also what "Sign in with Google" (Google Identity Services `initCodeClient`) ends in: the browser
// half hands the backend a code, and the backend exchanges it for access and refresh tokens. The scope is
// https://mail.google.com/, which Google documents as the scope for IMAP, POP and SMTP access.
'use strict';
import http from 'node:http';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const AUTH_URL = 'https://accounts.google.com/o/oauth2/v2/auth';
const TOKEN_URL = 'https://oauth2.googleapis.com/token';
const PROFILE_URL = 'https://gmail.googleapis.com/gmail/v1/users/me/profile';
const SCOPE = 'https://mail.google.com/';

const b64url = (buf) => buf.toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

function arg(name, fallback) {
  const at = process.argv.indexOf('--' + name);
  if (at < 0) return fallback;
  const value = process.argv[at + 1];
  if (!value || value.startsWith('--')) throw new Error(`--${name} needs a value`);
  return value;
}

function loadClient(file) {
  const raw = JSON.parse(fs.readFileSync(file, 'utf8'));
  const kind = raw.installed ? 'installed' : raw.web ? 'web' : null;
  const client = raw.installed || raw.web;
  if (!client || !client.client_id) throw new Error('client json has no installed/web client_id');
  return { client, kind };
}
// A web client's redirect is a fixed, pre-registered URL, so the port is the operator's choice and has to be
// one Google already knows. Refusing an unregistered value here is the difference between a clear message
// now and a `redirect_uri_mismatch` after the consent screen.
function resolveRedirect(kind, client, requested) {
  if (kind === 'web') {
    if (!requested) throw new Error('a "Web application" client needs --redirect <registered uri>, e.g. --redirect http://localhost:8080');
    const registered = client.redirect_uris || [];
    if (!registered.includes(requested)) throw new Error('--redirect ' + requested + ' is not registered on this client; registered: ' + (registered.join(', ') || '(none)'));
    return requested;
  }
  return requested || null;
}

async function postForm(url, form) {
  const body = new URLSearchParams(form).toString();
  const res = await fetch(url, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body,
  });
  const text = await res.text();
  let json = null;
  try { json = JSON.parse(text); } catch { /* Google answers JSON; anything else is reported raw */ }
  return { status: res.status, json, text };
}

async function main() {
  const segment = (arg('segment', 'DEFAULT') || '').toUpperCase();
  if (!/^[A-Z0-9_]{1,32}$/.test(segment)) throw new Error('--segment must be A-Z, 0-9 or _ (max 32)');
  const clientFile = arg('client');
  if (!clientFile) throw new Error('--client <client_secret.json> is required');
  const { client, kind } = loadClient(clientFile);
  const requestedRedirect = arg('redirect');
  const redirect = resolveRedirect(kind, client, requestedRedirect);
  const timeoutSeconds = Number(arg('timeout', '300'));
  const writeEnv = arg('write-env');

  // RFC 7636 S256. The verifier is the secret; only its hash travels in the URL.
  const verifier = b64url(crypto.randomBytes(32));
  const challenge = b64url(crypto.createHash('sha256').update(verifier).digest());
  const state = b64url(crypto.randomBytes(16));

  const server = http.createServer();
  const result = { code: null, error: null };
  let settle;
  const answered = new Promise((resolve) => { settle = resolve; });

  server.on('request', (req, res) => {
    const url = new URL(req.url, 'http://127.0.0.1');
    if (url.pathname !== '/') { res.writeHead(404).end(); return; }
    const said = url.searchParams.get('error');
    const code = url.searchParams.get('code');
    const gotState = url.searchParams.get('state');
    // A mismatched state is an attack, not a retry: it ends the run without exchanging anything.
    if (gotState !== state) {
      result.error = 'state_mismatch';
      res.writeHead(400, { 'content-type': 'text/plain' }).end('state mismatch - nothing was exchanged\n');
    } else if (said) {
      result.error = 'consent_refused:' + said;
      res.writeHead(400, { 'content-type': 'text/plain' }).end('authorization was not granted: ' + said + '\n');
    } else if (!code) {
      result.error = 'no_code';
      res.writeHead(400, { 'content-type': 'text/plain' }).end('no code in the callback\n');
    } else {
      result.code = code;
      res.writeHead(200, { 'content-type': 'text/plain' }).end('authorized - you can close this tab\n');
    }
    settle();
  });

  await new Promise((resolve, reject) => {
    if (redirect) {
      const target = new URL(redirect);
      // localhost is what Google's examples register; bind the loopback address, not a name that may resolve
      // elsewhere on this machine.
      server.once('error', reject);
      server.listen(Number(target.port || 80), '127.0.0.1', resolve);
    } else {
      server.listen(0, '127.0.0.1', resolve);
    }
  });
  const port = server.address().port;
  const redirectUri = redirect || `http://127.0.0.1:${port}`;

  const authUrl = new URL(AUTH_URL);
  authUrl.searchParams.set('client_id', client.client_id);
  authUrl.searchParams.set('redirect_uri', redirectUri);
  authUrl.searchParams.set('response_type', 'code');
  authUrl.searchParams.set('scope', SCOPE);
  authUrl.searchParams.set('access_type', 'offline');   // without this Google returns no refresh token
  authUrl.searchParams.set('prompt', 'consent');        // and without this it may return none on re-consent
  authUrl.searchParams.set('state', state);
  authUrl.searchParams.set('code_challenge', challenge);
  authUrl.searchParams.set('code_challenge_method', 'S256');

  console.log(`segment:      ${segment}`);
  console.log(`client:       ${kind}`);
  console.log(`redirect:     ${redirectUri}`);
  console.log(`scope:        ${SCOPE}`);
  console.log('\nOpen this URL and approve the account you want to connect:\n');
  console.log(authUrl.toString() + '\n');
  console.log(`waiting up to ${timeoutSeconds}s for the callback (loopback only)...`);

  const timer = setTimeout(() => { result.error = 'timeout'; settle(); }, timeoutSeconds * 1000);
  await answered;
  clearTimeout(timer);
  server.close();

  if (result.error) {
    console.error('\nnot authorized: ' + result.error);
    console.error('nothing was written.');
    process.exitCode = 1;
    return;
  }

  console.log('\nexchanging the code...');
  const token = await postForm(TOKEN_URL, {
    client_id: client.client_id,
    client_secret: client.client_secret || '',
    code: result.code,
    code_verifier: verifier,
    grant_type: 'authorization_code',
    redirect_uri: redirectUri,
  });
  if (token.status !== 200 || !token.json || !token.json.refresh_token) {
    console.error('exchange failed: http ' + token.status + ' ' +
      (token.json ? JSON.stringify({ error: token.json.error, description: token.json.error_description }) : token.text.slice(0, 300)));
    console.error('nothing was written.');
    process.exitCode = 1;
    return;
  }

  // Which account consented? Asking Gmail is the only trustworthy answer; the consent screen's order and
  // the operator's memory are not. This is also the identity we key the account on.
  let email = null;
  try {
    const profile = await fetch(PROFILE_URL, { headers: { authorization: 'Bearer ' + token.json.access_token } });
    if (profile.ok) email = (await profile.json()).emailAddress || null;
  } catch { /* identity is reported as unknown, not guessed */ }

  const secret = client.client_secret ? client.client_secret : 'none';
  const lines = [
    `MAIL_OAUTH2_${segment}_PROVIDER=google`,
    `MAIL_OAUTH2_${segment}_CLIENT_ID=${client.client_id}`,
    `MAIL_OAUTH2_${segment}_CLIENT_SECRET=${secret}`,
    `MAIL_OAUTH2_${segment}_REFRESH_TOKEN=${token.json.refresh_token}`,
    `MAIL_IMAP_${segment}_HOST=imap.gmail.com`,
    `MAIL_IMAP_${segment}_PORT=993`,
    `MAIL_IMAP_${segment}_SECURE=true`,
    `MAIL_SMTP_${segment}_HOST=smtp.gmail.com`,
    `MAIL_SMTP_${segment}_PORT=465`,
  ];

  console.log('\naccount:      ' + (email || 'unknown (profile call failed; the token is still valid)'));
  console.log('refresh token received and NOT printed.');
  if (writeEnv) {
    const file = path.resolve(writeEnv);
    const existing = fs.existsSync(file) ? fs.readFileSync(file, 'utf8').split('\n') : [];
    const kept = existing.filter((line) => line && !line.startsWith(`MAIL_OAUTH2_${segment}_`) && !line.startsWith(`MAIL_IMAP_${segment}_`) && !line.startsWith(`MAIL_SMTP_${segment}_`));
    const next = kept.concat(lines).join('\n') + '\n';
    fs.writeFileSync(file, next, { mode: 0o600 });
    fs.chmodSync(file, 0o600);
    console.log('wrote:        ' + file + ' (0600, ' + lines.length + ' keys for ' + segment + ')');
  } else {
    console.log('\nadd these to the file you pass as mail-mcp\'s env (nothing was written):');
    for (const line of lines) console.log(line.replace(/(REFRESH_TOKEN=).*/, '$1<redacted>'));
    console.log('\n(re-run with --write-env <file> to store them, mode 0600)');
  }
}

main().catch((error) => { console.error('error: ' + error.message); process.exitCode = 2; });
