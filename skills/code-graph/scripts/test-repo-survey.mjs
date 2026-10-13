#!/usr/bin/env node
// Private offline fixtures, no repository downloads or startup of third-party code.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {surveyView} from './repo-survey.mjs';

const scratch=process.argv[2];if(!scratch||!path.isAbsolute(scratch))throw Error('pass absolute writable evidence scratch');
const fixture=fs.mkdtempSync(path.join(scratch,'repo-view-')),cache=path.join(fixture,'cache ü with spaces');fs.mkdirSync(cache);
let checks=0,skipped=0;const check=fn=>{fn();checks++;};
const hash=bytes=>crypto.createHash('sha256').update(bytes).digest('hex');
const manifest={at:'2026-10-13T00:00:00Z',results:[]};
function add(repo,index){
 const dir=path.join(cache,repo.replace('/','--'));fs.mkdirSync(dir);
 const commit=crypto.createHash('sha1').update(repo).digest('hex'),readme='# '+repo+'\n'+('Full Unicode 🧭 source with final rules.\n'.repeat(1000));
 for(const [file,value]of Object.entries({'metadata.json':{html_url:'https://github.com/'+repo,language:'TypeScript',license:{spdx_id:'MIT'},archived:false},'commit.json':{sha:commit,commit:{committer:{date:'2026-10-12T00:00:00Z'}}},'tree.json':{truncated:index===5,tree:Array.from({length:500},(_,n)=>({path:'src/file-'+n+'.ts',type:'blob'}))}}))fs.writeFileSync(path.join(dir,file),JSON.stringify(value));
 fs.writeFileSync(path.join(dir,'README.md'),readme);
 manifest.results.push({repo,ok:true,commit,readme_bytes:Buffer.byteLength(readme),candidate_files:Array.from({length:500},(_,n)=>'src/'+n+'.ts'),excerpts:[{text:readme}]});
}
try{
 for(let n=0;n<6;n++)add('owner/repository-'+n,n);fs.writeFileSync(path.join(cache,'receipt.json'),JSON.stringify(manifest));
 const original=new Map();for(const file of ['receipt.json',...manifest.results.flatMap(r=>['metadata.json','commit.json','tree.json','README.md'].map(p=>r.repo.replace('/','--')+'/'+p))])original.set(file,hash(fs.readFileSync(path.join(cache,file))));
 const oldBytes=Buffer.byteLength(JSON.stringify({out:cache,results:manifest.results})+'\n');
 check(()=>assert(oldBytes>51200,'old survey dump must causally exceed the tool budget'));
 const full=surveyView({cache});
 check(()=>assert(full.complete&&full.total===6&&full.returned===6&&full.next_offset===null));
 check(()=>assert(Buffer.byteLength(JSON.stringify(full)+'\n')<=8192));
 check(()=>assert.deepEqual(full.results.map(r=>[r.repo,r.commit]),manifest.results.map(r=>[r.repo,r.commit])));
 check(()=>assert(full.results.every(r=>r.readme&&r.license==='MIT'&&r.commit_at==='2026-10-12T00:00:00Z')));
 check(()=>assert(full.results[5].tree_truncated,'incomplete remote tree stays explicit'));
 check(()=>assert(!JSON.stringify(full).includes('Full Unicode')&&full.omitted_fields.includes('readme_excerpts')));
 check(()=>assert([...original].every(([p,h])=>hash(fs.readFileSync(path.join(cache,p)))===h),'projection must never write or lose cached source'));
 let page=surveyView({cache,maxBytes:2048}),pages=1,rows=[...page.results];
 check(()=>assert(!page.complete&&page.returned>0&&page.omitted_after>0));
 while(!page.complete){check(()=>assert(Buffer.byteLength(JSON.stringify(page)+'\n')<=2048));page=surveyView({cache,maxBytes:2048,offset:page.next_offset,snapshot:page.snapshot});rows.push(...page.results);pages++;}
 check(()=>assert.deepEqual(rows.map(r=>r.repo),manifest.results.map(r=>r.repo)));
 check(()=>assert.equal(new Set(rows.map(r=>r.repo)).size,6));
 check(()=>assert.throws(()=>surveyView({cache,offset:1}),/requires snapshot/));
 check(()=>assert.throws(()=>surveyView({cache,maxBytes:2047}),/max-bytes/));
 check(()=>assert.throws(()=>surveyView({cache,maxBytes:51201}),/max-bytes/));
 check(()=>assert.throws(()=>surveyView({cache,offset:-1}),/offset/));
 check(()=>assert.throws(()=>surveyView({cache,snapshot:'not-a-hash'}),/snapshot/));
 check(()=>assert.throws(()=>surveyView({cache,offset:7,snapshot:full.snapshot}),/exceeds survey/));
 check(()=>assert.throws(()=>surveyView({cache:'relative'}),/absolute/));
 const readmeFile=path.join(cache,'owner--repository-0','README.md'),before=fs.readFileSync(readmeFile);
 fs.writeFileSync(readmeFile,Buffer.from(before.toString().replace('owner','ownez')));
 check(()=>assert.throws(()=>surveyView({cache,offset:1,snapshot:full.snapshot}),/snapshot changed/));fs.writeFileSync(readmeFile,before);
 const readFile=fs.readFileSync;let mutated=false;
 const mutateRead=(filename,...args)=>{const bytes=readFile.call(fs,filename,...args);if(!mutated&&path.resolve(String(filename))===path.resolve(readmeFile)){mutated=true;fs.writeFileSync(readmeFile,Buffer.from(before.toString().replace('owner','ownez')));}return bytes;};
 fs.readFileSync=mutateRead;
 try{check(()=>assert.throws(()=>surveyView({cache}),/changed during capture/));}finally{fs.readFileSync=readFile;fs.writeFileSync(readmeFile,before);}
 manifest.results.push({...manifest.results[0]});fs.writeFileSync(path.join(cache,'receipt.json'),JSON.stringify(manifest));
 check(()=>assert.throws(()=>surveyView({cache}),/duplicate/));manifest.results.pop();
 manifest.results.push({repo:'../escape',ok:true});fs.writeFileSync(path.join(cache,'receipt.json'),JSON.stringify(manifest));
 check(()=>assert.throws(()=>surveyView({cache}),/invalid/));manifest.results.pop();
 manifest.results.push({repo:'a--b/c',ok:false,error:'fixture'},{repo:'a/b--c',ok:false,error:'fixture'});fs.writeFileSync(path.join(cache,'receipt.json'),JSON.stringify(manifest));
 check(()=>assert.throws(()=>surveyView({cache}),/ambiguous evidence directory/));manifest.results.splice(-2);
 manifest.results.push({repo:'owner/failed',ok:false,error:'Failure 🧭 '.repeat(5000)});fs.writeFileSync(path.join(cache,'receipt.json'),JSON.stringify(manifest));
 const partial=surveyView({cache});
 check(()=>assert(!partial.collection_ok&&partial.failed_total===1&&partial.results.at(-1).ok===false));
 check(()=>assert(partial.results.at(-1).error_truncated&&Buffer.byteLength(partial.results.at(-1).error)<=512));
 check(()=>assert(!partial.results.at(-1).error.includes('\ufffd'),'error prefix remains Unicode-safe'));
 const cli=fileURLToPath(new URL('./repo-survey.mjs',import.meta.url));
 const failed=spawnSync(process.execPath,[cli,'--cache',cache],{encoding:'utf8',windowsHide:true});
 check(()=>assert(failed.status===1&&JSON.parse(failed.stdout).failed_total===1));
 manifest.results.pop();fs.writeFileSync(path.join(cache,'receipt.json'),JSON.stringify(manifest));
 const run=spawnSync(process.execPath,[cli,'--cache',cache],{encoding:'utf8',windowsHide:true});
 check(()=>assert.equal(run.status,0,run.stderr));
 check(()=>assert.deepEqual(JSON.parse(run.stdout).results,full.results));
 const invalid=spawnSync(process.execPath,[cli,'--cache',cache,'--wat','yes'],{encoding:'utf8',windowsHide:true});
 check(()=>assert(invalid.status===1&&JSON.parse(invalid.stdout).ok===false));
 const meta=path.join(cache,'owner--repository-0','metadata.json'),bytes=fs.readFileSync(meta);fs.unlinkSync(meta);
 check(()=>assert.throws(()=>surveyView({cache}),/ENOENT/));fs.writeFileSync(meta,bytes);
 fs.writeFileSync(meta,Buffer.from([0xff]));check(()=>assert.throws(()=>surveyView({cache}),/encoded data|encoding|UTF/i));fs.writeFileSync(meta,bytes);
 fs.truncateSync(meta,32*1024*1024+1);check(()=>assert.throws(()=>surveyView({cache}),/oversized evidence/));fs.writeFileSync(meta,bytes);
 const outside=path.join(fixture,'outside');fs.mkdirSync(outside);fs.copyFileSync(meta,path.join(outside,'metadata.json'));
 const dir=path.join(cache,'owner--repository-0'),backup=dir+'-preserved';fs.renameSync(dir,backup);
 try{fs.symlinkSync(outside,dir,process.platform==='win32'?'junction':'dir');check(()=>assert.throws(()=>surveyView({cache}),/escapes cache/));}
 catch(error){if(['EPERM','EACCES','ENOTSUP'].includes(error.code))skipped++;else throw error;}
 finally{if(fs.existsSync(dir))fs.rmSync(dir,{recursive:true,force:true});fs.renameSync(backup,dir);}
 const empty=path.join(fixture,'empty');fs.mkdirSync(empty);fs.writeFileSync(path.join(empty,'receipt.json'),'{"results":[]}');
 check(()=>assert(surveyView({cache:empty}).complete&&surveyView({cache:empty}).total===0));
 console.log(JSON.stringify({ok:true,checks,skipped,pages,old_dump_bytes:oldBytes,new_view_bytes:Buffer.byteLength(run.stdout),full_release_gate:false}));
}finally{fs.rmSync(fixture,{recursive:true,force:true});}
