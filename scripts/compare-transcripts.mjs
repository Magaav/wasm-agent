#!/usr/bin/env node
// Compare a shadow run of the `wa-whatsapp` component with the Go connector's journal, side by side.
//
//   node scripts/compare-transcripts.mjs --log <component.log> --journal <journal.db> [--limit N] [--json]
//   node scripts/compare-transcripts.mjs <component.log> <journal.db>
//
// Both sides are read as METADATA ONLY, by construction:
//
// * the component side is the stable `wa-transcript v=1 …` key=value lines the component writes into
//   its own service log (rust/components/wa-whatsapp/src/telemetry.rs). They carry ids, states,
//   reasons and durations — never the audio's or the transcript's text;
// * the journal side is SQL over the Go connector's `audio`/`messages`/`outbox` tables, and the only
//   thing it ever selects from `transcript` or `body` is `length(...)`. No transcript text is read
//   into this process, printed or put in the JSON output. The journal is opened read-only.
//
// The table answers the one question a shadow run is for: does the component recognize the same
// messages, with the same amount of text, and how long did it take (download, first segment, total)?
//
// The journal is read with `node:sqlite` when the runtime has it (Node 24 here) and with the
// read-only `sqlite3` CLI otherwise; neither available is an error, never a guess.
//
// Exit status: 0 when the comparison ran (differences are the report, not a failure), 2 on bad usage,
// 1 when either input could not be read.

import fs from 'node:fs';
import { createHash } from 'node:crypto';
import { createRequire } from 'node:module';
import { spawnSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';

const require = createRequire(import.meta.url);
const PREFIX = 'wa-transcript ';

// ── the join identity ────────────────────────────────────────────────────────────────────────────
// A component log line carries the chat and the message id as a digest (`sha256:` + the first 16 bytes,
// hex - `rust/components/wa-whatsapp/src/privacy.rs`), because a log line may not name a JID. The
// journal has the JID. Both sides are compared on the digest, so the table still joins: a value that is
// already a mark is used as it is, and a raw one (the journal's, or an older log's) is digested to
// match it. The table prints what each side said; only the join key is normalized.
const MARK = 'sha256:';

/// The comparison key for one identity. Stable across runs, so a shadow run's rows group as before.
export function identity(value) {
  const text = value === undefined || value === null || value === '' ? '-' : String(value);
  if (text.startsWith(MARK)) return text;
  return MARK + createHash('sha256').update(text, 'utf8').digest('hex').slice(0, 32);
}
const USAGE = `usage: node scripts/compare-transcripts.mjs --log <component.log> --journal <journal.db> [--limit N] [--json]

  --log       the wa-whatsapp component's service log (its \`wa-transcript\` lines are the component side)
  --journal   the Go connector's journal.db (opened read-only; only ids, states and counts are read)
  --limit N   how many journal rows to compare (default 50, newest first)
  --json      machine-readable output
Both paths may also be given as the first two positional arguments.`;

function parseArgs(argv) {
  const opts = { limit: 50, json: false };
  const positional = [];
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--help' || arg === '-h') { opts.help = true; continue; }
    if (arg === '--json') { opts.json = true; continue; }
    if (arg === '--log' || arg === '--journal' || arg === '--limit') {
      const value = argv[i + 1];
      if (value === undefined) throw new Error(`${arg} needs a value\n${USAGE}`);
      i += 1;
      if (arg === '--log') opts.log = value;
      else if (arg === '--journal') opts.journal = value;
      else opts.limit = Math.max(1, Number.parseInt(value, 10) || 50);
      continue;
    }
    if (arg.startsWith('-')) throw new Error(`unknown option ${arg}\n${USAGE}`);
    positional.push(arg);
  }
  if (!opts.log && positional.length > 0) opts.log = positional.shift();
  if (!opts.journal && positional.length > 0) opts.journal = positional.shift();
  if (positional.length > 0) throw new Error(`unexpected argument(s): ${positional.join(' ')}\n${USAGE}`);
  return opts;
}

// ── the component side: the `wa-transcript` lines, one record per (chat, id) and kind ────────────
export function parseComponentLog(text) {
  const notes = new Map();
  for (const line of text.split(/\r?\n/)) {
    const at = line.indexOf(PREFIX);
    if (at < 0) continue;
    const fields = {};
    for (const pair of line.slice(at + PREFIX.length).trim().split(' ')) {
      if (!pair) continue;
      const eq = pair.indexOf('=');
      if (eq <= 0) continue;
      fields[pair.slice(0, eq)] = pair.slice(eq + 1);
    }
    if (fields.v !== '1' || !fields.kind) continue;
    // The join key is the digest of both identities, whatever spelling each side used.
    const key = `${identity(fields.chat)}\u0000${identity(fields.id)}`;
    const note = notes.get(key) || { chat: fields.chat || '-', id: fields.id || '-', kinds: [], fields: {} };
    if (!note.kinds.includes(fields.kind)) note.kinds.push(fields.kind);
    // Later lines for the same kind win (a retry reports again); ready/posted/failed are separate
    // kinds, so nothing is overwritten by the disposition of the same note.
    Object.assign(note.fields, fields);
    notes.set(key, note);
  }
  return notes;
}

// ── the journal side: ids, states and counts, never text ────────────────────────────────────────
function journalQuery(withOutbox, limit) {
  const posted = withOutbox
    ? `(SELECT min(o.created) FROM outbox o WHERE o.account=a.account AND o.generation=a.generation
          AND o.chat=a.chat AND o.source=a.id)`
    : 'NULL';
  // length(a.transcript) is the only thing read from the transcript column, and length(o.body) the
  // only thing read from a post's body: the counts a comparison needs, and nothing that is text.
  return `SELECT a.chat AS chat, a.id AS id, a.state AS state, a.reason AS reason,
                 length(a.transcript) AS chars, a.language AS language, ${posted} AS posted_at,
                 m.sent AS sent_at
          FROM audio a
          LEFT JOIN messages m ON m.account=a.account AND m.generation=a.generation
                              AND m.chat=a.chat AND m.id=a.id
          ORDER BY m.sent DESC, a.rowid DESC
          LIMIT ${Number(limit)}`;
}

const COLUMNS = ['chat', 'id', 'state', 'reason', 'chars', 'language', 'posted_at', 'sent_at'];

/// Rows by column name, whatever the driver called them (node:sqlite hands objects, sqlite3 arrays).
function fromRows(rows, byName = false) {
  return rows.map((raw) => {
    const row = byName ? COLUMNS.map((name) => raw[name]) : raw;
    return ({
    chat: String(row[0] ?? ''),
    id: String(row[1] ?? ''),
    state: String(row[2] ?? ''),
    reason: String(row[3] ?? ''),
    chars: row[4] === null || row[4] === undefined ? null : Number(row[4]),
    language: row[5] === null || row[5] === undefined ? '' : String(row[5]),
    posted_at: row[6] === null || row[6] === undefined ? null : Number(row[6]),
      sent_at: row[7] === null || row[7] === undefined ? null : Number(row[7]),
    });
  });
}

export async function readJournal(path, limit) {
  if (!fs.existsSync(path)) throw new Error(`journal not found: ${path}`);
  // node:sqlite first (no external dependency), read-only; sqlite3(1) as the fallback. Neither
  // available is a reason to refuse the comparison, not to guess at the journal's shape.
  try {
    const { DatabaseSync } = await import('node:sqlite');
    const db = new DatabaseSync(path, { readOnly: true });
    try {
      let rows;
      try {
        rows = db.prepare(journalQuery(true, limit)).all();
      } catch {
        // A journal older than the `outbox.created` migration: the same comparison without it.
        rows = db.prepare(journalQuery(false, limit)).all();
      }
      return { rows: fromRows(rows, true), source: 'node:sqlite' };
    } finally {
      db.close();
    }
  } catch (error) {
    const query = journalQuery(true, limit);
    const run = spawnSync('sqlite3', ['-readonly', '-json', path, query], { encoding: 'utf8', timeout: 120000 });
    if (run.error || run.status !== 0) {
      throw new Error(`journal unreadable with node:sqlite (${error.message}) and sqlite3 (${run.error?.message || run.stderr?.trim()})`);
    }
    const parsed = JSON.parse(run.stdout || '[]');
    return { rows: fromRows(parsed, true), source: 'sqlite3' };
  }
}

// ── the comparison ───────────────────────────────────────────────────────────────────────────────
const LAST_KIND_ORDER = ['posted', 'failed', 'expired', 'blocked', 'held', 'shadow', 'ready'];

function compare(notes, journal) {
  const index = new Map();
  for (const row of journal) index.set(`${identity(row.chat)}\u0000${identity(row.id)}`, row);
  const keys = new Set([...notes.keys(), ...index.keys()]);
  const rows = [];
  for (const key of keys) {
    const note = notes.get(key);
    const row = index.get(key);
    const componentChars = note?.fields.chars !== undefined && note.fields.chars !== '-' ? Number(note.fields.chars) : null;
    let verdict = 'chars equal';
    if (!note) verdict = 'component missing';
    else if (!row) verdict = 'journal missing';
    else if (componentChars === null) verdict = 'component chars unknown';
    else if (row.chars === null) verdict = 'journal chars unknown';
    else if (componentChars !== row.chars) verdict = `chars differ ${componentChars} vs ${row.chars}`;
    rows.push({
      key,
      chat: note?.chat ?? row.chat,
      id: note?.id ?? row.id,
      kinds: note ? note.kinds.join('+') : '-',
      download_ms: numberOrNull(note?.fields.download_ms),
      first_segment_ms: numberOrNull(note?.fields.first_segment_ms),
      total_ms: numberOrNull(note?.fields.total_ms),
      component_chars: componentChars,
      segments: numberOrNull(note?.fields.segments),
      state: row?.state ?? '-',
      reason: row?.reason || '-',
      journal_chars: row?.chars ?? null,
      verdict,
    });
  }
  rows.sort((a, b) => (a.chat === b.chat ? a.id.localeCompare(b.id) : a.chat.localeCompare(b.chat)));
  const counts = {
    component_notes: notes.size,
    journal_audio: journal.length,
    matched: rows.filter((r) => r.kinds !== '-' && r.state !== '-').length,
    chars_equal: rows.filter((r) => r.verdict === 'chars equal').length,
    chars_differ: rows.filter((r) => r.verdict.startsWith('chars differ')).length,
    component_missing: rows.filter((r) => r.verdict === 'component missing').length,
    journal_missing: rows.filter((r) => r.verdict === 'journal missing').length,
  };
  return { rows, counts };
}

function numberOrNull(value) {
  if (value === undefined || value === null || value === '' || value === '-') return null;
  const n = Number(value);
  return Number.isFinite(n) ? n : null;
}

function table(rows) {
  const head = ['chat', 'id', 'kind', 'dl_ms', 'first_ms', 'total_ms', 'c_chars', 'seg', 'journal_state', 'j_reason', 'j_chars', 'verdict'];
  const cell = (v) => (v === null || v === undefined || v === '' ? '-' : String(v));
  const body = rows.map((r) => [
    r.chat, r.id, r.kinds, cell(r.download_ms), cell(r.first_segment_ms), cell(r.total_ms),
    cell(r.component_chars), cell(r.segments), r.state, r.reason, cell(r.journal_chars), r.verdict,
  ]);
  const widths = head.map((h, i) => Math.max(h.length, ...body.map((row) => row[i].length)));
  const line = (row) => row.map((v, i) => (i === row.length - 1 ? v : v.padEnd(widths[i]))).join('  ');
  return [line(head), line(widths.map((w) => '-'.repeat(w))), ...body.map(line)].join('\n');
}

async function main() {
  let opts;
  try {
    opts = parseArgs(process.argv.slice(2));
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    return 2;
  }
  if (opts.help) { process.stdout.write(`${USAGE}\n`); return 0; }
  if (!opts.log || !opts.journal) {
    process.stderr.write(`${USAGE}\n`);
    return 2;
  }
  let logText;
  try {
    logText = fs.readFileSync(opts.log, 'utf8');
  } catch (error) {
    process.stderr.write(`component log unreadable: ${error.message}\n`);
    return 1;
  }
  let journal;
  try {
    journal = await readJournal(opts.journal, opts.limit);
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    return 1;
  }
  const { rows, counts } = compare(parseComponentLog(logText), journal.rows);
  if (opts.json) {
    process.stdout.write(`${JSON.stringify({ log: opts.log, journal: opts.journal, journal_source: journal.source, counts, rows }, null, 2)}\n`);
    return 0;
  }
  process.stdout.write('component = wa-whatsapp log (metadata lines)   journal = Go connector journal.db (read-only, text never read)\n');
  process.stdout.write(`${table(rows)}\n`);
  process.stdout.write(
    `\nnotes ${counts.component_notes} · journal audio ${counts.journal_audio} · matched ${counts.matched} · ` +
      `chars equal ${counts.chars_equal}, differ ${counts.chars_differ} · component-only ${counts.journal_missing}, journal-only ${counts.component_missing}\n`,
  );
  return 0;
}

// Executed, not imported: `scripts/test-whatsapp-compare-transcripts.mjs` imports the two parsers
// above, and its own name ends with `compare-transcripts.mjs` - a suffix test would run main().
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().then((code) => {
    process.exitCode = code;
  });
}
