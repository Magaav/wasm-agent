const fs=require('node:fs'),path=require('node:path');const {spawn,spawnSync}=require('node:child_process');
const HOOK=process.argv[2],SENTINEL=process.argv[3],REPO=process.argv[4],S=process.argv[5];
const run=path.join(S,'d2');fs.rmSync(run,{recursive:true,force:true});fs.mkdirSync(run,{recursive:true});
const sleep=(ms)=>new Promise(r=>setTimeout(r,ms));
const g=(...a)=>{const r=spawnSync('git',a,{encoding:'utf8',windowsHide:true});return r.stdout.trim();};
const dir=path.join(S,'d2co');fs.rmSync(dir,{recursive:true,force:true});fs.mkdirSync(dir,{recursive:true});
g('init','-q','-b','main',dir);g('-C',dir,'config','user.email','p@p');g('-C',dir,'config','user.name','p');
fs.writeFileSync(path.join(dir,'README.md'),'b\n');g('-C',dir,'add','-A');g('-C',dir,'commit','-qm','base');
g('-C',dir,'update-ref','refs/remotes/origin/main','HEAD');g('-C',dir,'checkout','-qb','change/d2');
fs.mkdirSync(path.join(dir,'ui'),{recursive:true});fs.writeFileSync(path.join(dir,'ui','app.js'),'x\n');
g('-C',dir,'add','-A');g('-C',dir,'commit','-qm','w');
const head=g('-C',dir,'rev-parse','HEAD');const id='child-d2';
const task={subagent_id:id,state:'completed',settled:true,session_id:'s-'+id,profile:'task-worker',parent_session_id:'s-o'};
const packet={child:{id,state:'completed'},session:{id:'s-'+id,parent:'s-o'},artifacts:{available:true,managed:true,worktree:dir,branch:'change/d2',head,dirty:0,untracked:0}};
const spec=path.join(run,'spec.json'),pf=path.join(run,'port'),wf=path.join(run,'wakes.jsonl');
fs.writeFileSync(spec,JSON.stringify([{task,completion:{child_id:id,state:'completed',detail:'{}',packet:JSON.stringify(packet)}}]));
(async()=>{
 const node=spawn(process.execPath,[path.join(S,'probe','fake-node.cjs'),spec,pf,wf],{stdio:['ignore','pipe','pipe'],windowsHide:true});
 let port='';for(let i=0;i<100&&!port;i++){await sleep(50);if(fs.existsSync(pf))port=fs.readFileSync(pf,'utf8').trim();}
 const env={...process.env,WASM_AGENT_HOME:path.join(run,'home'),WASM_AGENT_PORT:port,WA_SENTINEL_BIN:SENTINEL,
  WA_SENTINEL_AUTH_SESSION:'p',WA_SENTINEL_SCRIPTS:`${path.join(REPO,'scripts')};${S}`,WA_SENTINEL_RETURN_STATE:path.join(run,'cursor.json'),
  WASM_AGENT_RELAY:'',WASM_AGENT_RENDEZVOUS:'',WASM_AGENT_MANAGED:'0',WA_SENTINEL_WAKE_BUDGET:'24',WA_SENTINEL_JOB_WAKE_BUDGET:'24',WA_SENTINEL_JOB_RESERVED_CHILD_CAPACITY:'1'};
 delete env.WA_SCRIPT;delete env.WASM_AGENT_LUA_ROOT;
 const cli=(...a)=>spawnSync(SENTINEL,['job',...a],{env,encoding:'utf8',timeout:30000,windowsHide:true});
 const def=JSON.parse(fs.readFileSync(path.join(REPO,'jobs','on-subagent-return.json'),'utf8'));
 def.action.session='probe';def.action.prepare.script=path.join(REPO,'scripts','subagent-return-prepare.sh');
 const jf=path.join(run,'j.json');fs.writeFileSync(jf,JSON.stringify(def));
 cli('put',jf);cli('enable','onSubagentReturn');
 const marker=path.join(run,'home','.wasm-agent','sentinel','completion-wake-superseded');
 const watcher=spawn(SENTINEL,['watch'],{env,stdio:['ignore','pipe','pipe'],windowsHide:true});
 for(let i=0;i<100&&!fs.existsSync(marker);i++) await sleep(200);
 console.log('marker before the pass:',fs.existsSync(marker)?fs.readFileSync(marker,'utf8').replace(/\s+/g,' '):'(absent)');
 const r=spawnSync(process.execPath,[HOOK,'--observe','--node',`http://127.0.0.1:${port}`,'--state',path.join(run,'cursor.json'),'--emit-command',SENTINEL],{env,encoding:'utf8',timeout:60000,windowsHide:true});
 console.log('observe:',r.stdout.trim().replace(/\s+/g,' '));
 for(let i=0;i<150&&(!fs.existsSync(wf)||fs.readFileSync(wf,'utf8').trim()==='');i++) await sleep(200);
 const lines=fs.existsSync(wf)?fs.readFileSync(wf,'utf8').split('\n').filter(Boolean):[];
 console.log('wakes while the marker is present:',lines.length);
 if(lines.length)console.log('wake carries:',lines[0].split('DEPLOY VERDICT')[1].slice(0,60));
 console.log('history:',cli('history').stdout.replace(/\s+/g,' ').slice(0,200));
 watcher.kill();node.kill();process.exit(0);})();
