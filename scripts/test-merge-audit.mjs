// Real disposable Git repositories: branch names, divergence, dirty worktrees and PR-only heads.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {audit,parseWorktrees} from '../skills/git-orchestrator/scripts/audit.mjs';
const root=fs.mkdtempSync(path.join(os.tmpdir(),'wa-merge-audit-'));
const repo=path.join(root,'repo with spaces'),remote=path.join(root,'origin.git'),lane=path.join(root,'dirty actor');
fs.mkdirSync(repo);fs.mkdirSync(remote);
let checks=0;
function check(value,label){assert.ok(value,label);checks++;}
function gitAt(cwd,...args){const r=spawnSync('git',args,{cwd,encoding:'utf8',windowsHide:true});assert.equal(r.status,0,`${args.join(' ')}: ${r.stderr}`);return r.stdout.trim();}
const git=(...args)=>gitAt(repo,...args);
function commit(name){fs.writeFileSync(path.join(repo,name),name+'\n');git('add',name);git('commit','-m',name);return git('rev-parse','HEAD');}
try {
  gitAt(remote,'init','--bare');git('init','-b','main');git('config','user.name','Merge fixture');git('config','user.email','fixture@example.invalid');
  git('config','core.autocrlf','false');git('config','core.hooksPath',path.join(root,'no-hooks'));
  const base=commit('base.txt');git('remote','add','origin',remote);git('push','-u','origin','main');
  git('switch','-c','astra');const actor=commit('actor.txt');git('push','-u','origin','astra');
  const local=commit('local-only.txt');
  git('switch','-c','remote-input',actor);const divergent=commit('remote-only.txt');git('push','origin','HEAD:refs/heads/astra');
  // This update is deliberately divergent and must not discard either exact tip.
  git('switch','main');git('branch','-D','remote-input');
  git('switch','-c','temporary-pr');const prSha=commit('pr-only.txt');git('push','origin','HEAD:refs/pull/7/head');
  git('switch','main');git('branch','-D','temporary-pr');
  git('worktree','add',lane,'astra');fs.writeFileSync(path.join(lane,'unfinished.txt'),'keep this uncommitted\n');
  const prs=[{number:7,sha:prSha,branch:'feature/from-fork',base:'main',draft:false}];
  const options={listPRs:()=>prs,includePRs:true};
  const first=audit(repo,options);
  check(first.discovery_complete,'all discovery sources succeeded');
  check(!first.integration_complete,'unmerged tips fail completion');
  check(first.candidates.some(c=>c.sha===local&&c.state==='pending'),'non-change local actor is an integration input');
  check(first.candidates.some(c=>c.sha===divergent&&c.state==='pending'),'divergent remote actor is a separate input');
  check(first.candidates.some(c=>c.sha===prSha&&c.sources.some(s=>s.kind==='pr')),'PR-only head fetched and included');
  const internal=audit(repo,{listPRs:()=>prs});
  check(internal.candidates.find(c=>c.sha===prSha).state==='excluded_pr','ordinary merge excludes PRs');
  git('branch','copied-pr',prSha);
  const indirect=audit(repo,{listPRs:()=>prs});
  check(indirect.candidates.find(c=>c.sha===prSha).state==='excluded_pr','copying a PR to a local branch cannot bypass explicit PR scope');
  git('branch','-D','copied-pr');
  check(first.worktrees.some(w=>w.path.replaceAll('\\','/')===lane.replaceAll('\\','/')&&w.sync==='dirty_retained'),'dirty worktree reported separately');
  check(first.candidates.find(c=>c.sha===local).merge==='clean','dirty checkout does not block clean committed-tip integration');
  check(git('rev-parse','HEAD')===base,'audit does not merge or move the caller');
  check(fs.readFileSync(path.join(lane,'unfinished.txt'),'utf8')==='keep this uncommitted\n','audit preserves dirty bytes');
  const parsed=parseWorktrees('worktree C:/a path\0HEAD abc\0branch refs/heads/actor\0\0worktree C:/bench\0HEAD def\0detached\0\0');
  check(parsed[0].worktree==='C:/a path'&&parsed[1].detached===true,'NUL worktree records preserve Windows colons and spaces');
  for(const sha of [local,divergent])git('merge','--no-ff','-m','merge(fixture): preserve exact tip',sha);
  git('push','origin','main');
  check(audit(repo,{listPRs:()=>prs}).integration_complete,'internal integration completes with PR explicitly out of scope');
  check(!audit(repo,options).integration_complete,'merge all remains pending until PR is included');
  git('merge','--no-ff','-m','merge(fixture): reviewed PR',prSha);
  git('push','origin','main');
  const merged=audit(repo,options);
  check(merged.integration_complete,'every committed input is now contained');
  check(merged.worktrees.some(w=>w.sync==='dirty_retained'),'dirty worktree does not relabel completed integration as partial');
  check(gitAt(lane,'rev-parse','HEAD')===local,'worktree remains on original branch and tip');
  check(fs.readFileSync(path.join(lane,'unfinished.txt'),'utf8')==='keep this uncommitted\n','merging committed tips preserves uncommitted work');
  const unavailable=audit(repo,{listPRs:()=>{throw Error('fixture GitHub unavailable');}});
  check(!unavailable.discovery_complete&&!unavailable.integration_complete,'PR discovery failure cannot masquerade as an empty queue');
  const stale=audit(repo,{listPRs:()=>[{...prs[0],sha:actor}]});
  check(!stale.discovery_complete&&stale.errors.some(e=>e.includes('head moved')),'moving PR head requires re-audit');
  const moving=audit(repo,{listPRs:()=>{git('branch','arrived-during-discovery',prSha);return prs;}});
  check(!moving.discovery_complete&&moving.errors.some(e=>e.includes('Branch tips moved')),'branch arrival during an audit invalidates the snapshot');
  git('switch','-c','late-lane');const late=commit('late.txt');git('switch','main');
  const final=audit(repo,options);
  check(!final.integration_complete&&final.candidates.some(c=>c.sha===late&&c.state==='pending'),'fresh audit catches a late non-change local lane');
  console.log(`merge audit ok (${checks} checks, 0 skipped; real Git, fixture PR discovery)`);
} finally {
  // Entire fixture is an explicitly created disposable root; retain it on failure for diagnosis.
  console.log('evidence: '+root);
}
