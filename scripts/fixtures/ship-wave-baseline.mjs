// Baseline from 3f54a90d9d23b105df93002a683135d62cde81e0:scripts/ship-wave.mjs.
import fs from 'node:fs';
import path from 'node:path';
const [rootArg,installArg]=process.argv.slice(2),root=path.resolve(rootArg),install=path.resolve(installArg);
const scripts=path.join(root,'scripts'),files=new Set(),pending=fs.readdirSync(scripts).filter(name=>/^wave-.*\.(mjs|sh|json|lua)$/.test(name)).map(name=>path.join(scripts,name));
for(const name of ['lib/wave-guard.mjs','lib/full-gate-proof.mjs','lib/service-target.sh'])if(fs.existsSync(path.join(scripts,name)))pending.push(path.join(scripts,name));
while(pending.length){
 const file=pending.pop(),real=fs.realpathSync(file);
 if(!real.startsWith(fs.realpathSync(scripts)+path.sep))throw Error('wave shipping import escapes scripts: '+file);
 if(files.has(real))continue;files.add(real);
 if(file.endsWith('.mjs')){
  const source=fs.readFileSync(file,'utf8');
  for(const match of source.matchAll(/(?:\bfrom\s*|\bimport\s*\(\s*|\bimport\s*)['"](\.[^'"]+)['"]/g)){
   const target=path.resolve(path.dirname(file),match[1]);if(!fs.existsSync(target))throw Error('wave shipping dependency missing: '+target);pending.push(target);
  }
 }
}
for(const source of files){const relative=path.relative(scripts,source),target=path.join(install,'scripts',relative);fs.mkdirSync(path.dirname(target),{recursive:true});fs.copyFileSync(source,target);}
console.log(`wave scripts shipped (${files.size} files; literal relative imports closed; dynamic source references use recorded runtime worktree)`);
