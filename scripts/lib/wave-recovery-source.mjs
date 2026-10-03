// Explicit reviewed source bootstrap verification. No environment path override.
import fs from 'node:fs';import path from 'node:path';import {spawnSync} from 'node:child_process';import {digest} from './wave-recovery.mjs';
export function verifyRecoverySource(repo,descriptor){
 const git=(...a)=>{const r=spawnSync('git',['-C',repo,...a],{encoding:'utf8'});if(r.status!==0)throw Error('recovery_source_git_unavailable');return r.stdout.trim();};
 const fail=s=>{throw Error('recovery_source_'+s);};
 if(descriptor.kind!=='wave-reviewed-source'||git('rev-parse',`${descriptor.tip}^{tree}`)!==descriptor.tree)fail('identity');
 const review=JSON.parse(git('show',`${descriptor.review_commit}:${descriptor.review_path}`));
 const body=git('show','-s','--format=%B',descriptor.review_commit).split(/\r?\n/).pop();
 if(review.kind!=='wave-source-review'||review.tip!==descriptor.tip||review.tree!==descriptor.tree||review.verdict!=='passed'||review.reviewer===review.producer||!body.startsWith('Agent:')||!body.includes(`session=${review.reviewer}`))fail('review');
 if(!Array.isArray(descriptor.files)||!descriptor.files.length||JSON.stringify(review.files)!==JSON.stringify(descriptor.files))fail('closure');
 const root=fs.realpathSync(descriptor.root),common=git('rev-parse','--path-format=absolute','--git-common-dir');
 const r=spawnSync('git',['-C',root,'rev-parse','--path-format=absolute','--git-common-dir'],{encoding:'utf8'});
 if(r.status!==0||fs.realpathSync(r.stdout.trim())!==fs.realpathSync(common))fail('foreign_root');
 for(const f of descriptor.files){if(!/^scripts\/[a-zA-Z0-9._/-]+\.(mjs|cjs)$/.test(f.path)||f.path.includes('..'))fail('path');if(digest(fs.readFileSync(path.join(root,f.path)))!==f.sha256||digest(git('show',`${descriptor.tip}:${f.path}`))!==f.sha256)fail('bytes');}
 return {verified:true,root,tip:descriptor.tip,tree:descriptor.tree,files:descriptor.files};
}
