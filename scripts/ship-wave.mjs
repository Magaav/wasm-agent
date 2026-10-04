import fs from 'node:fs';
import path from 'node:path';
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
