import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {canonicalRuntime,worktreeBlocks} from './runtime-install-binding.mjs';
const root=fs.mkdtempSync(path.join(os.tmpdir(),'wa-runtime-install-binding-'));
function git(...args){const r=spawnSync('git',args,{cwd:root,encoding:'utf8',windowsHide:true});assert.equal(r.status,0,r.stderr);return r.stdout.trim();}
try {
  git('init','-q','--initial-branch','main');git('config','user.name','fixture');git('config','user.email','fixture@local');
  fs.writeFileSync(path.join(root,'source'),'accepted\n');git('add','.');git('commit','-qm','base');git('update-ref','refs/remotes/origin/main','HEAD');
  assert.equal(canonicalRuntime(root),fs.realpathSync(root));
  fs.writeFileSync(path.join(root,'dirty'),'preserve');assert.throws(()=>canonicalRuntime(root),/clean/);assert(fs.existsSync(path.join(root,'dirty')));fs.unlinkSync(path.join(root,'dirty'));
  // git < 2.36 has no `worktree list -z` (Ubuntu 22.04: 2.34). A shim git that refuses -z the way 2.34
  // does must still select the same checkout, through the newline format.
  const shim=fs.mkdtempSync(path.join(os.tmpdir(),'wa-git234-'));const realGit=spawnSync('sh',['-c','command -v git'],{encoding:'utf8'}).stdout.trim();
  fs.writeFileSync(path.join(shim,'git'),`#!/bin/sh\nfor a in "$@"; do [ "$a" = "-z" ] && [ "$1 $2" = "worktree list" ] && { echo "error: unknown switch \\\`z'" >&2; exit 129; }; done\nexec ${realGit} "$@"\n`,{mode:0o755});
  const savedPath=process.env.PATH;process.env.PATH=`${shim}${path.delimiter}${savedPath}`;
  try{assert.equal(canonicalRuntime(root),fs.realpathSync(root));assert.equal(worktreeBlocks(root).length,1);}finally{process.env.PATH=savedPath;fs.rmSync(shim,{recursive:true,force:true});}
  git('switch','-q','--detach','HEAD');assert.throws(()=>canonicalRuntime(root),/canonical main checkout/);
  git('switch','-q','main');fs.appendFileSync(path.join(root,'source'),'pending');git('add','.');git('commit','-qm','ahead');
  assert.throws(()=>canonicalRuntime(root),/exact fetched origin/);
  console.log('runtime install binding ok (7 checks, 0 skipped; read-only canonical selection)');
} finally {fs.rmSync(root,{recursive:true,force:true});}
