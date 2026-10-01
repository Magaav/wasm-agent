import fs from 'node:fs';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
function git(repo,...args){const r=spawnSync('git',args,{cwd:repo,encoding:'utf8',windowsHide:true});if(r.status!==0)throw Error(r.stderr||r.error?.message);return r.stdout.trim();}
export function canonicalRuntime(repo,expectedHead='HEAD') {
  const head=git(repo,'rev-parse',expectedHead),main=git(repo,'rev-parse','origin/main');
  if(head!==main)throw Error('deploy source must be the exact fetched origin/main before canonical runtime binding');
  const raw=spawnSync('git',['worktree','list','--porcelain','-z'],{cwd:repo,encoding:'utf8',windowsHide:true});
  if(raw.status!==0)throw Error(raw.stderr);
  const candidates=raw.stdout.split('\0\0').map(block=>block.split('\0')).filter(lines=>lines.includes('branch refs/heads/main'))
    .map(lines=>lines.find(line=>line.startsWith('worktree '))?.slice(9));
  if(candidates.length!==1||!candidates[0])throw Error('exactly one canonical main checkout is required; no actor tree was moved');
  const root=fs.realpathSync(candidates[0]);
  if(git(root,'rev-parse','HEAD')!==main||git(root,'status','--porcelain'))throw Error('canonical main checkout must be clean and equal to fetched origin/main');
  return path.resolve(root);
}
if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url)) {
  try{console.log(canonicalRuntime(path.resolve(process.argv[2]||'.')));}catch(error){console.error(error.message);process.exitCode=2;}
}
