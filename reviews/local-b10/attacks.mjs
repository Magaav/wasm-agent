// Independent private-fixture extension; original source remains untouched.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {pathToFileURL} from 'node:url';
const original=fs.readFileSync('scripts/test-delivery-local.mjs','utf8');
let source=original.replace("from './delivery-admission.mjs'",`from '${pathToFileURL(path.resolve('scripts/delivery-admission.mjs'))}'`).replace("from './producer-admission.mjs'",`from '${pathToFileURL(path.resolve('scripts/producer-admission.mjs'))}'`).replace("import('./lib/delivery-store.mjs')",`import('${pathToFileURL(path.resolve('scripts/lib/delivery-store.mjs'))}')`);
const marker=" git(reviewer,'commit','--allow-empty','-qm','wrong provenance";
const at=source.indexOf(marker);if(at<0)throw Error('fixture marker missing');
source=source.slice(0,at)+`
 const cli=(label,expected)=>{
   const r=spawnSync(process.execPath,[path.resolve('scripts/delivery-admission.mjs'),'check',record.delivery,'--repo',repo,'--store',store,'--session-db',dbFile],{encoding:'utf8'});
   assert.equal(r.status,expected,r.stdout+r.stderr);
   const result=r.stdout.trim()?JSON.parse(r.stdout):null;
   console.log(JSON.stringify({label,exit:r.status,condition:result?.condition,authority:result?.authority,stderr:r.stderr.trim()}));
 };
 cli('matched actual CLI private authority',0);
 const binding=new DatabaseSync(dbFile);
 binding.prepare('UPDATE sessions SET workspace_state=? WHERE id=?').run('released','reviewer');
 cli('revoked reviewer refuses',2);
 binding.prepare('UPDATE sessions SET workspace_state=? WHERE id=?').run('allocated','reviewer');binding.close();
 record.review.tip=anchor;writeRecord(store,record);cli('same tree different review tip refuses',2);
 record.review.tip=tip;writeRecord(store,record);
 fs.writeFileSync(path.join(repo,'lane-policy.json'),JSON.stringify({remote:{main_only:false}}));
 cli('dirty caller policy override refuses',4);
 fs.writeFileSync(path.join(repo,'lane-policy.json'),JSON.stringify({remote:{main_only:true}}));
 cli('restored accepted policy admits',0);
`+source.slice(at);
const temp=path.join(fs.mkdtempSync(path.join(os.tmpdir(),'wa-review-driver-')),'driver.mjs');
try{fs.writeFileSync(temp,source);await import(pathToFileURL(temp));}finally{fs.rmSync(path.dirname(temp),{recursive:true,force:true});}
