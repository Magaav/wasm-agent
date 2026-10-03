// Main-only handoff is local evidence, never publication evidence.
import fs from 'node:fs';
import path from 'node:path';
import {DatabaseSync} from 'node:sqlite';
import {spawnSync} from 'node:child_process';
const git=(repo,...args)=>{const r=spawnSync('git',args,{cwd:repo,encoding:'utf8',windowsHide:true});if(r.status!==0)throw Error(r.stderr.trim());return r.stdout.trim();};
const real=p=>fs.realpathSync(p);
export function mainOnly(repo) {
  const file=path.join(git(repo,'rev-parse','--show-toplevel'),'lane-policy.json');
  return fs.existsSync(file) && JSON.parse(fs.readFileSync(file,'utf8')).remote?.main_only===true;
}
export function localProducer(repo, branch, producer, tip, sessionDb) {
  if(!mainOnly(repo))throw Error('local_policy_required');
  if(!/^[0-9a-f]{40}$/.test(tip))throw Error('local_full_tip_required');
  const clean=producer.replace(/[^A-Za-z0-9_-]/g,'');
  if(branch!==`change/wa-session-${clean}`)throw Error('local_owner_mismatch');
  const dbPath=sessionDb || path.join(process.env.WASM_AGENT_HOME || process.env.USERPROFILE || process.env.HOME,'.wasm-agent','memory.db');
  const db=new DatabaseSync(dbPath,{readOnly:true});
  let row;
  try{row=db.prepare('SELECT id,worktree,workspace_required,workspace_state,workspace_branch FROM sessions WHERE id=?').get(producer);}finally{db.close();}
  if(!row || row.workspace_required!==1 || row.workspace_state!=='allocated' || row.workspace_branch!==branch || real(row.worktree)!==real(repo))throw Error('local_workspace_binding_mismatch');
  if(git(repo,'symbolic-ref','--short','HEAD')!==branch || git(repo,'rev-parse',`refs/heads/${branch}`)!==tip)throw Error('local_tip_moved');
  const common=real(git(repo,'rev-parse','--path-format=absolute','--git-common-dir'));
  const body=git(repo,'show','-s','--format=%B',tip).trimEnd().split(/\r?\n/).pop();
  const sessions=[...body.matchAll(/(?:^|[ \t])session=([^ \t\r\n]+)/g)];
  if(!body.startsWith('Agent: ') || sessions.length!==1 || sessions[0][1]!==producer)throw Error('local_provenance_mismatch');
  return {kind:'managed_local',published:false,branch,session:producer,worktree:real(repo),git_common_dir:common,tip,tree:git(repo,'rev-parse',`${tip}^{tree}`)};
}
