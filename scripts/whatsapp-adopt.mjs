// whatsapp-adopt: move one linked-device session from a Go/whatsmeow store to the Rust/WASI
// wa-whatsapp component's store, offline.
//
//   node scripts/whatsapp-adopt.mjs export --from <COPY of device-keys.db> --out <dir>
//   node scripts/whatsapp-adopt.mjs export --from <copy> --out <dir> --merge-into <kv.sqlite> [--allow-state]
//   node scripts/whatsapp-adopt.mjs check  --json <dev.json> | --kv <kv.sqlite>
//
// It is INERT. It reads a copy, never the live database (the caller passes the copy), writes only
// `dev.json` and `kv.sqlite` under `--out` (or replaces the `dev` key in a kv file the caller names),
// never connects to WhatsApp, never starts or stops a service, and never prints key material.
//
// The output is the `dev` record `wacore::store::Device` persists (`rust/components/wa-whatsapp/src/
// store.rs`): one JSON object whose key pairs are the 64 bytes serde writes for `KeyPair`
// (private 32 || public 32), whose JIDs are the `Jid` struct, and whose `account` is the
// ADVSignedDeviceIdentity protobuf. The Rust checker (`cargo run --example adopt_check -- dev.json`)
// is the proof that the record deserializes and that every public key is the one its private key
// derives; `scripts/test-whatsapp-adopt.mjs` pins the same shape on a synthetic fixture.
//
// Why an importer at all: the linked-device registration is the device's identity (JID + device id,
// Noise key, identity key, signed pre-key and the phone-signed ADV identity), not the library. The
// keys are exportable, so a re-pair is not required *in principle*. That does not make the move
// free: once a Rust client sends with these keys it advances the Signal ratchet, and a rollback to
// the Go store would hold a stale ratchet. docs/WHATSAPP-CUTOVER.md is the runbook, and the
// operator runs it.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { DatabaseSync } from 'node:sqlite';

const PKCS8_X25519 = Buffer.from('302e020100300506032b656e04220420', 'hex');
const DEVICE_DEFAULTS = { app_version_primary: 2, app_version_secondary: 3000, app_version_tertiary: 1042742319 };

function fail(message) {
  console.error('whatsapp-adopt: ' + message);
  process.exitCode = 1;
  process.exit(1);
}
function hex(buf) { return Buffer.from(buf).toString('hex'); }
function unhex(text, bytes, what) {
  if (typeof text !== 'string' || !/^[0-9a-fA-F]*$/.test(text) || text.length !== bytes * 2) {
    fail(`${what} is not ${bytes} bytes of hex`);
  }
  return Buffer.from(text, 'hex');
}
function publicFromPrivate(privateKey) {
  const der = Buffer.concat([PKCS8_X25519, privateKey]);
  const key = crypto.createPrivateKey({ key: der, format: 'der', type: 'pkcs8' });
  const spki = crypto.createPublicKey(key).export({ format: 'der', type: 'spki' });
  return spki.subarray(spki.length - 32);
}
function pair(privateKey, what) {
  if (privateKey.length !== 32) fail(`${what} must be 32 bytes`);
  return [...privateKey, ...publicFromPrivate(privateKey)];
}
function varint(value) {
  const bytes = [];
  while (value > 0x7f) { bytes.push((value & 0x7f) | 0x80); value >>>= 7; }
  bytes.push(value);
  return Buffer.from(bytes);
}
function protoBytes(field, value) {
  return Buffer.concat([Buffer.from([field << 3 | 2]), varint(value.length), value]);
}
// ADVSignedDeviceIdentity: 1 details, 2 account_signature_key, 3 account_signature, 4 device_signature.
function advIdentity(details, accountKey, accountSignature, deviceSignature) {
  const parts = [];
  if (details.length) parts.push(protoBytes(1, details));
  if (accountKey.length) parts.push(protoBytes(2, accountKey));
  if (accountSignature.length) parts.push(protoBytes(3, accountSignature));
  if (deviceSignature.length) parts.push(protoBytes(4, deviceSignature));
  return Buffer.concat(parts);
}
function jid(text, what) {
  const match = /^(?:([0-9]+)(?::([0-9]+))?|([^@]+))@([a-z.]+)$/.exec(String(text || '').trim());
  if (!match) fail(`${what} is not a JID: ${JSON.stringify(text)}`);
  const user = match[1] || match[3];
  return { user, server: match[4], agent: 0, device: match[2] ? Number(match[2]) : 0, integrator: 0 };
}
function numbers(buf) { return Array.from(buf); }

// The one device row, read from a copy. The Go store keeps every key as its 32-byte private key;
// the public half is derived here, which is exactly what the Rust client would have stored at pairing.
function readDevice(source) {
  const db = new DatabaseSync(source, { readOnly: true });
  try {
    const columns = db.prepare('pragma table_info(whatsmeow_device)').all().map((row) => row.name);
    const needed = ['jid', 'lid', 'registration_id', 'noise_key', 'identity_key', 'signed_pre_key',
      'signed_pre_key_id', 'signed_pre_key_sig', 'adv_key', 'adv_details', 'adv_account_sig',
      'adv_account_sig_key', 'adv_device_sig', 'push_name'];
    for (const column of needed) if (!columns.includes(column)) fail(`the copy has no whatsmeow_device.${column}`);
    const rows = db.prepare('select * from whatsmeow_device').all();
    if (rows.length !== 1) fail(`expected exactly one whatsmeow_device row, found ${rows.length}`);
    const row = rows[0];
    const device = {
      pn: jid(row.jid, 'jid'),
      lid: row.lid ? jid(row.lid, 'lid') : null,
      registration_id: Number(row.registration_id),
      noise_key: pair(Buffer.from(row.noise_key), 'noise_key'),
      identity_key: pair(Buffer.from(row.identity_key), 'identity_key'),
      signed_pre_key: pair(Buffer.from(row.signed_pre_key), 'signed_pre_key'),
      signed_pre_key_id: Number(row.signed_pre_key_id),
      signed_pre_key_signature: numbers(Buffer.from(row.signed_pre_key_sig)),
      adv_secret_key: numbers(Buffer.from(row.adv_key)),
      account: numbers(advIdentity(
        Buffer.from(row.adv_details), Buffer.from(row.adv_account_sig_key),
        Buffer.from(row.adv_account_sig), Buffer.from(row.adv_device_sig))),
      push_name: String(row.push_name || ''),
      ...DEVICE_DEFAULTS,
      app_version_last_fetched_ms: 0,
    };
    // Lengths the Rust reader will reject if wrong: check before writing, so a bad copy fails here.
    if (device.signed_pre_key_signature.length !== 64) fail('signed_pre_key_sig must be 64 bytes');
    if (device.adv_secret_key.length !== 32) fail('adv_key must be 32 bytes');
    if (device.account.length < 4) fail('the ADV identity fields are empty');
    if (!Number.isFinite(device.registration_id) || device.registration_id <= 0) fail('registration_id is missing');
    return device;
  } finally {
    db.close();
  }
}

function deviceJson(device) { return Buffer.from(JSON.stringify(device)); }

function writeKv(kvPath, value) {
  const db = new DatabaseSync(kvPath);
  try {
    db.exec('CREATE TABLE IF NOT EXISTS kv(k BLOB PRIMARY KEY, v BLOB NOT NULL)');
    db.prepare('insert into kv(k,v) values(?,?) on conflict(k) do update set v=excluded.v')
      .run(Buffer.from('dev'), value);
  } finally {
    db.close();
  }
}

function checkDevice(device) {
  const problems = [];
  const isJid = (j) => j && typeof j.user === 'string' && j.user.length > 0 && typeof j.server === 'string';
  if (!isJid(device.pn)) problems.push('pn');
  if (device.lid !== null && !isJid(device.lid)) problems.push('lid');
  if (!Number.isInteger(device.registration_id) || device.registration_id <= 0) problems.push('registration_id');
  for (const key of ['noise_key', 'identity_key', 'signed_pre_key']) {
    if (!Array.isArray(device[key]) || device[key].length !== 64) problems.push(key);
    else if (device[key].some((b) => !Number.isInteger(b) || b < 0 || b > 255)) problems.push(key + ' bytes');
  }
  if (!Number.isInteger(device.signed_pre_key_id)) problems.push('signed_pre_key_id');
  if (!Array.isArray(device.signed_pre_key_signature) || device.signed_pre_key_signature.length !== 64) problems.push('signed_pre_key_signature');
  if (!Array.isArray(device.adv_secret_key) || device.adv_secret_key.length !== 32) problems.push('adv_secret_key');
  if (!Array.isArray(device.account) || device.account.length < 4) problems.push('account');
  if (typeof device.push_name !== 'string') problems.push('push_name');
  if (problems.length) fail('not a whatsapp-rust device record: ' + problems.join(', '));
  return {
    pn: `${device.pn.user}${device.pn.device ? ':' + device.pn.device : ''}@${device.pn.server}`,
    lid: device.lid ? `${device.lid.user}${device.lid.device ? ':' + device.lid.device : ''}@${device.lid.server}` : null,
    registration_id: device.registration_id,
    signed_pre_key_id: device.signed_pre_key_id,
    account_bytes: device.account.length,
    push_name_length: device.push_name.length,
  };
}

function parseArgs(argv) {
  const [command, ...rest] = argv;
  const args = { command };
  for (let i = 0; i < rest.length; i++) {
    const token = rest[i];
    if (!token.startsWith('--')) fail('unexpected argument ' + token);
    const key = token.slice(2);
    if (key === 'allow-state' || key === 'force') { args[key] = true; continue; }
    args[key] = rest[++i];
    if (args[key] === undefined) fail('--' + key + ' needs a value');
  }
  return args;
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.command === 'check') {
    const device = args.json
      ? JSON.parse(fs.readFileSync(args.json, 'utf8'))
      : (() => {
          if (!args.kv) fail('check needs --json <dev.json> or --kv <kv.sqlite>');
          const db = new DatabaseSync(args.kv, { readOnly: true });
          try {
            const row = db.prepare('select v from kv where k=?').get(Buffer.from('dev'));
            if (!row) fail('the kv file has no dev key');
            return JSON.parse(Buffer.from(row.v).toString('utf8'));
          } finally { db.close(); }
        })();
    console.log(JSON.stringify({ ok: true, ...checkDevice(device) }));
    return;
  }
  if (args.command === 'fixture') {
    // A deterministic synthetic row, so the committed Rust fixture and this script cannot drift.
    const seed = args.seed || 'wasm-agent-adopt-fixture';
    const bytes = (label) => crypto.createHash('sha256').update(seed + '/' + label).digest();
    const device = {
      pn: jid('5511000000000:9@s.whatsapp.net', 'pn'),
      lid: jid('72103978127547:9@lid', 'lid'),
      registration_id: 123456789,
      noise_key: pair(bytes('noise'), 'noise'),
      identity_key: pair(bytes('identity'), 'identity'),
      signed_pre_key: pair(bytes('signed-pre-key'), 'signed pre key'),
      signed_pre_key_id: 1,
      signed_pre_key_signature: numbers(Buffer.concat([bytes('sig-a'), bytes('sig-b')])),
      adv_secret_key: numbers(bytes('adv-secret')),
      account: numbers(advIdentity(bytes('details'), bytes('account-key'), Buffer.concat([bytes('acct-sig-a'), bytes('acct-sig-b')]), Buffer.concat([bytes('dev-sig-a'), bytes('dev-sig-b')]))),
      push_name: 'fixture',
      ...DEVICE_DEFAULTS,
      app_version_last_fetched_ms: 0,
    };
    const json = deviceJson(device);
    if (args.out) {
      fs.mkdirSync(args.out, { recursive: true, mode: 0o700 });
      fs.writeFileSync(path.join(args.out, 'dev.json'), json, { mode: 0o600 });
      writeKv(path.join(args.out, 'kv.sqlite'), json);
    }
    process.stdout.write(json.toString('utf8'));
    return;
  }
  if (args.command !== 'export') fail('usage: export --from <copy.db> --out <dir> [--merge-into <kv.sqlite>] | check --json|--kv | fixture');
  if (!args.from || !args.out) fail('export needs --from <copy.db> and --out <dir>');
  const out = path.resolve(args.out);
  const mergeInto = args['merge-into'] ? path.resolve(args['merge-into']) : null;
  const destination = mergeInto || path.join(out, 'kv.sqlite');
  // The live component store is never the destination: this tool writes a fresh directory or a copy.
  if (!args['allow-state'] && /[\\/]components[\\/][^\\/]+\.state[\\/]/.test(destination)) {
    fail('refusing to write into a live component state directory; export to a copy and use --allow-state only for a restored copy');
  }
  if (!mergeInto && fs.existsSync(out) && fs.readdirSync(out).length && !args.force) {
    fail(`--out ${out} is not empty; pass --force to overwrite dev.json and kv.sqlite there`);
  }
  const source = path.resolve(args.from);
  if (!fs.existsSync(source)) fail('no such copy: ' + source);
  const stat = fs.statSync(source);
  const device = readDevice(source);
  const summary = checkDevice(device);
  const json = deviceJson(device);
  fs.mkdirSync(out, { recursive: true, mode: 0o700 });
  fs.writeFileSync(path.join(out, 'dev.json'), json, { mode: 0o600 });
  writeKv(destination, json);
  fs.writeFileSync(path.join(out, 'MANIFEST.json'), JSON.stringify({
    tool: 'whatsapp-adopt', version: 1, exported_at: Math.floor(Date.now() / 1000),
    source_bytes: stat.size, source_sha256: crypto.createHash('sha256').update(fs.readFileSync(source)).digest('hex'),
    device: summary, note: 'no key material in this manifest; dev.json is 0600 and holds the keys',
  }, null, 2) + '\n', { mode: 0o600 });
  console.log(JSON.stringify({ ok: true, wrote: { dev_json: path.join(out, 'dev.json'), kv: destination }, ...summary }));
}

main();
