// The cutover exporter's contract (`scripts/whatsapp-adopt.mjs`, docs/WHATSAPP-CUTOVER.md), hermetic:
// a synthetic whatsmeow store, a temp directory, no phone and no node. It pins:
//
//   * one device row in, the `dev` record out: the PN/LID keep their device id, the 32-byte private
//     keys become the 64-byte pairs the Rust store reads (public derived from private), the ADV
//     identity is the ADVSignedDeviceIdentity protobuf, and the record has the fields wacore requires;
//   * the kv file is the host store's schema (`kv(k BLOB PRIMARY KEY, v BLOB NOT NULL)`) with one
//     `dev` key whose bytes are exactly dev.json, and --merge-into preserves the other keys;
//   * the guard rails: a live `components/*.state` destination is refused, a non-empty --out needs
//     --force, and neither stdout nor stderr carries key material;
//   * the deterministic fixture the Rust test (`src/adoption.rs`) reads is what this script generates,
//     byte for byte, so the two ends cannot drift.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite';

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const tool = path.join(repo, 'scripts/whatsapp-adopt.mjs');
const fixture = path.join(repo, 'rust/components/wa-whatsapp/tests/fixtures/adopted-dev.json');

function run(args, options = {}) {
  const result = spawnSync(process.execPath, [tool, ...args], { encoding: 'utf8', windowsHide: true, ...options });
  return result;
}
function seed(label) { return crypto.createHash('sha256').update('adopt-test/' + label).digest(); }
function syntheticStore(dir) {
  const db = new DatabaseSync(path.join(dir, 'device-keys.db'));
  db.exec(`create table whatsmeow_device(jid text primary key, lid text, registration_id integer,
    noise_key blob, identity_key blob, signed_pre_key blob, signed_pre_key_id integer,
    signed_pre_key_sig blob, adv_key blob, adv_details blob, adv_account_sig blob,
    adv_account_sig_key blob, adv_device_sig blob, push_name text, platform text)`);
  db.prepare('insert into whatsmeow_device values(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)').run(
    '5511000000000:9@s.whatsapp.net', '72103978127547:9@lid', 123456789,
    seed('noise'), seed('identity'), seed('signed-pre-key'), 1,
    Buffer.concat([seed('sig-a'), seed('sig-b')]), seed('adv'), seed('details'),
    Buffer.concat([seed('acct-a'), seed('acct-b')]), seed('acct-key'),
    Buffer.concat([seed('dev-a'), seed('dev-b')]), 'Fixture', 'android');
  db.close();
  return path.join(dir, 'device-keys.db');
}
function temp() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-adopt-'));
  return { dir, cleanup: () => fs.rmSync(dir, { recursive: true, force: true }) };
}
function publicFrom(privateKey) {
  const prefix = Buffer.from('302e020100300506032b656e04220420', 'hex');
  const key = crypto.createPrivateKey({ key: Buffer.concat([prefix, privateKey]), format: 'der', type: 'pkcs8' });
  const spki = crypto.createPublicKey(key).export({ format: 'der', type: 'spki' });
  return spki.subarray(spki.length - 32);
}
function noSecret(text) {
  // No 64-hex run (a 32-byte key/private half) and no base64 blob of that size.
  return !/[0-9a-f]{64}/i.test(text) && !/[A-Za-z0-9+/]{43}=/.test(text);
}

test('one whatsmeow device becomes the wacore device record, without leaking keys', () => {
  const { dir, cleanup } = temp();
  try {
    const source = syntheticStore(dir);
    const out = path.join(dir, 'out');
    const exported = run(['export', '--from', source, '--out', out]);
    assert.equal(exported.status, 0, exported.stderr);
    assert.ok(noSecret(exported.stdout) && noSecret(exported.stderr), 'no key material on the tool output');
    const device = JSON.parse(fs.readFileSync(path.join(out, 'dev.json'), 'utf8'));
    assert.deepEqual(device.pn, { user: '5511000000000', server: 's.whatsapp.net', agent: 0, device: 9, integrator: 0 });
    assert.deepEqual(device.lid, { user: '72103978127547', server: 'lid', agent: 0, device: 9, integrator: 0 });
    assert.equal(device.registration_id, 123456789);
    for (const [name, label] of [['noise_key', 'noise'], ['identity_key', 'identity'], ['signed_pre_key', 'signed-pre-key']]) {
      assert.equal(device[name].length, 64, name + ' is a 64-byte pair');
      const priv = Buffer.from(device[name].slice(0, 32));
      assert.deepEqual(priv, seed(label), name + ' keeps the private half');
      assert.deepEqual(Buffer.from(device[name].slice(32)), publicFrom(priv), name + ' derives the public half');
    }
    assert.equal(device.signed_pre_key_signature.length, 64);
    assert.equal(device.adv_secret_key.length, 32);
    assert.equal(device.account[0], 0x0a, 'account starts with details (field 1, length-delimited)');
    assert.equal(device.app_version_primary, 2);
    // The kv is the host store's schema and its value is the exact JSON.
    const kv = new DatabaseSync(path.join(out, 'kv.sqlite'), { readOnly: true });
    const row = kv.prepare('select v from kv where k=?').get(Buffer.from('dev'));
    kv.close();
    assert.ok(row, 'one dev key');
    assert.deepEqual(Buffer.from(row.v), fs.readFileSync(path.join(out, 'dev.json')));
    // check reads either half.
    for (const args of [['check', '--json', path.join(out, 'dev.json')], ['check', '--kv', path.join(out, 'kv.sqlite')]]) {
      const checked = run(args);
      assert.equal(checked.status, 0, checked.stderr);
      assert.equal(JSON.parse(checked.stdout).ok, true);
      assert.ok(noSecret(checked.stdout));
    }
    // The manifest carries the source hash, not the keys.
    const manifest = fs.readFileSync(path.join(out, 'MANIFEST.json'), 'utf8');
    // The manifest keeps a source hash (not key material) and the non-secret facts, never the record.
    const facts = JSON.parse(manifest);
    assert.equal(facts.device.pn, '5511000000000:9@s.whatsapp.net');
    assert.equal(facts.dev, undefined);
    assert.equal(manifest.includes('noise_key'), false);
  } finally { cleanup(); }
});

test('the guard rails: a live state dir, a non-empty out, and merge preserving other keys', () => {
  const { dir, cleanup } = temp();
  try {
    const source = syntheticStore(dir);
    const live = path.join(dir, 'components', 'wa-whatsapp.state', 'kv.sqlite');
    fs.mkdirSync(path.dirname(live), { recursive: true });
    const refused = run(['export', '--from', source, '--out', path.join(dir, 'x'), '--merge-into', live]);
    assert.equal(refused.status, 1);
    assert.match(refused.stderr, /refusing to write into a live component state directory/);
    assert.equal(fs.existsSync(live), false, 'the live path was not created');

    const out = path.join(dir, 'out');
    assert.equal(run(['export', '--from', source, '--out', out]).status, 0);
    assert.equal(run(['export', '--from', source, '--out', out]).status, 1, 'a non-empty out needs --force');
    assert.equal(run(['export', '--from', source, '--out', out, '--force']).status, 0);

    // A merge into a copy keeps the index/queue keys around the device.
    const copy = path.join(dir, 'copy.sqlite');
    const kv = new DatabaseSync(copy);
    kv.exec('create table kv(k blob primary key, v blob not null)');
    kv.prepare('insert into kv values(?,?)').run(Buffer.from('q/keep'), Buffer.from('untouched'));
    kv.close();
    const merged = run(['export', '--from', source, '--out', out, '--merge-into', copy]);
    assert.equal(merged.status, 0, merged.stderr);
    const read = new DatabaseSync(copy, { readOnly: true });
    assert.equal(read.prepare('select count(*) n from kv').get().n, 2);
    assert.deepEqual(Buffer.from(read.prepare('select v from kv where k=?').get(Buffer.from('q/keep')).v), Buffer.from('untouched'));
    assert.ok(read.prepare('select v from kv where k=?').get(Buffer.from('dev')));
    read.close();
  } finally { cleanup(); }
});

test('the committed fixture is what the fixture mode generates', () => {
  const { dir, cleanup } = temp();
  try {
    const generated = run(['fixture', '--out', dir]);
    assert.equal(generated.status, 0, generated.stderr);
    assert.deepEqual(fs.readFileSync(path.join(dir, 'dev.json')), fs.readFileSync(fixture),
      'regenerate the fixture with: node scripts/whatsapp-adopt.mjs fixture --out <dir>');
  } finally { cleanup(); }
});
