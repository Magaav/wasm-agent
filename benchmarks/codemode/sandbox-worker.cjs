// One raw filesystem/process request INSIDE the blind, networkless tool container.
// No model runtime, credentials, repaired Lua, grader or original Git is installed here.
const fs=require('node:fs'),path=require('node:path'),cp=require('node:child_process'),z=require('node:zlib');
const cwd='/tmp/work';let effectStarted=false;
function checked(p,write=false){
 if(typeof p!=='string')throw Error('path_required');if(/^[a-zA-Z]:[\\/]|^\\\\/.test(p))throw Error('sandbox_path_outside_workspace');p=path.posix.resolve(cwd,p);
 if(p!==cwd&&!p.startsWith(cwd+'/'))throw Error('sandbox_path_outside_workspace');
 let q=p;while(!fs.existsSync(q)){const parent=path.dirname(q);if(parent===q)break;q=parent;}
 const real=fs.realpathSync(q);if(real!==cwd&&!real.startsWith(cwd+'/'))throw Error('sandbox_symlink_escape');
 return p;
}
function pids(){return fs.readdirSync('/proc').filter(x=>/^\d+$/.test(x));}
function main({op,args=[]}){
 if(op==='import_tree'){if(fs.readdirSync(cwd).length)throw Error('fresh_sandbox_import_only');const rows=JSON.parse(z.gunzipSync(Buffer.from(args[0],'base64'),{maxOutputLength:128*1024*1024}));for(const row of rows){if(typeof row.path!=='string'||row.path.startsWith('/')||row.path.split('/').some(p=>p==='..'||p===''))throw Error('import_escape');const p=checked(row.path,true);effectStarted=true;fs.mkdirSync(path.dirname(p),{recursive:true});fs.writeFileSync(p,Buffer.from(row.base64,'base64'),{flag:'wx',mode:row.mode});}return rows.length;}
 if(op==='export_tree'){const rows=[];let bytes=0;function walk(dir){for(const name of fs.readdirSync(dir).sort()){const p=path.join(dir,name),s=fs.lstatSync(p);if(s.isSymbolicLink()||!s.isDirectory()&&!s.isFile()||s.isFile()&&s.nlink!==1)throw Error('linked_or_special_candidate');if(s.isDirectory())walk(p);else{bytes+=s.size;if(bytes>64*1024*1024)throw Error('candidate_export_bound');rows.push({path:path.relative(cwd,p),mode:s.mode&511,base64:fs.readFileSync(p).toString('base64')});}}}walk(cwd);return z.gzipSync(Buffer.from(JSON.stringify(rows))).toString('base64');}
 if(op==='read_file'){try{const b=fs.readFileSync(checked(args[0]));try{return new TextDecoder('utf8',{fatal:true,ignoreBOM:true}).decode(b);}catch{return null;}}catch(e){if(e.code==='ENOENT'||e.code==='EISDIR')return null;throw e;}}
 if(op==='read_image_base64'){let b;try{b=fs.readFileSync(checked(args[0]));}catch(e){if(e.code==='ENOENT')return JSON.stringify({error:'not_found'});throw e;}const mime=b.subarray(0,8).equals(Buffer.from([137,80,78,71,13,10,26,10]))?'image/png':b[0]===255&&b[1]===216?'image/jpeg':b.subarray(0,3).toString()==='GIF'?'image/gif':b.subarray(0,4).toString()==='RIFF'&&b.subarray(8,12).toString()==='WEBP'?'image/webp':null;return JSON.stringify(!mime?{error:'not_image'}:b.length>args[1]?{error:'image_too_large'}:{mime,base64:b.toString('base64')});}
 if(op==='read_bytes')return fs.readFileSync(checked(args[0])).toString('base64');
 if(op==='access'){fs.accessSync(checked(args[0]));return true;}
 if(op==='mkdir'){const p=checked(args[0],true);effectStarted=true;fs.mkdirSync(p,{recursive:true});return true;}
 if(op==='write_file'){const p=checked(args[0],true);effectStarted=true;fs.mkdirSync(path.dirname(p),{recursive:true});fs.writeFileSync(p,args[1]);return true;}
 if(op==='path_kind'){try{const s=fs.statSync(checked(args[0]));return s.isFile()?'file':s.isDirectory()?'directory':'other';}catch(e){if(e.code==='ENOENT')return 'missing';throw e;}}
 if(op==='canonical_path'){try{return fs.realpathSync(checked(args[0]));}catch(e){if(e.code==='ENOENT')return null;throw e;}}
 if(op==='list_dir'){const p=checked(args[0]);return JSON.stringify({path:p,entries:fs.readdirSync(p,{withFileTypes:true}).map(d=>({name:d.name,kind:d.isDirectory()?'directory':d.isFile()?'file':'other'}))});}
 if(op==='exec'){
  if(typeof args[0]!=='string'||args[0].length>1048576)throw Error('invalid_shell');
  const seconds=args[2]??300;if(!Number.isSafeInteger(seconds)||seconds<1||seconds>2700)throw Error('invalid_shell_timeout');
  const before=new Set(pids()),start=performance.now();
  const r=cp.spawnSync('/bin/bash',['-c',args[0]],{cwd,env:{PATH:'/usr/local/bin:/usr/bin:/bin',HOME:'/tmp/work',LANG:'C.UTF-8',WA_BENCHMARK_TOOL_SANDBOX:'1',...args[3]},encoding:null,timeout:seconds*1000,maxBuffer:16*1024*1024});
  const descendants=pids().filter(p=>!before.has(p));
  return JSON.stringify({code:r.status,ok:r.status===0,stdout:r.stdout?.toString('utf8')??'',stderr:r.stderr?.toString('utf8')??'',stdout_base64:r.stdout?.toString('base64')??'',stderr_base64:r.stderr?.toString('base64')??'',text_lossy:!!(r.stdout&&!Buffer.from(r.stdout.toString('utf8')).equals(r.stdout)||r.stderr&&!Buffer.from(r.stderr.toString('utf8')).equals(r.stderr)),error:r.error?.message??null,elapsed_ms:performance.now()-start,cleanup:r.error||descendants.length?'unknown':'settled',descendants,output_complete:!r.error,output_streams_closed:!r.error});
 }
 if(op==='grep'){
  const [pattern,root,encoded]=args,o=JSON.parse(encoded),base=checked(root),matches=[],skipped=[];let files=0,dirs=0,complete=true;
  const target=o.ignore_case===false?pattern:pattern.toLowerCase();
  function scan(p,depth){if(matches.length>=(o.limit??100)){complete=false;return;}const s=fs.lstatSync(p);if(s.isSymbolicLink()){skipped.push({path:p,reason:'symlink'});return;}
   if(s.isDirectory()){dirs++;if(depth>(o.max_depth??12))return;for(const n of fs.readdirSync(p).sort())scan(path.join(p,n),depth+1);return;}
   if(!s.isFile()||o.extensions?.length&&!o.extensions.some(e=>p.endsWith('.'+e)))return;files++;
   const b=fs.readFileSync(p);if(b.includes(0)){skipped.push({path:p,reason:'binary'});return;}const lines=b.toString('utf8').split('\n');
   for(let n=0;n<lines.length;n++){const line=lines[n];if((o.ignore_case===false?line:line.toLowerCase()).includes(target)){if(matches.length>=(o.limit??100)){complete=false;break;}matches.push({file:p,line:n+1,text:line,text_truncated:false});}}
  }scan(base,0);return JSON.stringify({matches,count:matches.length,complete,truncated:!complete,skipped,files_scanned:files,directory_entries_observed:dirs,literal:true});
 }
 throw Error('unsupported_sandbox_operation');
}
try{const request=JSON.parse(fs.readFileSync(0,'utf8'));console.log(JSON.stringify({ok:true,value:main(request)}));}
catch(e){console.log(JSON.stringify({ok:false,error:e.message,code:e.code??null,effect:effectStarted?'unknown':'none'}));process.exitCode=1;}
