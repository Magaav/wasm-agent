// The comparison script reads METADATA ONLY: this test makes a journal whose transcript text is a
// canary, runs `scripts/compare-transcripts.mjs` against it, and fails if the canary (or any other
// transcript text) reaches stdout, stderr or the --json output.
//
//   node --test scripts/test-whatsapp-compare-transcripts.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { DatabaseSync } from 'node:sqlite';
import { identity, parseComponentLog } from './compare-transcripts.mjs';

const SCRIPT = path.resolve('scripts/compare-transcripts.mjs');
const CANARY = 'texto-secreto-do-transcrito-nao-pode-sair';
const CANARY_TWO = 'outro-texto-secreto-que-nao-pode-sair';
const CHAT = '5511999999999@s.whatsapp.net';
const OWN = '5511888888888@s.whatsapp.net';

function fixture() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-compare-'));
  const dbPath = path.join(dir, 'journal.db');
  const db = new DatabaseSync(dbPath);
  db.exec(`
    CREATE TABLE messages(account TEXT, generation INTEGER, chat TEXT, id TEXT, sent INTEGER, observed INTEGER, PRIMARY KEY(account,generation,chat,id));
    CREATE TABLE audio(account TEXT, generation INTEGER, chat TEXT, id TEXT, state TEXT, reason TEXT, transcript TEXT, language TEXT, PRIMARY KEY(account,generation,chat,id));
    CREATE TABLE outbox(account TEXT, generation INTEGER, chat TEXT, source TEXT, part INTEGER, body TEXT, created INTEGER, PRIMARY KEY(account,generation,chat,source,part));
  `);
  const audio = db.prepare('INSERT INTO audio(account,generation,chat,id,state,reason,transcript,language) VALUES(?,?,?,?,?,?,?,?)');
  const message = db.prepare('INSERT INTO messages(account,generation,chat,id,sent,observed) VALUES(?,?,?,?,?,?)');
  const outbox = db.prepare('INSERT INTO outbox(account,generation,chat,source,part,body,created) VALUES(?,?,?,?,?,?,?)');
  audio.run('acct', 1, CHAT, 'AUDIO-A', 'transcribed', '', CANARY, 'pt');
  message.run('acct', 1, CHAT, 'AUDIO-A', 1_700_000_100, 1_700_000_101);
  outbox.run('acct', 1, CHAT, 'AUDIO-A', 0, `🤖 _Copiloto_\n${CANARY}`, 1_700_000_102);
  audio.run('acct', 1, OWN, 'AUDIO-B', 'failed', 'no_speech_detected', '', 'pt');
  message.run('acct', 1, OWN, 'AUDIO-B', 1_700_000_200, 1_700_000_201);
  // A component-only note (the journal never saw it) carries the second canary in its log line as
  // ids only - the script must print the ids and the counts, never the text.
  audio.run('acct', 1, OWN, 'AUDIO-C', 'transcribed', '', CANARY_TWO, 'pt');
  db.close();
  const logPath = path.join(dir, 'wa-whatsapp.service.log');
  fs.writeFileSync(
    logPath,
    [
      '[   11.02s] message chat=5511999999999@s.whatsapp.net kind=chat media=audio id=AUDIO-A',
      `[   12.40s] wa-transcript v=1 kind=ready chat=${CHAT} id=AUDIO-A state=transcribed download_ms=250 first_segment_ms=1500 recognize_ms=4000 total_ms=4700 since_sent_ms=4900 chars=${CANARY.length} segments=3 streamed=true`,
      '[   12.41s] transcript ready chat=5511999999999@s.whatsapp.net id=AUDIO-A ms=4000 chars=41 latency_ms=4900 download_ms=250 wait_ms=200 seconds=7 segments=3',
      '[   13.00s] wa-transcript v=1 kind=shadow chat=5511999999999@s.whatsapp.net id=AUDIO-A reason=shadow',
      `[   21.00s] wa-transcript v=1 kind=failed chat=${OWN} id=AUDIO-B stage=recognize reason=no_speech_detected`,
      `[   22.00s] wa-transcript v=1 kind=ready chat=${OWN} id=AUDIO-C state=transcribed download_ms=190 first_segment_ms=- recognize_ms=800 total_ms=1100 since_sent_ms=1200 chars=31 segments=1 streamed=false`,
    ].join('\n'),
  );
  return { dir, dbPath, logPath };
}

function run(args) {
  const out = spawnSync(process.execPath, [SCRIPT, ...args], { encoding: 'utf8', timeout: 120000 });
  return { status: out.status, stdout: out.stdout, stderr: out.stderr };
}

test('the component log is parsed into one record per chat, id and kind', () => {
  const { logPath } = fixture();
  const notes = parseComponentLog(fs.readFileSync(logPath, 'utf8'));
  // The join identity is the digest of each id, whatever spelling the log used.
  const a = notes.get(`${identity(CHAT)}\u0000${identity('AUDIO-A')}`);
  assert.ok(a, 'the ready note is found');
  assert.deepEqual(a.kinds, ['ready', 'shadow'], 'the disposition is a second kind, not an overwrite');
  assert.equal(a.fields.chars, String(CANARY.length));
  assert.equal(a.fields.first_segment_ms, '1500');
  const b = notes.get(`${identity(OWN)}\u0000${identity('AUDIO-B')}`);
  assert.deepEqual(b.kinds, ['failed']);
  assert.equal(b.fields.reason, 'no_speech_detected');
});

test('the table joins both sides and never prints transcript text', () => {
  const { dbPath, logPath } = fixture();
  const out = run(['--log', logPath, '--journal', dbPath]);
  assert.equal(out.status, 0, out.stderr);
  assert.match(out.stdout, /notes 3 · journal audio 3/);
  for (const id of ['AUDIO-A', 'AUDIO-B', 'AUDIO-C']) assert.ok(out.stdout.includes(id), `the table names ${id}`);
  assert.ok(out.stdout.includes('chars equal'), 'the matching note is marked equal');
  assert.ok(out.stdout.includes('no_speech_detected'), 'the journal reason is shown');
  assert.ok(out.stdout.includes('ready+shadow'), 'the component kinds are shown together');
  for (const canary of [CANARY, CANARY_TWO]) {
    assert.ok(!out.stdout.includes(canary), `the transcript text "${canary}" must never be printed`);
    assert.ok(!out.stderr.includes(canary));
  }
});

test('--json is metadata only too', () => {
  const { dbPath, logPath } = fixture();
  const out = run(['--log', logPath, '--journal', dbPath, '--json']);
  assert.equal(out.status, 0, out.stderr);
  const report = JSON.parse(out.stdout);
  assert.equal(report.journal_source, 'node:sqlite');
  assert.equal(report.counts.component_notes, 3);
  assert.equal(report.counts.chars_equal, 1);
  const a = report.rows.find((row) => row.id === 'AUDIO-A');
  assert.equal(a.component_chars, CANARY.length);
  assert.equal(a.journal_chars, CANARY.length);
  assert.equal(a.verdict, 'chars equal');
  assert.equal(a.first_segment_ms, 1500);
  assert.equal(a.download_ms, 250);
  const text = JSON.stringify(report);
  assert.ok(!text.includes(CANARY) && !text.includes(CANARY_TWO), 'no transcript text in the JSON');
});

test('a note the other side did not see is reported, not hidden', () => {
  const { dbPath, logPath } = fixture();
  const out = run(['--log', logPath, '--journal', dbPath, '--json']);
  const report = JSON.parse(out.stdout);
  // AUDIO-B is in both sides; AUDIO-C is a journal row the component never reported; there is no
  // component-only note in this fixture beyond the ones the journal has.
  assert.equal(report.counts.journal_audio, 3);
  assert.equal(report.rows.length, 3);
  const b = report.rows.find((row) => row.id === 'AUDIO-B');
  assert.equal(b.verdict, 'component chars unknown', 'a failed recognition has no chars to compare');
});

test('a log whose ids are marks (the component\'s privacy rule) still joins the journal', () => {
  // This build writes `chat=sha256:…` / `id=sha256:…` (`privacy.rs`), and the journal has the JIDs: the
  // table must still join, or a shadow run would silently report "journal missing" for every audio.
  const { dir, dbPath } = fixture();
  const logPath = path.join(dir, 'wa-whatsapp.marked.log');
  fs.writeFileSync(
    logPath,
    [
      `[   12.40s] wa-transcript v=1 kind=ready chat=${identity(CHAT)} id=${identity('AUDIO-A')} state=transcribed download_ms=250 first_segment_ms=1500 chars=${CANARY.length} segments=3`,
      `[   21.00s] wa-transcript v=1 kind=failed chat=${identity(OWN)} id=${identity('AUDIO-B')} stage=recognize reason=no_speech_detected`,
    ].join('\n'),
  );
  const out = run(['--log', logPath, '--journal', dbPath, '--json']);
  assert.equal(out.status, 0, out.stderr);
  const report = JSON.parse(out.stdout);
  const a = report.rows.find((row) => row.chat === identity(CHAT) && row.id === identity('AUDIO-A'));
  assert.ok(a, 'the marked note joined its journal row');
  assert.equal(a.verdict, 'chars equal');
  assert.equal(a.journal_chars, CANARY.length);
  assert.ok(a.chat.startsWith('sha256:') && a.id.startsWith('sha256:'), 'the component side stays marks, never a JID');
  for (const text of [out.stdout, out.stderr]) {
    assert.ok(!text.includes(CANARY) && !text.includes(CANARY_TWO), 'no transcript text');
  }
});

test('bad usage is 2, an unreadable journal is 1', () => {
  assert.equal(run([]).status, 2);
  const { logPath } = fixture();
  const out = run(['--log', logPath, '--journal', path.join(os.tmpdir(), 'no-such-journal.db')]);
  assert.equal(out.status, 1);
  assert.match(out.stderr, /journal not found/);
});
