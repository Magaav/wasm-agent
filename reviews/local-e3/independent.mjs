import fs from 'node:fs';import path from 'node:path';import {spawnSync} from 'node:child_process';import {pathToFileURL} from 'node:url';
const repo=fs.readFileSync('reviews/local-e3/source-path.txt','utf8');
let code=fs.readFileSync(path.join(repo,'scripts/test-delivery-subsystem-consumer.mjs'),'utf8');
const needle=' // Mutate real log artifacts';if(!code.includes(needle))throw Error('marker missing');
code=code.replace(needle,`
 for(const review of [null,{...record.review,reviewer:owner},{...record.review,verdict:'refused'},{...record.review,tip:receipt.base},{...record.review,commit:anchor.slice(0,8)}])assert.equal(check({...record,review}).decision,'refused');
 const bdb=new DatabaseSync(dbFile);bdb.prepare('UPDATE sessions SET workspace_state=? WHERE id=?').run('released','reviewer');assert.equal(check(record).decision,'refused');bdb.prepare('UPDATE sessions SET workspace_state=? WHERE id=?').run('allocated','reviewer');bdb.close();
 const policy=path.join(repo,'lane-policy.json'),savedPolicy=fs.readFileSync(policy);fs.writeFileSync(policy,JSON.stringify({remote:{main_only:false}}));assert.throws(()=>check(record),/local_policy_differs/);fs.writeFileSync(policy,savedPolicy);
 for(const patch of [{results:receipt.results.map((r,i)=>i?r:{...r,exit:1})},{results:receipt.results.map((r,i)=>i?r:{...r,log_sha256:'0'.repeat(64)})}])assert.equal(check({...record,producer_checks:{...receipt,...patch}}).decision,'refused');
 console.log('independent missing/self/refused/exact40/revoked/policy/nonzero/loghash controls pass');
`+needle);
// Private instrumented copy imports exact immutable modules, never alters candidate bytes.
for(const name of ['delivery-admission.mjs','producer-admission.mjs','lib/delivery-producer-proof.mjs','lib/delivery-store.mjs'])code=code.replace(`from './${name}'`,`from '${pathToFileURL(path.join(repo,'scripts',name)).href}'`);
const driver=path.join(path.dirname(repo),'independent-consumer.mjs');fs.writeFileSync(driver,code);
const r=spawnSync(process.execPath,[driver],{cwd:repo,encoding:'utf8',timeout:240000,maxBuffer:32*1024*1024});console.log(JSON.stringify({cwd:repo,driver,status:r.status,error:r.error?.message}));process.stdout.write(r.stdout||'');process.stderr.write(r.stderr||'');process.exitCode=r.status===0?0:1;
