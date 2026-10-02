// Logical dump of the whole wave store: every column of every row, plus the schema.
import {DatabaseSync} from 'node:sqlite';
import fs from 'node:fs';

const dir = process.argv[2];
const out = process.argv[3];
const db = new DatabaseSync(dir + '/waves.sqlite', {readOnly: true});
const schema = db.prepare("SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY type,name").all();
const tables = db.prepare("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name").all().map(r => r.name);
const data = {};
for (const t of tables) data[t] = db.prepare(`SELECT * FROM ${t}`).all();
db.close();
const payload = {schema, data};
fs.writeFileSync(out, JSON.stringify(payload, null, 1) + '\n');
const counts = Object.fromEntries(Object.entries(data).map(([k, v]) => [k, v.length]));
const cols = {};
for (const r of schema) if (r.name === 'waves') cols.schema = r.sql;
console.log(JSON.stringify({out, counts, tables, index_sql: schema.filter(r => r.type === 'index').map(r => `${r.name}: ${r.sql}`)}, null, 1));
