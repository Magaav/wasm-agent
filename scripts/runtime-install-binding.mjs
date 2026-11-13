import fs from 'node:fs';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
function git(repo,...args){const r=spawnSync('git',args,{cwd:repo,encoding:'utf8',windowsHide:true});if(r.status!==0)throw Error(r.stderr||r.error?.message);return r.stdout.trim();}
// `git worktree list --porcelain` as blocks of lines. `-z` (NUL-separated, safe for any path) needs git
// 2.36+; Ubuntu 22.04 ships 2.34 (mail, 13/11: "error: unknown switch `z'" refused every deploy there).
// Without -z the format is one record per line and a blank line between blocks; a worktree path with a
// newline in it cannot be told apart there, so such a list is refused rather than guessed.
export function worktreeBlocks(repo){
  const z=spawnSync('git',['worktree','list','--porcelain','-z'],{cwd:repo,encoding:'utf8',windowsHide:true});
  if(z.status===0)return z.stdout.split('\0\0').map(block=>block.split('\0').filter(Boolean)).filter(lines=>lines.length);
  if(!/unknown switch|unknown option/.test(z.stderr||''))throw Error(z.stderr||z.error?.message);
  const raw=spawnSync('git',['worktree','list','--porcelain'],{cwd:repo,encoding:'utf8',windowsHide:true});
  if(raw.status!==0)throw Error(raw.stderr||raw.error?.message);
  const blocks=raw.stdout.replace(/\r/g,'').split(/\n\n+/).map(block=>block.split('\n').filter(Boolean)).filter(lines=>lines.length);
  for(const lines of blocks)if(lines.filter(line=>line.startsWith('worktree ')).length!==1)throw Error('git worktree list without -z is ambiguous here (a path with a newline?); no actor tree was moved');
  return blocks;
}
// The main this deploy is on: origin/main, or the remote a checkout names with `git config wa.deployRemote`
// (deploy.sh exports it as WA_DEPLOY_MAIN_REF after its own rules held; 29/10, the sandbox's host bundle).
export function canonicalRuntime(repo,expectedHead='HEAD',mainRef=process.env.WA_DEPLOY_MAIN_REF||'origin/main') {
  if(!/^[A-Za-z0-9._-]+\/main$/.test(mainRef))throw Error('deploy main ref must be <remote>/main');
  const head=git(repo,'rev-parse',expectedHead),main=git(repo,'rev-parse',mainRef);
  if(head!==main)throw Error(`deploy source must be the exact fetched ${mainRef} before canonical runtime binding`);
  const candidates=worktreeBlocks(repo).filter(lines=>lines.includes('branch refs/heads/main'))
    .map(lines=>lines.find(line=>line.startsWith('worktree '))?.slice(9));
  if(candidates.length!==1||!candidates[0])throw Error('exactly one canonical main checkout is required; no actor tree was moved');
  const root=fs.realpathSync(candidates[0]);
  if(git(root,'rev-parse','HEAD')!==main||git(root,'status','--porcelain'))throw Error(`canonical main checkout must be clean and equal to fetched ${mainRef}`);
  return path.resolve(root);
}
if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url)) {
  try{console.log(canonicalRuntime(path.resolve(process.argv[2]||'.')));}catch(error){console.error(error.message);process.exitCode=2;}
}
