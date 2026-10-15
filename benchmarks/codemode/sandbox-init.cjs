// One-shot lifetime backstop, not a watcher or inference worker. Workspace data
// is in a generation-owned persistent volume and survives this process's exit.
if(process.pid!==1)throw Error('private tool PID namespace required');const fs=require('node:fs');fs.mkdirSync('/tmp/work',{recursive:true});let finishing=false;
function finish(reason){if(finishing)return;finishing=true;console.log(JSON.stringify({phase:'sandbox-stopped',reason,workspace_volume_preserved:true}));process.exit(0);}
process.on('SIGTERM',()=>finish('controller-stop'));console.log('sandbox-ready');setTimeout(()=>finish('experiment-lifetime'),Number(process.argv[1]));
