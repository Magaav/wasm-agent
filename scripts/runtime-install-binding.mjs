import fs from 'node:fs';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {isMain} from './lib/main-module.mjs';
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
  // IS THIS TREE MAIN? ONE ANSWER, IN ONE PLACE (work update retry #3, 27/11: this was the SECOND owner of the
  // question - deploy.sh step 0b had already accepted a tree that is ON main but not its tip, and this refusal then
  // rejected the same tree before anything was built, with `deploy source must be the exact fetched origin/main`).
  // The rule deploy.sh now applies is ancestry, so the binding applies ancestry too: a tree on a main commit that has
  // moved forward is main. A commit that is NOT an ancestor is still refused, by name.
  const onMain=spawnSync('git',['merge-base','--is-ancestor',head,main],{cwd:repo});
  if(onMain.status!==0)throw Error(`deploy source must be a commit on ${mainRef} before canonical runtime binding: `
    + `the tree is on ${head.slice(0,12)}, ${mainRef} is ${main.slice(0,12)}; if this tree should follow it, run `
    + `git -C <tree> fetch ${mainRef.split('/')[0]} and git -C <tree> reset --hard ${mainRef}`);
  const candidates=worktreeBlocks(repo).filter(lines=>lines.includes('branch refs/heads/main'))
    .map(lines=>lines.find(line=>line.startsWith('worktree '))?.slice(9));
  // The refusal names EVERY candidate (item 9, 18/11): the operator had two worktrees on branch main and
  // was told only that one was required, after waiting four minutes for a build it never needed.
  if(candidates.length!==1||!candidates[0])throw Error(`exactly one canonical main checkout is required; found ${candidates.length} on branch refs/heads/main (${candidates.length?candidates.join(', '):'none'}) - a runtime binding is installed from exactly one tree, so remove or re-point the extra checkout(s); no actor tree was moved`);
  const root=fs.realpathSync(candidates[0]);
  // THE SAME QUESTION, ASKED OF THE CHECKOUT ITSELF (work retry #3, 27/11): this said the canonical checkout must be
  // EQUAL to origin/main, which is the rule the other two callers just stopped applying. A checkout that is clean and
  // on a main commit that has moved forward is still a canonical main checkout; a dirty one, or one off main, is not.
  const clean=!git(root,'status','--porcelain');
  const checkoutOnMain=spawnSync('git',['merge-base','--is-ancestor',git(root,'rev-parse','HEAD'),main],{cwd:root});
  if(!clean||checkoutOnMain.status!==0)throw Error(`canonical main checkout must be clean and on ${mainRef} (found ${git(root,'rev-parse','HEAD').slice(0,12)}${clean?'':' dirty'})`);
  return path.resolve(root);
}
if(process.argv[1]&&isMain(import.meta.url)) {
  try{console.log(canonicalRuntime(path.resolve(process.argv[2]||'.')));}catch(error){console.error(error.message);process.exitCode=2;}
}
