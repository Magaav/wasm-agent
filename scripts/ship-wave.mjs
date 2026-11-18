import fs from 'node:fs';
import path from 'node:path';
import { spawnSync, execFileSync } from 'node:child_process';
const [rootArg,installArg]=process.argv.slice(2),root=path.resolve(rootArg),install=path.resolve(installArg);
// Static closure only: quoted ESM import/export-from, import('literal'), and
// require('literal'). Computed paths remain runtime source references. Tokenize
// strings/comments/templates/regexes so prose is never interpreted as a dependency.
// Supported literals are unescaped, exact filenames (no Node extension/directory
// resolution). Template bodies, including interpolation, are not statically closed.
function dependencies(source) {
 const tokens=[];let i=0;
 while(i<source.length){
  const c=source[i];
  if(/\s/.test(c)){i++;continue;}
  if(source.startsWith('//',i)){i=source.indexOf('\n',i);if(i<0)break;continue;}
  if(source.startsWith('/*',i)){const end=source.indexOf('*/',i+2);if(end<0)throw Error('unterminated shipping comment');i=end+2;continue;}
  if(c==='"'||c==="'"||c==='`'){
   const quote=c;let value='',escaped=false;i++;
   while(i<source.length){const ch=source[i++];if(ch===quote)break;if(ch==='\\'){escaped=true;value+=ch+(source[i++]||'');}else value+=ch;}
   tokens.push({kind:quote==='`'?'template':'string',value,escaped});continue;
  }
  // Slash after an expression-start token is a regex, not executable identifiers.
  if(c==='/'&&(!tokens.length||/^(?:\(|\[|\{|=|:|,|;|!|\?|return|throw|=>)$/.test(tokens.at(-1).value))){
   i++;let bracket=false;while(i<source.length){const ch=source[i++];if(ch==='\\'){i++;continue;}if(ch==='[')bracket=true;if(ch===']')bracket=false;if(ch==='/'&&!bracket)break;}while(/[a-z]/i.test(source[i]||'')&&i<source.length)i++;tokens.push({kind:'regex',value:''});continue;
  }
  const word=source.slice(i).match(/^[A-Za-z_$][\w$]*/);
  if(word){tokens.push({kind:'word',value:word[0]});i+=word[0].length;}else{tokens.push({kind:'punct',value:c});i++;}
 }
 const out=[];
 const add=t=>{if(t?.kind==='string'&&t.value.startsWith('.')){if(t.escaped)throw Error('escaped shipping dependency unsupported');out.push(t.value);}};
 for(let n=0;n<tokens.length;n++){
  const t=tokens[n],prev=tokens[n-1]?.value;
  if(t.kind!=='word'||prev==='.'||prev==='?.')continue;
  if(t.value==='require'||t.value==='import'){
   if(tokens[n+1]?.value==='('&&tokens[n+3]?.value===')')add(tokens[n+2]);
   else if(t.value==='import')add(tokens[n+1]);
  }
  if(t.value==='from')add(tokens[n+1]);
 }
 return out;
}
// IS THIS TREE'S COMMIT ON A BRANCH THE REMOTE HAS? Shipping a tree's scripts into an install is shipping that
// tree's code onto a node, and the 18/11 artifact was exactly this: a build of commits that were on no branch
// anyone else could see, indistinguishable from a landed one until the next deploy of main removed what it
// carried. The answer comes from the ONE shared implementation (scripts/lib/shared-commit.sh, `git ls-remote`),
// and it is three-valued: yes, no, or cannot tell - the last two refuse unless the caller names the override
// (deploy.sh passes WA_ALLOW_UNSHARED_SHIP=1 only when its own --force --reason said so, recorded in deploy.log).
function commitShared(tree,commit){
 const lib=path.join(tree,'scripts','lib','shared-commit.sh');
 if(!fs.existsSync(lib))return{state:'unknown',why:'scripts/lib/shared-commit.sh is not beside this script'};
 try{
  const result=spawnSync('bash',[lib,tree,commit,'origin'],{encoding:'utf8',windowsHide:true});
  if(result.status===0)return{state:'yes',branches:(result.stdout||'').trim().split(/\s+/).filter(Boolean)};
  if(result.status===1)return{state:'no',why:(result.stderr||'').trim()};
  return{state:'unknown',why:(result.stderr||String(result.error||'')).trim()};
 }catch(error){return{state:'unknown',why:String(error)};}
}
const head=(()=>{try{return execFileSync('git',['-C',root,'rev-parse','HEAD'],{encoding:'utf8'}).trim();}catch{return'';}})();
if(head){
 const shared=commitShared(root,head);
 // WHO REFUSES, AND WHY NOT HERE BY DEFAULT: this script is also run by the gate's own checks (and by hand) on a
 // tree whose branch is not pushed yet - which is every change before it lands - so an unconditional refusal here
 // would refuse every unlanded change. The caller that puts code on a NODE is scripts/deploy.sh: it asks the same
 // question before it builds and refuses unless the operator recorded --force --reason. It then requires the same
 // answer here (WA_SHIP_REQUIRE_SHARED=1), so this step cannot ship what that decision refused, and an override is
 // the operator's own, named.
 if(shared.state==='yes')console.error(`ship-wave: ${head.slice(0,12)} is on a pushed branch: ${(shared.branches||[])[0]||'yes'}`);
 else if(process.env.WA_SHIP_REQUIRE_SHARED==='1'&&process.env.WA_ALLOW_UNSHARED_SHIP!=='1'){
  console.error(`ship-wave: refused(commit_not_on_pushed_branch): ${head.slice(0,12)} is on no branch the remote has (${shared.state==='no'?'git ls-remote answers: no branch contains it':(shared.why||'the remote could not be asked')}). Shipping these scripts would put code on a node that no landed branch can reproduce or review. Nothing was written.`);
  process.exit(2);
 }else if(shared.state==='no')console.error(`ship-wave: ${head.slice(0,12)} is on no branch the remote has; shipping because the caller did not require a shared commit (a deploy refuses this unless --force --reason)`);
 else console.error(`ship-wave: could not ask the remote whether ${head.slice(0,12)} is shared (${shared.why||'no answer'}); shipping because the caller did not require a shared commit`);
}
const scripts=path.join(root,'scripts'),files=new Set(),pending=fs.readdirSync(scripts).filter(name=>/^wave-.*\.(mjs|sh|json|lua)$/.test(name)).map(name=>path.join(scripts,name));
for(const name of ['lib/wave-guard.mjs','lib/full-gate-proof.mjs','lib/service-target.sh'])if(fs.existsSync(path.join(scripts,name)))pending.push(path.join(scripts,name));
while(pending.length){
 const file=pending.pop(),real=fs.realpathSync(file);
 if(!real.startsWith(fs.realpathSync(scripts)+path.sep))throw Error('wave shipping import escapes scripts: '+file);
 if(files.has(real))continue;files.add(real);
 if(/\.(?:mjs|cjs|js)$/.test(file)){
  for(const relative of dependencies(fs.readFileSync(file,'utf8'))){
   const target=path.resolve(path.dirname(file),relative);if(!fs.existsSync(target))throw Error('wave shipping dependency missing: '+target);pending.push(target);
  }
 }
}
for(const source of files){const relative=path.relative(scripts,source),target=path.join(install,'scripts',relative);fs.mkdirSync(path.dirname(target),{recursive:true});fs.copyFileSync(source,target);}
console.log(`wave scripts shipped (${files.size} files; literal relative JS module dependencies closed; dynamic source references use recorded runtime worktree)`);
