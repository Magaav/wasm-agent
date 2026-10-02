const fs=require('node:fs'),path=require('node:path');
const {spawnSync}=require('node:child_process');
const [hook,out]=process.argv.slice(2);
// the packet shape lua/core/completions.lua's evaluation_packet builds
const packet={child:{id:'child-1',profile:'task-worker',state:'failed',error:'runaway_guard',model:'requested-model',reasoning:'high',served_model:'served-model',provider:'some-provider'},
  session:{id:'session-child-1',parent:'session-orchestrator',duration_s:12.5,started_at:1,settled_at:2},
  usage:{available:true,prompt:100,completion:20,total:120,cost_usd:0.004},
  artifacts:{available:true,managed:true,worktree:process.cwd(),branch:'change/x',head:'a'.repeat(40),dirty:0,untracked:0}};
const event={schema:1,child_id:'child-1',state:'failed',settled:true,session:'session-child-1',parent_session:'session-orchestrator',
  profile:'task-worker',artifacts:packet.artifacts,notification:{child:packet.child,session:packet.session,usage:packet.usage,review:{needs_wake:true,kind:'recovery',reason:'child_failed_needs_recovery_decision'}},
  changed_paths:['ui/app.js'],uncommitted_paths:[],changed_paths_source:'fixture'};
fs.writeFileSync(out,JSON.stringify(event));
const r=spawnSync(process.execPath,[hook,'--compose','--event',out],{encoding:'utf8',windowsHide:true});
const j=JSON.parse(r.stdout);
console.log(j.instruction.split('\n').filter((l)=>l.startsWith('child:')||l.startsWith('session:')||l.startsWith('model')||l.startsWith('changed')||l.startsWith('DEPLOY')).join('\n'));
console.log('--- the notification line, whole ---');
console.log(j.instruction.split('\n').find((l)=>l.startsWith('model')||l.startsWith('model/usage')));
