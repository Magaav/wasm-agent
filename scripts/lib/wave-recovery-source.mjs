// Exact reviewed source bytes; no environment path override.
import fs from 'node:fs';import path from 'node:path';import {spawnSync} from 'node:child_process';import {digest} from './wave-recovery.mjs';
export function verifyRecoverySource(repo,d){
 const fail=s=>{throw Error('recovery_source_'+s);};
 const bytes=(...a)=>{const r=spawnSync('git',['-C',repo,...a]);if(r.status!==0)fail('git_unavailable');return r.stdout;};
 const text=(...a)=>bytes(...a).toString().trim();
 if(![d.tip,d.tree,d.review_commit].every(x=>/^[a-f0-9]{40}$/.test(x||''))||d.kind!=='wave-reviewed-source'||text('rev-parse',`${d.tip}^{tree}`)!==d.tree)fail('identity');
 const review=JSON.parse(bytes('show',`${d.review_commit}:${d.review_path}`));
 const last=text('show','-s','--format=%B',d.review_commit).split(/\r?\n/).pop(),sessions=[...last.matchAll(/(?:^|\s)session=([^\s]+)/g)];
 if(review.kind!=='wave-source-review'||review.tip!==d.tip||review.tree!==d.tree||review.verdict!=='passed'||review.reviewer===review.producer||!last.startsWith('Agent:')||sessions.length!==1||sessions[0][1]!==review.reviewer)fail('review');
 // Pin every tracked JavaScript module in scripts, not an arbitrary claimed subset.
 const closure=text('ls-tree','-r','--name-only',d.tip,'scripts').split('\n').filter(x=>/\.(mjs|cjs)$/.test(x)).sort();
 if(!Array.isArray(d.files)||JSON.stringify(d.files.map(x=>x.path).sort())!==JSON.stringify(closure)||JSON.stringify(review.files)!==JSON.stringify(d.files))fail('closure');
 const root=fs.realpathSync(d.root),common=fs.realpathSync(text('rev-parse','--path-format=absolute','--git-common-dir'));
 const r=spawnSync('git',['-C',root,'rev-parse','--path-format=absolute','--git-common-dir'],{encoding:'utf8'});
 if(r.status!==0||fs.realpathSync(r.stdout.trim())!==common)fail('foreign_root');
 for(const f of d.files){if(!/^scripts\/[a-zA-Z0-9._/-]+\.(mjs|cjs)$/.test(f.path)||f.path.includes('..'))fail('path');if(digest(fs.readFileSync(path.join(root,f.path)))!==f.sha256||digest(bytes('show',`${d.tip}:${f.path}`))!==f.sha256)fail('bytes');}
 return {verified:true,root,tip:d.tip,tree:d.tree,files:d.files};
}
