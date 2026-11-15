// mcp-mail.mjs repairs mail-mcp's API without touching anything else (15/11): a cursor search drops its
// filters, a message_id supplies account_id, tools/list states limit 1..50. Driven end to end through the
// real wrapper against a fake mail-mcp that echoes what it received.
import { spawn } from 'node:child_process';
import fs from 'node:fs'; import os from 'node:os'; import path from 'node:path'; import assert from 'node:assert';
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'mcp-mail-'));
const fake = path.join(dir, 'fake-mail-mcp');
fs.writeFileSync(fake, `#!${process.execPath}
let b='';process.stdin.setEncoding('utf8');process.stdin.on('data',c=>{b+=c;let i;while((i=b.indexOf('\\n'))>=0){const m=JSON.parse(b.slice(0,i));b=b.slice(i+1);
if(m.method==='tools/list'){process.stdout.write(JSON.stringify({jsonrpc:'2.0',id:m.id,result:{tools:[{name:'imap_search_messages',inputSchema:{type:'object',properties:{limit:{type:'integer'}}}},{name:'imap_get_message',inputSchema:{type:'object',properties:{}}}]}})+'\\n');}
else process.stdout.write(JSON.stringify({jsonrpc:'2.0',id:m.id,result:{echo:m.params}})+'\\n');}});`);
fs.chmodSync(fake, 0o755);
const secret = path.join(dir, 'mail.env'); fs.writeFileSync(secret, 'MAIL_IMAP_TEST_HOST=example.invalid\n'); fs.chmodSync(secret, 0o600);
const here = path.dirname(new URL(import.meta.url).pathname);
const child = spawn(process.execPath, [path.join(here, 'mcp-mail.mjs'), '--binding-json', JSON.stringify({ binary: fake, secret_file: secret })], { stdio: ['pipe', 'pipe', 'inherit'] });
const replies = new Map(); let out = '';
child.stdout.setEncoding('utf8');
child.stdout.on('data', (c) => { out += c; let i; while ((i = out.indexOf('\n')) >= 0) { const r = JSON.parse(out.slice(0, i)); out = out.slice(i + 1); replies.set(r.id, r); } });
const send = (m) => child.stdin.write(JSON.stringify(m) + '\n');
send({ jsonrpc: '2.0', id: 1, method: 'tools/list', params: {} });
send({ jsonrpc: '2.0', id: 2, method: 'tools/call', params: { name: 'imap_search_messages', arguments: { account_id: 'a', mailbox: 'INBOX', cursor: 'c1', last_days: 7, unread_only: true, query: 'x', limit: 30 } } });
send({ jsonrpc: '2.0', id: 3, method: 'tools/call', params: { name: 'imap_get_message', arguments: { message_id: 'imap:vicscar_zangao:INBOX:2:65039', body_max_chars: 500 } } });
send({ jsonrpc: '2.0', id: 4, method: 'tools/call', params: { name: 'imap_search_messages', arguments: { account_id: 'a', mailbox: 'INBOX', last_days: 7 } } });
send({ jsonrpc: '2.0', id: 5, method: 'tools/call', params: { name: 'imap_search_messages', arguments: { mailbox: 'INBOX', limit: 5 } } });
send({ jsonrpc: '2.0', id: 6, method: 'tools/call', params: { name: 'imap_list_accounts', arguments: {} } });
setTimeout(() => {
  let checks = 0; const ok = (v, m) => { assert.ok(v, m); checks++; };
  const limit = replies.get(1).result.tools[0].inputSchema.properties.limit;
  // The tools/list answer is byte-for-byte the server's: the approval binds these schemas (15/11 regression).
  ok(limit.minimum === undefined && limit.maximum === undefined && JSON.stringify(limit) === '{"type":"integer"}', 'tools/list is never rewritten: ' + JSON.stringify(limit));
  const paged = replies.get(2).result.echo.arguments;
  ok(paged.cursor === 'c1' && paged.limit === 30 && paged.mailbox === 'INBOX' && paged.last_days === undefined && paged.query === undefined && paged.unread_only === undefined, 'a cursor search drops its filters: ' + JSON.stringify(paged));
  const got = replies.get(3).result.echo.arguments;
  ok(got.account_id === 'vicscar_zangao' && got.body_max_chars === 500, 'account_id comes from the message_id: ' + JSON.stringify(got));
  const plain = replies.get(4).result.echo.arguments;
  ok(plain.last_days === 7, 'a search without a cursor keeps its filters');
  // One configured account (MAIL_IMAP_TEST_HOST): a read without account_id means it; an explicit one is kept
  // (id 4), the message_id's account wins (id 3), and a tool that takes no account gets none (15/11).
  const filled = replies.get(5).result.echo.arguments;
  ok(filled.account_id === 'test' && filled.limit === 5, 'the only account fills a missing account_id: ' + JSON.stringify(filled));
  ok(plain.account_id === 'a', 'an explicit account_id is kept');
  ok(replies.get(6).result.echo.arguments.account_id === undefined, 'list_accounts gets no account_id');
  child.kill(); console.log(JSON.stringify({ ok: true, checks })); process.exit(0);
}, 1500);
