// Read-only facts about the LIVE wave store (never written by this review).
import {DatabaseSync} from 'node:sqlite';
import fs from 'node:fs';

const dir = process.argv[2];
const db = new DatabaseSync(dir + '/waves.sqlite', {readOnly: true});
console.log('columns:', JSON.stringify(db.prepare("SELECT name FROM pragma_table_info('waves')").all().map(r => r.name)));
console.log('indexes:', JSON.stringify(db.prepare("SELECT name FROM sqlite_master WHERE type='index'").all().map(r => r.name)));
for (const row of db.prepare('SELECT * FROM waves ORDER BY created_at').all()) {
  console.log('row:', JSON.stringify({id: row.id, state: row.state, reason: row.reason, created_at: row.created_at, updated_at: row.updated_at, legacy_set: row.legacy !== null}));
  if (row.legacy) { const l = JSON.parse(row.legacy); console.log('   legacy:', JSON.stringify({kind: l.kind, wave_id: l.wave_id, at: l.at, by: l.by, why: l.why})); }
}
console.log('steps:', JSON.stringify(db.prepare('SELECT wave,name,state,attempts FROM steps').all()));
console.log('events:', JSON.stringify(db.prepare('SELECT sequence,wave,type,substr(body,1,160) body FROM events ORDER BY sequence').all(), null, 1));
db.close();
console.log('files:', JSON.stringify(fs.readdirSync(dir)));
