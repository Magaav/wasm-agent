const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const repo=path.resolve(__dirname,'..');
const snapshot=JSON.parse(fs.readFileSync(path.join(repo,'docs/harness-report-snapshot.json'),'utf8'));
const bytes=fs.readFileSync(path.join(repo,snapshot.path));
assert.equal(require('node:crypto').createHash('sha256').update(bytes).digest('hex'),snapshot.sha256,'report snapshot integrity mismatch');
const index=JSON.parse(bytes);
const entries=new Map();for(const g of index.groups)for(const [id,statement] of Object.entries(g.entries)){assert(!entries.has(id),`duplicate ${id}`);assert(g.session&&g.date&&statement,`missing report evidence ${id}`);entries.set(id,{...g,statement});}
const register=fs.readFileSync(path.join(repo,'docs/HARNESS-FEEDBACK.md'),'utf8');
const covered=new Set();for(const line of register.split('\n').filter(l=>l.startsWith('|'))){const evidence=line.split('|')[2]||'';if(!evidence.includes('E'))continue;for(const n of evidence.matchAll(/\d+/g)){const id='E'+n[0];assert(entries.has(id),`missing portable excerpt ${id}`);covered.add(id);}}
for(const id of Object.keys(index.excluded)){assert(entries.has(id),`missing excluded report ${id}`);assert(register.includes(id),`exclusion undocumented ${id}`);covered.add(id);}
assert.equal(entries.size,119,'report inventory count, not defect count');for(const id of entries.keys())assert(covered.has(id),`unmatched report ${id}`);
// Execution/count behavior is tested by test-long-command-contract.cjs, not source spelling.
console.log('portable harness feedback ok (119 report identifiers; 3 intentional exclusions)');
