// Exact reviewed source bytes; no environment path override.
import fs from 'node:fs';import path from 'node:path';import os from 'node:os';import {spawnSync} from 'node:child_process';import {digest} from './wave-recovery.mjs';
export function verifyRecoverySource(repo,d){
 const fail=s=>{throw Error('recovery_source_'+s);};
 const bytes=(...a)=>{const r=spawnSync('git',['-C',repo,...a],{windowsHide:true,maxBuffer:64*1024*1024});if(r.status!==0)fail('git_unavailable');return r.stdout;};
 const text=(...a)=>bytes(...a).toString().trim();
 if(![d.tip,d.tree,d.review_commit].every(x=>/^[a-f0-9]{40}$/.test(x||''))||d.kind!=='wave-reviewed-source'||text('rev-parse',`${d.tip}^{tree}`)!==d.tree)fail('identity');
 const review=JSON.parse(bytes('show',`${d.review_commit}:${d.review_path}`));
 const last=text('show','-s','--format=%B',d.review_commit).split(/\r?\n/).pop(),sessions=[...last.matchAll(/(?:^|\s)session=([^\s]+)/g)];
 if(review.kind!=='wave-source-review'||review.tip!==d.tip||review.tree!==d.tree||review.verdict!=='passed'||review.reviewer===review.producer||!last.startsWith('Agent:')||sessions.length!==1||sessions[0][1]!==review.reviewer)fail('review');
 // Pin every tracked JavaScript module in scripts, not an arbitrary claimed subset.
 const closure=d.schema===2?text('ls-tree','-r','--name-only',d.tip).split('\n').filter(Boolean).sort():text('ls-tree','-r','--name-only',d.tip,'scripts').split('\n').filter(x=>/\.(mjs|cjs)$/.test(x)).sort();
 if(!Array.isArray(d.files)||JSON.stringify(d.files.map(x=>x.path).sort())!==JSON.stringify(closure)||JSON.stringify(review.files)!==JSON.stringify(d.files))fail('closure');
 const root=fs.realpathSync(d.root),common=fs.realpathSync(text('rev-parse','--path-format=absolute','--git-common-dir'));
 const r=spawnSync('git',['-C',root,'rev-parse','--path-format=absolute','--git-common-dir'],{encoding:'utf8'});
 if(r.status!==0||fs.realpathSync(r.stdout.trim())!==common)fail('foreign_root');
 let archived=null;
 if(d.schema===2){
  const result=spawnSync('git',['-C',repo,'cat-file','--batch'],{input:d.files.map(f=>`${d.tip}:${f.path}\n`).join(''),windowsHide:true,maxBuffer:128*1024*1024});
  if(result.status!==0)fail('closure_objects');archived=new Map();let offset=0;
  for(const f of d.files){const end=result.stdout.indexOf(10,offset),header=result.stdout.subarray(offset,end).toString(),match=/^[a-f0-9]{40} blob (\d+)$/.exec(header);if(!match)fail('closure_blob');const size=Number(match[1]);archived.set(f.path,result.stdout.subarray(end+1,end+1+size));offset=end+size+2;}
 }
 for(const f of d.files){if(!(d.schema===2?/^[a-zA-Z0-9._/-]+$/.test(f.path):/^scripts\/[a-zA-Z0-9._/-]+\.(mjs|cjs)$/.test(f.path))||f.path.split('/').includes('..'))fail('path');if(digest(fs.readFileSync(path.join(root,f.path)))!==f.sha256||digest(archived?archived.get(f.path):bytes('show',`${d.tip}:${f.path}`))!==f.sha256)fail('bytes');}
 if(d.schema===2){
  const anchor=commit=>{const last=text('show','-s','--format=%B',commit).split(/\r?\n/).pop(),m=[...last.matchAll(/(?:^|\s)session=([^\s]+)/g)];if(!last.startsWith('Agent:')||m.length!==1)fail('producer_anchor');return m[0][1];};
  if(review.schema!==2||anchor(d.tip)!==review.producer||JSON.stringify(review.runtime)!==JSON.stringify(d.runtime)||review.authority!==d.authority)fail('runtime_review');
  for(const name of ['native','node','git']){const tool=d.runtime?.[name];if(!tool?.path||digest(fs.readFileSync(tool.path))!==tool.sha256)fail('runtime_binary');}
  if(process.platform==='win32'&&(!d.runtime.observer?.path||digest(fs.readFileSync(d.runtime.observer.path))!==d.runtime.observer.sha256))fail('observer_binary');
  if(fs.realpathSync(process.execPath)!==fs.realpathSync(d.runtime.node.path))fail('node_runner');
  if(d.runtime.driver!=='scripts/wave-recovery-driver.lua'||d.runtime.consumer!=='scripts/wave-recovery-bootstrap.mjs'||JSON.stringify(d.runtime.effects)!==JSON.stringify(['canonical-local-main-cas']))fail('runtime_contract');
  const buildRef=d.runtime.native,build=JSON.parse(bytes('show',`${buildRef.build_commit}:${buildRef.build_path}`));
  const commands=['cargo build --offline --manifest-path rust/Cargo.toml -p wa-host','cargo build --release --offline --manifest-path rust/Cargo.toml'];
  if(build.kind!=='wave-native-build'||build.source_tip!==d.tip||build.source_tree!==d.tree||build.binary_sha256!==buildRef.sha256||build.exit!==0||!commands.includes(build.command)||digest(fs.readFileSync(build.log.path))!==build.log.sha256)fail('native_build');
  const nativeInputs=d.files.filter(f=>f.path.startsWith('rust/')||f.path.startsWith('lua/'));
  if(JSON.stringify(build.native_inputs)!==JSON.stringify(nativeInputs))fail('native_input_closure');
  if(d.authority==='private-fixture'){
   const temp=fs.realpathSync(os.tmpdir());
   if(![repo,root,buildRef.path,build.log.path].every(p=>fs.realpathSync(p).startsWith(temp+path.sep)))fail('private_fixture_root');
  }else if(d.authority!=='operator-local')fail('authority_kind');
 }
 return {verified:true,schema:d.schema||1,authority:d.authority||'legacy-read-only',root,tip:d.tip,tree:d.tree,files:d.files,runtime:d.runtime||null,review_commit:d.review_commit,review_path:d.review_path};
}
