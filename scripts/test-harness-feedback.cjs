const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const repo=path.resolve(__dirname,'..');
const index=JSON.parse(fs.readFileSync(path.join(repo,'docs/harness-report-index.json'),'utf8'));
const entries=new Map();for(const g of index.groups)for(const [id,statement] of Object.entries(g.entries)){assert(!entries.has(id),`duplicate ${id}`);assert(g.session&&g.date&&statement,`missing report evidence ${id}`);entries.set(id,{...g,statement});}
const register=fs.readFileSync(path.join(repo,'docs/HARNESS-FEEDBACK.md'),'utf8');
const covered=new Set();for(const line of register.split('\n').filter(l=>l.startsWith('|'))){const evidence=line.split('|')[2]||'';if(!evidence.includes('E'))continue;for(const n of evidence.matchAll(/\d+/g)){const id='E'+n[0];assert(entries.has(id),`missing portable excerpt ${id}`);covered.add(id);}}
for(const id of Object.keys(index.excluded)){assert(entries.has(id),`missing excluded report ${id}`);assert(register.includes(id),`exclusion undocumented ${id}`);covered.add(id);}
assert.equal(entries.size,119,'report inventory count, not defect count');for(const id of entries.keys())assert(covered.has(id),`unmatched report ${id}`);
// Normal gate must execute, not merely contain, the long-command fixture and floor.
const runner=fs.readFileSync(path.join(repo,'scripts/test-session-workspaces.cjs'),'utf8');
assert(runner.includes("const longCommand=run('test-bash-long-command.lua')"),'missing normal-reachable invocation');
assert(runner.includes('check(longCount>=10,'),'missing count floor');
console.log('portable harness feedback ok (119 report identifiers; 3 intentional exclusions)');
