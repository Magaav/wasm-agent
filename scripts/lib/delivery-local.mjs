// Local evidence never claims publication. Runtime root is WASM_AGENT_HOME/.wasm-agent.
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import {DatabaseSync} from 'node:sqlite';
import {spawnSync} from 'node:child_process';
const git=(repo,...args)=>{const r=spawnSync('git',args,{cwd:repo,encoding:'utf8',windowsHide:true});if(r.status!==0)throw Error(r.stderr.trim());return r.stdout.trim();};
const real=p=>fs.realpathSync(p);
const common=repo=>real(git(repo,'rev-parse','--path-format=absolute','--git-common-dir'));
export function mainOnly(repo) {
  let text;try{text=git(repo,'show','origin/main:lane-policy.json');}catch{return false;}
  if(JSON.parse(text).remote?.main_only!==true)return false;
  const file=path.join(git(repo,'rev-parse','--show-toplevel'),'lane-policy.json');
  if(!fs.existsSync(file)||fs.readFileSync(file,'utf8')!==text+'\n' && fs.readFileSync(file,'utf8').trimEnd()!==text)throw Error('local_policy_differs_from_accepted_main');
  return true;
}
export function bindingSource(sessionDb) {
  const root=path.resolve(process.env.WASM_AGENT_HOME || process.env.USERPROFILE || process.env.HOME,'.wasm-agent');
  if(sessionDb) {
    // Explicit rehearsal only: scratch DB and repository must both be under OS temp.
    const file=real(sessionDb),temp=real(os.tmpdir());
    if(!file.startsWith(temp+path.sep))throw Error('private_session_db_required');
    return {kind:'private-fixture',published:false,file};
  }
  return {kind:'runtime',root,file:path.join(root,'memory.db')};
}
export function managedLocal(repo, session, tip, sessionDb, branch=null) {
  if(!/^[0-9a-f]{40}$/.test(tip))throw Error('local_full_tip_required');
  const source=bindingSource(sessionDb),db=new DatabaseSync(source.file,{readOnly:true});let row;
  try{row=db.prepare('SELECT id,worktree,workspace_required,workspace_state,workspace_branch FROM sessions WHERE id=?').get(session);}finally{db.close();}
  const expected=`change/wa-session-${session.replace(/[^A-Za-z0-9_-]/g,'')}`;
  if(branch && branch!==expected)throw Error('local_owner_mismatch');
  if(!row || row.workspace_required!==1 || row.workspace_state!=='allocated' || row.workspace_branch!==expected)throw Error('local_workspace_binding_mismatch');
  const tree=real(row.worktree);
  if(source.kind==='private-fixture' && (!real(repo).startsWith(real(os.tmpdir())+path.sep)||!tree.startsWith(real(os.tmpdir())+path.sep)))throw Error('private_repository_required');
  if(common(tree)!==common(repo))throw Error('local_repository_mismatch');
  if(git(tree,'symbolic-ref','--short','HEAD')!==expected || git(tree,'rev-parse',`refs/heads/${expected}`)!==tip)throw Error('local_tip_moved');
  const body=git(tree,'show','-s','--format=%B',tip).trimEnd().split(/\r?\n/).pop();
  const sessions=[...body.matchAll(/(?:^|[ \t])session=([^ \t\r\n]+)/g)];
  if(!body.startsWith('Agent: ') || sessions.length!==1 || sessions[0][1]!==session)throw Error('local_provenance_mismatch');
  return {kind:'managed_local',published:false,source,branch:expected,session,worktree:tree,git_common_dir:common(tree),tip,tree:git(tree,'rev-parse',`${tip}^{tree}`)};
}
export function localProducer(repo, branch, producer, tip, sessionDb) {
  if(!mainOnly(repo))throw Error('local_policy_required');
  const evidence=managedLocal(repo,producer,tip,sessionDb,branch);
  if(real(repo)!==evidence.worktree)throw Error('local_workspace_binding_mismatch');
  return evidence;
}
