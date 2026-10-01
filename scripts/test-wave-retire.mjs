// Real Git deletion/CAS in disposable repos; owner/registry observations are
// stand-ins. No live branch, worktree, Orca card or diagnostic is changed.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {guard,retire} from './wave-retire.mjs';
const root=fs.mkdtempSync(path.join(os.tmpdir(),'wa-retire-test-'));let checks=0,passed=false;
function git(repo,args,input) { const r=spawnSync('git',['-C',repo,...args],{input,encoding:'utf8',windowsHide:true});assert.equal(r.status,0,r.stderr);return r.stdout.trim(); }
const q=x=>`'${x.replaceAll("'","'\\''")}'`;
function fixture(name) {
  const dir=path.join(root,name),repo=path.join(dir,'main'),remote=path.join(dir,'remote.git'),state=path.join(dir,'state');fs.mkdirSync(repo,{recursive:true});
  git(repo,['init','-b','main']);git(repo,['config','user.name','fixture']);git(repo,['config','user.email','fixture@invalid']);
  fs.writeFileSync(path.join(repo,'seed'),'seed');git(repo,['add','seed']);git(repo,['commit','-m','seed']);git(dir,['init','--bare',remote]);
  git(repo,['remote','add','origin',remote]);git(repo,['push','-u','origin','main']);git(repo,['branch','feature']);git(repo,['push','origin','feature']);
  const driver=path.join(dir,'proof.cjs');fs.writeFileSync(driver,`console.log(JSON.stringify({ok:true,complete:true,unresolved:[],settled:process.argv[2]!=='live',owner_id:'fixture',worktree:process.env.WA_WAVE_TARGET,tip:process.env.WA_WAVE_TIP,evidence:'fixture owner settlement',reconciled:true}));`);
  const main=git(repo,['rev-parse','HEAD']);
  const plan={wave_id:name,owner:'external-fixture',repo,main,managed_roots:[dir],worktrees:[],local:[{ref:'refs/heads/feature',tip:main}],remote:[{ref:'refs/heads/feature',tip:main}],dependencies_argv:[process.execPath,driver],owners_argv:[process.execPath,driver]};
  return {dir,repo,remote,state,driver,main,plan};
}
try {
  const good=fixture('good'),marker=path.join(good.dir,'prior-hook-ran');
  fs.writeFileSync(path.join(good.repo,'.git/hooks/pre-push'),`#!/bin/sh\nprintf prior > ${q(marker)}\n`,{mode:0o755});
  assert.equal(retire(good.plan,good.state).ok,true);checks++;
  assert.ok(fs.existsSync(marker),'existing pre-push policy executed');checks++;
  assert.equal(git(good.repo,['ls-remote','--heads','origin']).split('\n').length,1);checks++;
  assert.equal(git(good.repo,['for-each-ref','--format=%(refname)','refs/heads/']),'refs/heads/main');checks++;
  assert.equal(retire(good.plan,good.state).ok,true,'settled journal is idempotent');checks++;
  const changed=fixture('changed');assert.throws(()=>guard(changed.plan,`(delete) ${'0'.repeat(40)} refs/heads/feature ${'f'.repeat(40)}\n`),/remote_tip_moved/);checks++;
  assert.throws(()=>guard(changed.plan,`(delete) ${'0'.repeat(40)} refs/heads/main ${changed.main}\n`),/out_of_plan/);checks++;
  const race=fixture('race'),newTip=git(race.repo,['commit-tree','HEAD^{tree}','-p','HEAD','-m','concurrent remote work']);
  git(race.repo,['push','origin',`${newTip}:refs/wave-fixture/newtip`]); // object exists before the racing remote ref update
  fs.writeFileSync(path.join(race.repo,'.git/hooks/pre-push'),`#!/bin/sh\ngit --git-dir=${q(race.remote)} update-ref refs/heads/feature ${newTip}\n`,{mode:0o755});
  assert.throws(()=>retire(race.plan,race.state),/command_failed/);checks++;
  assert.ok(git(race.repo,['ls-remote','--heads','origin']).includes(newTip),'server old-OID CAS preserves tip moved after advertisement');checks++;
  const localMoved=fixture('local-moved');git(localMoved.repo,['update-ref','refs/heads/feature',git(localMoved.repo,['commit-tree','HEAD^{tree}','-p','HEAD','-m','local valuable work'])]);
  assert.throws(()=>retire(localMoved.plan,localMoved.state),/local_ref_moved/);checks++;
  const parked=fixture('parked'),tree=path.join(parked.dir,'tree');git(parked.repo,['worktree','add',tree,'feature']);
  const treePlan={path:tree,tip:parked.main,branch:'refs/heads/feature',mode:'park',owner_id:'fixture',owner_argv:[process.execPath,parked.driver],safety_argv:[process.execPath,parked.driver],reconcile_argv:[process.execPath,parked.driver],registry_post_argv:[process.execPath,parked.driver]};
  parked.plan.worktrees=[treePlan];fs.writeFileSync(path.join(tree,'preserve'),'dirty valuable evidence');
  assert.throws(()=>retire(parked.plan,parked.state),/worktree_dirty/);checks++;
  assert.equal(fs.readFileSync(path.join(tree,'preserve'),'utf8'),'dirty valuable evidence');checks++;
  fs.unlinkSync(path.join(tree,'preserve'));treePlan.owner_argv=[process.execPath,parked.driver,'live'];
  assert.throws(()=>retire(parked.plan,parked.state),/owner_settlement/);checks++;
  assert.equal(git(tree,['symbolic-ref','HEAD']),'refs/heads/feature','live owner tree remains attached');checks++;
  treePlan.owner_argv=[process.execPath,parked.driver];assert.equal(retire(parked.plan,parked.state).ok,true);checks++;
  assert.equal(git(tree,['rev-parse','HEAD']),parked.main);checks++;
  assert.equal(spawnSync('git',['-C',tree,'symbolic-ref','--quiet','HEAD'],{windowsHide:true}).status,1,'finished terminal tree is detached, not on main');checks++;
  const refused=fixture('refused');fs.writeFileSync(path.join(refused.repo,'.git/hooks/pre-push'),'#!/bin/sh\nexit 23\n',{mode:0o755});
  assert.throws(()=>retire(refused.plan,refused.state),/command_failed/);checks++;
  assert.ok(git(refused.repo,['ls-remote','--heads','origin']).includes('refs/heads/feature'));checks++;
  assert.throws(()=>retire(refused.plan,refused.state),/effect_unknown/);checks++;
  passed=true;console.log(`wave retirement ok (${checks} checks; non-force advertisement and server CAS, preserved owners/work, private Git only)`);
}finally{if(passed)fs.rmSync(root,{recursive:true});else console.error(`retirement fixtures retained: ${root}`);}
