import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {canonicalRuntime} from './runtime-install-binding.mjs';
const root=fs.mkdtempSync(path.join(os.tmpdir(),'wa-runtime-install-binding-'));
function git(...args){const r=spawnSync('git',args,{cwd:root,encoding:'utf8',windowsHide:true});assert.equal(r.status,0,r.stderr);return r.stdout.trim();}
try {
  git('init','-q','--initial-branch','main');git('config','user.name','fixture');git('config','user.email','fixture@local');
  fs.writeFileSync(path.join(root,'source'),'accepted\n');git('add','.');git('commit','-qm','base');git('update-ref','refs/remotes/origin/main','HEAD');
  assert.equal(canonicalRuntime(root),fs.realpathSync(root));
  fs.writeFileSync(path.join(root,'dirty'),'preserve');assert.throws(()=>canonicalRuntime(root),/clean/);assert(fs.existsSync(path.join(root,'dirty')));fs.unlinkSync(path.join(root,'dirty'));
  git('switch','-q','--detach','HEAD');assert.throws(()=>canonicalRuntime(root),/canonical main checkout/);
  git('switch','-q','main');fs.appendFileSync(path.join(root,'source'),'pending');git('add','.');git('commit','-qm','ahead');
  assert.throws(()=>canonicalRuntime(root),/exact fetched origin/);
  console.log('runtime install binding ok (5 checks, 0 skipped; read-only canonical selection)');
} finally {fs.rmSync(root,{recursive:true,force:true});}
