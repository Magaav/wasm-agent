// Explicit current operator acceptance of external author trees. Never writes
// native session bindings or pretends these are runtime-managed workspaces.
import fs from 'node:fs';import {spawnSync} from 'node:child_process';import {digest} from './wave-recovery.mjs';
const fail=s=>{throw Error('recovery_external_custody_'+s);};
function git(repo,...args){const r=spawnSync('git',['-C',repo,...args],{encoding:'utf8',windowsHide:true});if(r.status!==0)fail('git_unavailable');return r.stdout.trim();}
function anchor(repo,tip){const last=git(repo,'show','-s','--format=%B',tip).split(/\r?\n/).pop(),m=[...last.matchAll(/(?:^|\s)session=([^\s]+)/g)];if(!last.startsWith('Agent:')||m.length!==1)fail('provenance');return m[0][1];}
export function externalCustody(repo,spec,entry){
 if(spec?.kind!=='current-operator-external-custody'||!Array.isArray(spec.evidence)||!spec.evidence.length)fail('descriptor_required');
 for(const artifact of spec.evidence)if(!artifact.path||!/^[a-f0-9]{64}$/.test(artifact.sha256)||digest(fs.readFileSync(artifact.path))!==artifact.sha256)fail('evidence_moved');
 const common=fs.realpathSync(git(repo,'rev-parse','--path-format=absolute','--git-common-dir'));
 const listed=git(repo,'worktree','list','--porcelain').split('\n').filter(x=>x.startsWith('worktree ')).map(x=>fs.realpathSync(x.slice(9)));
 const inspect=(row,session,tip,branch)=>{
  if(row?.session!==session||row.tip!==tip||row.branch!==branch||!/^change\/[a-zA-Z0-9._/-]+$/.test(branch)||branch.includes('..'))fail('identity');
  const tree=fs.realpathSync(row.worktree);
  if(!listed.includes(tree)||fs.realpathSync(git(tree,'rev-parse','--path-format=absolute','--git-common-dir'))!==common)fail('foreign_tree');
  if(git(tree,'symbolic-ref','--short','HEAD')!==branch||git(tree,'rev-parse','HEAD')!==tip||git(tree,'status','--porcelain'))fail('tree_moved_or_dirty');
  if(anchor(repo,tip)!==session||git(tree,'rev-parse','HEAD^{tree}')!==row.tree)fail('source_or_actor');
  return {kind:'external-author-tree',source:{kind:'current-operator-external-custody'},published:false,session,branch,worktree:tree,tip,tree:row.tree};
 };
 return {producer:inspect(spec.producer,entry.producer,entry.tip,entry.branch),reviewer:inspect(spec.reviewer,entry.reviewer,entry.review_commit,spec.reviewer?.branch),
  note:'Current operator-reviewed external custody; no native memory/session allocation or process drain is asserted'};
}
