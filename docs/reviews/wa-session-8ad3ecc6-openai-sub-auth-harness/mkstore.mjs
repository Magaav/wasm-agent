// Write a credential store fixture (reviewer's own), and print fingerprints only.
import fs from 'node:fs';
import crypto from 'node:crypto';

const fp = t => crypto.createHash('sha256').update(String(t)).digest('hex').slice(0, 12);
const b64 = v => Buffer.from(JSON.stringify(v)).toString('base64url');
const access = acct => `${b64({ alg: 'none', typ: 'JWT' })}.${b64({
  'https://api.openai.com/auth': { chatgpt_account_id: acct },
  exp: Math.floor(Date.now() / 1000) + 3600,
})}.reviewer`;

const [storePath, seedPath, account = 'acct-reviewer-0001', expiresOffset = '-60000'] = process.argv.slice(2);
const seed = fs.readFileSync(seedPath, 'utf8').trim();
fs.mkdirSync(storePath.replace(/\/[^/]+$/, ''), { recursive: true });
fs.writeFileSync(storePath, JSON.stringify({
  version: 1, provider: 'openai-codex', type: 'oauth',
  access: access(account), refresh: seed, expires: Date.now() + Number(expiresOffset),
  account_id: account, refreshes: 0, source: 'reviewer-fixture',
  access_fingerprint: fp(access(account)), refresh_fingerprint: fp(seed),
}));
process.stdout.write(JSON.stringify({ store: storePath, seed_fp: fp(seed) }) + '\n');
