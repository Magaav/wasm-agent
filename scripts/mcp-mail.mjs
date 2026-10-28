#!/usr/bin/env node
// MCP proxy for mail-mcp: the only place a mail credential exists in a child process.
//
// The host cannot pass literal environment values to a spawned MCP server - `server.env` is a map of
// references to variables already in the host's own environment - so the secrets file has to be read by
// something that then execs the real server. That is this file, and it is why it exists rather than the
// facade handing mail-mcp its keys directly.
//
//   node scripts/mcp-mail.mjs --binding-json '{"binary":"...","secret_file":"..."}'
//
// Responsibilities, in order:
//   1. refuse a secrets file that any other user can read (mode 0600 or tighter);
//   2. refuse anything in it that is not a `MAIL_*` assignment, so a compromised file cannot set PATH,
//      NODE_OPTIONS or HOME for the child;
//   3. spawn mail-mcp with exactly those keys plus a minimal environment;
//   4. refuse `tools/call` for a write tool unless writes were explicitly enabled for this process.
//
// The write gate is here and not only in Lua because this is the process boundary: an approval decided
// somewhere else must still be presented here, or nothing that mutates mail leaves the machine.
import { spawn } from 'node:child_process';
import fs from 'node:fs';

const WRITE_TOOLS = new Set([
  'smtp_send_message', 'smtp_reply_message', 'smtp_forward_message',
  'draft_create', 'draft_update', 'draft_delete', 'draft_send',
  'imap_append_message', 'imap_delete_message', 'imap_move_message', 'imap_copy_message',
  'imap_update_message_flags', 'imap_bulk_delete', 'imap_bulk_move', 'imap_bulk_update_flags',
  'imap_create_mailbox', 'imap_delete_mailbox', 'imap_rename_mailbox',
  'imap_search_and_delete', 'imap_search_and_move',
  'graph_send_message', 'ews_send_message',
]);

function fail(reason, extra) {
  process.stderr.write(JSON.stringify({ ok: false, error: reason, ...extra }) + '\n');
  process.exit(1);
}

const at = process.argv.indexOf('--binding-json');
if (at < 0 || !process.argv[at + 1]) fail('mail_binding_required');
let binding = null;
try { binding = JSON.parse(process.argv[at + 1]); } catch { fail('mail_binding_invalid'); }
if (!binding || typeof binding.binary !== 'string' || typeof binding.secret_file !== 'string') fail('mail_binding_incomplete');

const secretFile = binding.secret_file;
if (!fs.existsSync(secretFile)) fail('mail_secret_file_missing', { file: secretFile });

// 0600 or tighter. A credential every process on the box can read is not stored, it is published.
const mode = fs.statSync(secretFile).mode & 0o777;
if ((mode & 0o077) !== 0) fail('mail_secret_file_too_open', { file: secretFile, mode: '0' + mode.toString(8), required: '0600' });

const keys = {};
const problems = [];
for (const raw of fs.readFileSync(secretFile, 'utf8').split('\n')) {
  const line = raw.trim();
  if (!line || line.startsWith('#')) continue;
  const eq = line.indexOf('=');
  if (eq < 0) { problems.push('not_an_assignment'); continue; }
  const key = line.slice(0, eq);
  const value = line.slice(eq + 1);
  if (!/^MAIL_[A-Z0-9_]+$/.test(key)) { problems.push('foreign_key:' + key); continue; }
  keys[key] = value;
}
if (problems.length) fail('mail_secret_file_rejected', { problems: problems.slice(0, 5) });
if (!Object.keys(keys).length) fail('mail_secret_file_empty', { file: secretFile });

const allowed = /^(PATH|HOME|USERPROFILE|LANG|LC_ALL|TMPDIR|TEMP|TMP|SYSTEMROOT|WINDIR|USER|LOGNAME)$/;
const env = {};
for (const [k, v] of Object.entries(process.env)) if (allowed.test(k)) env[k] = v;
Object.assign(env, keys);
if (binding.log_level) env.RUST_LOG = String(binding.log_level);

const writesEnabled = process.env.WA_MAIL_WRITES === 'enabled' || binding.writes === 'enabled';
const child = spawn(binding.binary, [], { env, stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true });

child.on('error', (error) => fail('mail_binary_unusable', { message: error.message }));
child.stderr.pipe(process.stderr);
child.on('exit', (code, signal) => { process.exitCode = typeof code === 'number' ? code : (signal ? 1 : 0); });

// Requests are forwarded verbatim except for the write gate; responses flow back untouched.
let buffer = '';
const answerLocally = (id, reason, tool) => {
  const reply = { jsonrpc: '2.0', id, error: { code: -32000, message: reason, data: { tool, refused_before_dispatch: true } } };
  process.stdout.write(JSON.stringify(reply) + '\n');
};

process.stdin.setEncoding('utf8');
process.stdin.on('data', (chunk) => {
  buffer += chunk;
  let index;
  while ((index = buffer.indexOf('\n')) >= 0) {
    const line = buffer.slice(0, index).trim();
    buffer = buffer.slice(index + 1);
    if (!line) continue;
    let message = null;
    try { message = JSON.parse(line); } catch { child.stdin.write(line + '\n'); continue; }
    if (message.method === 'tools/call' && WRITE_TOOLS.has(message.params?.name) && !writesEnabled) {
      answerLocally(message.id ?? null, 'mail_writes_not_enabled', message.params?.name);
      continue;
    }
    child.stdin.write(line + '\n');
  }
});
process.stdin.on('end', () => { try { child.stdin.end(); } catch { /* already closed */ } });
child.stdout.pipe(process.stdout);
