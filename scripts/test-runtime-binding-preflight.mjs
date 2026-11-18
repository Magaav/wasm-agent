// Item 9 of the harness-fixes mission (18/11): the canonical runtime binding is decided in PREFLIGHT,
// before anything is built, and its refusal names every worktree that is on branch main.
//
// Measured: a deploy refused after ~4 minutes of build and prove with "exactly one canonical main checkout
// is required" and named neither of the two paths the operator had to choose between.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {canonicalRuntime} from '../scripts/runtime-install-binding.mjs';

let checks=0;
const check=(value,label)=>{ if(!value) throw Error(label); checks++; };
const root=path.resolve(import.meta.dirname,'..');
const git=(cwd,...args)=>{
  const r=spawnSync('git',args,{cwd,encoding:'utf8',windowsHide:true});
  if(r.status!==0) throw Error('git '+args.join(' ')+': '+(r.stderr||r.error?.message));
  return r.stdout.trim();
};
const scratch=fs.mkdtempSync(path.join(os.tmpdir(),'wa-binding-test-'));
try {
  const origin=path.join(scratch,'origin.git');
  const repo=path.join(scratch,'canonical');
  fs.mkdirSync(origin);
  git(origin,'init','--bare','--initial-branch=main');
  git(scratch,'init','--initial-branch=main','canonical');
  fs.writeFileSync(path.join(repo,'README.md'),'fixture\n');
  git(repo,'add','README.md');
  git(repo,'-c','user.email=test@example.com','-c','user.name=test','commit','-m','fixture');
  git(repo,'remote','add','origin',origin);
  git(repo,'push','-q','origin','main');
  git(repo,'fetch','-q','origin');
  // A second worktree checked out on branch main: the shape that cost a four-minute build.
  const second=path.join(scratch,'second');
  git(repo,'worktree','add','--detach',second,'HEAD');
  fs.writeFileSync(path.join(repo,'.git','worktrees','second','HEAD'),'ref: refs/heads/main\n');
  const listed=git(repo,'worktree','list','--porcelain');
  check((listed.match(/branch refs\/heads\/main/g)||[]).length===2,'fixture: two worktrees on branch main');

  let message='';
  try { canonicalRuntime(repo,'HEAD','origin/main'); } catch (error) { message=error.message; }
  check(message.includes('exactly one canonical main checkout is required'),
    'ITEM 9: the refusal still says what is required: '+message);
  check(message.includes(fs.realpathSync(repo)),'ITEM 9: it names the canonical path: '+message);
  check(message.includes(fs.realpathSync(second)),'ITEM 9: and the second worktree: '+message);

  // The decision is in preflight: the binding call is in scripts/deploy.sh, and nothing builds before it.
  const deploy=fs.readFileSync(path.join(root,'scripts','deploy.sh'),'utf8');
  const binding=deploy.indexOf('runtime-install-binding.mjs');
  const build=deploy.search(/cargo build/);
  check(binding>=0,'ITEM 9: deploy.sh resolves the canonical binding itself');
  check(build>=0,'ITEM 9: and it does build later in the same script');
  check(binding<build,'ITEM 9: the binding is decided before the first build command (binding at '+binding+', build at '+build+')');
  check(deploy.includes('canonical runtime binding refused before anything was built'),
    'ITEM 9: and its refusal says nothing was built');
  console.log(JSON.stringify({ok:true,checks}));
} finally {
  fs.rmSync(scratch,{recursive:true,force:true});
}