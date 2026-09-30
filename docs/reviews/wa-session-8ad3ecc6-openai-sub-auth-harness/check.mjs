// Count what the fixture saw and compare the store's rotating token to what the fixture issued.
// Prints counts and fingerprints only, never a token value.
import fs from 'node:fs';
import crypto from 'node:crypto';

const fp = t => crypto.createHash('sha256').update(String(t)).digest('hex').slice(0, 12);
const lines = file => { try { return fs.readFileSync(file, 'utf8').split('\n').filter(Boolean).map(l => JSON.parse(l)); }
  catch { return []; } };
const [dir, storePath, seedPath] = process.argv.slice(2);
const posts = lines(`${dir}/posts.jsonl`);
const issued = lines(`${dir}/issued.jsonl`);
const seed = fs.existsSync(seedPath) ? fs.readFileSync(seedPath, 'utf8').trim() : null;
const store = fs.existsSync(storePath) ? JSON.parse(fs.readFileSync(storePath, 'utf8')) : null;
const out = {
  token_posts: posts.filter(p => p.path === '/oauth/token').length,
  refresh_posts: posts.filter(p => p.grant_type === 'refresh_token').length,
  device_posts: posts.filter(p => p.path && p.path.includes('deviceauth')).length,
  refresh_posts_by_presented_fp: posts.filter(p => p.grant_type === 'refresh_token').map(p => p.presented_fp),
  issued_count: issued.length,
  issued_fps: issued.map(i => i.refresh_fp),
  seed_fp: seed ? fp(seed) : null,
  store_refresh_fp: store ? (store.refresh_fingerprint || null) : null,
  store_refresh_matches_seed: store && seed ? store.refresh === seed : null,
  store_refreshes: store ? store.refreshes : null,
  store_last_error: store ? (store.last_error ? store.last_error.code : null) : null,
  store_has_access_token_field: store ? typeof store.access === 'string' && store.access.length > 20 : null,
  store_source: store ? store.source : null,
};
console.log(JSON.stringify(out, null, 1));
