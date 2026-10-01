// Reuse only a complete smoke receipt for the identical Git source tree.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';
export function fullProof(receipt,tree) {
  try {
    if((receipt.kind&&receipt.kind!=='full')||receipt.schema!==1||receipt.passed!==true||receipt.tree!==tree||receipt.gate_exit!==0||receipt.gate_runs!==1||!Number.isFinite(receipt.gate_ms)||receipt.gate_ms<0)throw Error('invalid full receipt');
    const bytes=fs.readFileSync(receipt.log),digest=crypto.createHash('sha256').update(bytes).digest('hex');
    const match=/(?:^|\n)smoke ok(?: \((\d+) skipped\))?\r?\n?$/.exec(bytes.toString());
    if(digest!==receipt.log_sha256||!match||Number(match[1]||0)!==receipt.skipped)throw Error('invalid full log or skips');
    return {verified:true,tree,head:receipt.head,log:receipt.log,log_sha256:digest,skipped:receipt.skipped,gate_ms:receipt.gate_ms,verdict_line:match[0].trim()};
  } catch(error){return {verified:false,reason:error.message};}
}
export function findFullProof(repo,tree) {
  const run=(cwd,args)=>spawnSync('git',args,{cwd,encoding:'utf8',windowsHide:true});
  const listed=run(repo,['worktree','list','--porcelain']);
  const roots=new Set([repo,...(listed.stdout||'').split('\n').filter(l=>l.startsWith('worktree ')).map(l=>l.slice(9))]);
  for(const root of roots) {
    try {
      for(const name of ['wa-finish-gate.json','wa-combined-gate.json']) {
        const located=run(root,['rev-parse','--git-path',name]);if(located.status!==0)continue;
        const file=path.resolve(root,located.stdout.trim());
        let receipt;try{receipt=JSON.parse(fs.readFileSync(file,'utf8'));}catch{continue;}
        if(path.resolve(receipt.repo)!==path.resolve(root))continue;
        const proof=fullProof(receipt,tree);if(proof.verified)return {...proof,receipt:file};
      }
    } catch { /* Missing/unreadable evidence requires execution; it never authorizes reuse. */ }
  }
  return {verified:false,reason:'no complete identical-tree smoke evidence'};
}

if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url)) {
  const [repo,tree]=process.argv.slice(2);
  const proof=findFullProof(path.resolve(repo||'.'),tree);
  console.log(JSON.stringify(proof));if(!proof.verified)process.exitCode=2;
}
