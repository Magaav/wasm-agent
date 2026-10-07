#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {discoverFiles} from './discover-files.mjs';

const scratch=process.argv[2];
if (!scratch || !path.isAbsolute(scratch)) throw Error('pass an absolute writable evidence scratch directory');
const fixture=fs.mkdtempSync(path.join(scratch,'discovery-fixture-'));
let checks=0;
const check=(fn)=>{fn();checks++;};
try {
  for (const dir of ['src','docs','ignored']) fs.mkdirSync(path.join(fixture,dir));
  for (const file of ['src/executor.ts','src/server.ts','src/space ü.ts','docs/security.md','ignored/secret.txt'])
    fs.writeFileSync(path.join(fixture,file),'fixture\n');
  fs.writeFileSync(path.join(fixture,'.ignore'),'ignored/\n');
  const all=discoverFiles({root:fixture,scopes:['src','docs']});
  check(()=>assert.deepEqual(all.paths,['docs/security.md','src/executor.ts','src/server.ts','src/space ü.ts']));
  check(()=>assert(all.complete && all.next_offset===null && all.returned===4));
  const narrowed=discoverFiles({root:fixture,scopes:['src'],match:'executor|server'});
  check(()=>assert.deepEqual(narrowed.paths,['src/executor.ts','src/server.ts']));
  check(()=>assert.equal(narrowed.scanned,3));
  check(()=>assert.equal(discoverFiles({root:fixture,scopes:['src'],match:'no-match'}).matched,0));
  check(()=>assert.deepEqual(discoverFiles({root:fixture,scopes:['src','src']}).paths,all.paths.filter(p=>p.startsWith('src/'))));
  check(()=>assert(!discoverFiles({root:fixture,scopes:['.']}).paths.some(p=>p.startsWith('ignored/'))));
  check(()=>assert.throws(()=>discoverFiles({root:fixture,scopes:[]} ),/explicit relative scopes/));
  check(()=>assert.throws(()=>discoverFiles({root:fixture,scopes:['../']} ),/escapes root/));
  check(()=>assert.throws(()=>discoverFiles({root:fixture,scopes:[fixture]} ),/relative to root/));
  check(()=>assert.throws(()=>discoverFiles({root:fixture,scopes:['missing']} ),/ENOENT/));
  check(()=>assert.throws(()=>discoverFiles({root:fixture,scopes:['src'],match:'['} )));
  check(()=>assert.throws(()=>discoverFiles({root:fixture,scopes:['src'],offset:1} ),/requires snapshot/));
  check(()=>assert.throws(()=>discoverFiles({root:fixture,scopes:['src'],maxBytes:511} ),/max-bytes/));
  fs.mkdirSync(path.join(fixture,'many'));
  for(let i=0;i<450;i++) fs.writeFileSync(path.join(fixture,'many',String(i).padStart(4,'0')+'-repeated-long-filename.ts'),'fixture');
  let page=discoverFiles({root:fixture,scopes:['many'],maxBytes:2048});
  check(()=>assert(!page.complete && page.omitted_after>0 && page.returned>0));
  const collected=[...page.paths];let pages=1;
  while (!page.complete) {
    check(()=>assert(Buffer.byteLength(JSON.stringify(page)+'\n')<=2048));
    page=discoverFiles({root:fixture,scopes:['many'],maxBytes:2048,offset:page.next_offset,snapshot:page.snapshot});
    collected.push(...page.paths);pages++;
  }
  check(()=>assert.equal(collected.length,450));
  check(()=>assert.equal(new Set(collected).size,450));
  check(()=>assert(collected.every(p=>!path.isAbsolute(p)&&p.startsWith('many/'))));
  fs.writeFileSync(path.join(fixture,'many','new.ts'),'new');
  check(()=>assert.throws(()=>discoverFiles({root:fixture,scopes:['many'],offset:1,snapshot:page.snapshot}),/inventory changed/));
  check(()=>assert.throws(()=>discoverFiles({root:fixture,scopes:['src'],match:'executor|server',offset:99,snapshot:narrowed.snapshot}),/exceeds matched inventory/));
  check(()=>assert(Buffer.byteLength(JSON.stringify(page)+'\n')<=2048));
  const cli=fileURLToPath(new URL('./discover-files.mjs',import.meta.url));
  const run=spawnSync(process.execPath,[cli,'--root',fixture,'--scope','src','--match','executor|server'],{encoding:'utf8',windowsHide:true});
  check(()=>assert.equal(run.status,0,run.stderr));
  check(()=>assert.deepEqual(JSON.parse(run.stdout).paths,narrowed.paths));
  const bad=spawnSync(process.execPath,[cli,'--root',fixture,'--scope','src','--unknown','yes'],{encoding:'utf8',windowsHide:true});
  check(()=>assert.equal(bad.status,1));
  check(()=>assert.equal(JSON.parse(bad.stdout).ok,false));
  console.log(JSON.stringify({ok:true,checks,skipped:0,pagination_pages:pages,scope:'relative scoped discovery, exact page continuation and visible refusals',full_release_gate:false}));
} finally {fs.rmSync(fixture,{recursive:true,force:true});}
