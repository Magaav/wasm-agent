// Actual Docker effects for generation-owned resources only; no pull/prune/force.
import fs from 'node:fs';import path from 'node:path';import crypto from 'node:crypto';import {spawnSync} from 'node:child_process';
export function realDockerAdapter(root,{imageId,command=['node','-e','console.log("model-free disposable")']}={}) {
  root=path.resolve(root);
  const state=()=>JSON.parse(fs.readFileSync(path.join(root,'owner.json')));
  function run(args,{absence=false}={}) {
    const r=spawnSync('docker',args,{encoding:'utf8',timeout:15000,maxBuffer:8388608});
    const s=state(),log=s.phase==='collecting'?path.join(root,'records','docker-cli.jsonl'):path.join(root,'docker-cleanup.jsonl');
    fs.appendFileSync(log,JSON.stringify({args,code:r.status,error:r.error?.message??null,stdout:r.stdout||'',stderr:r.stderr||'',at:Date.now()})+'\n');
    if(absence && r.status===1 && /No such (?:object|container|volume|network)/i.test(r.stderr))return null;
    if(r.error || r.status!==0)throw Error('Docker command uncertain/refused: '+(r.error?.message||r.stderr));return r.stdout.trim();
  }
  function save(s){fs.writeFileSync(path.join(root,'owner.json'),JSON.stringify(s));}
  function effect(id,action,invoke) {
    const s=state(),r=s.docker_resources?.find(r=>r.id===id);if(!r || r.effect_state && r.effect_state!=='settled' && !(action==='stopping' && r.effect_state==='running'))throw Error('Docker effect uncertain; do not replay');
    r.effect_state=action;save(s);
    try {const result=invoke();r.effect_state=action==='starting'?'running':'settled';save(s);return result;}
    catch(e){r.effect_state='unknown';r.effect_error=e.message;save(s);throw e;}
  }
  function inspect(id) {
    if(!/^[a-zA-Z0-9_.-]+$/.test(id))throw Error('invalid Docker identity');
    const raw=run(['inspect',id],{absence:true});if(raw===null)return {id,absent:true};
    const x=JSON.parse(raw)[0],labels=x.Config?.Labels||x.Labels||{},kind=x.State?'container':x.Containers?'network':'volume';
    let shared=false,running=false,effects='settled';
    if(kind==='container') {
      shared=(x.Mounts||[]).length>0;
      running=x.State.Running===true||x.State.Restarting===true||x.State.Pid>0;
      if(x.State.Dead===true || !['created','exited'].includes(x.State.Status) && !running)effects='unknown';
    } else if(kind==='network') {
      shared=Object.keys(x.Containers||{}).length>0;running=shared;
    } else {
      shared=run(['ps','-a','--filter','volume='+id,'--format','{{.ID}}'])!=='';running=shared;
    }
    return {id,kind,generation:labels['wa.benchmark.generation'],owner_nonce:labels['wa.benchmark.owner'],shared,running,effects};
  }
  return {
    inspect,
    create(labels) {
      const s=state();if(s.phase!=='collecting'||s.docker_creation!=='reserved'||labels.generation!==s.generation||labels.owner_nonce!==s.nonce)throw Error('Docker create ownership refusal');
      const name='wa-bench-hermetic-'+crypto.randomUUID(),flags=['--label','wa.benchmark.generation='+s.generation,'--label','wa.benchmark.owner='+s.nonce];let id;
      if(labels.kind==='container') {
        if(!/^sha256:[a-f0-9]{64}$/.test(imageId||''))throw Error('exact cached image ID required');
        const pinned=JSON.parse(run(['image','inspect',imageId]))[0];if(pinned.Id!==imageId)throw Error('image drift');
        id=run(['create','--pull','never','--name',name,...flags,'--network','none','--read-only','--cap-drop','ALL','--security-opt','no-new-privileges','--pids-limit','32','--memory','128m','--cpus','0.5',imageId,...command]);
      } else if(labels.kind==='network')id=run(['network','create','--internal',...flags,name]);
      else if(labels.kind==='volume')id=run(['volume','create',...flags,name]);
      else throw Error('unsupported Docker type');return {id,kind:labels.kind};
    },
    start(id) {
      const s=state(),r=s.docker_resources?.find(r=>r.id===id),x=inspect(id);
      if(s.phase!=='collecting'||!r||r.kind!=='container'||x.generation!==s.generation||x.owner_nonce!==s.nonce)throw Error('Docker start ownership refusal');return effect(id,'starting',()=>run(['start',id]));
    },
    stop(id) {
      const s=state(),r=s.docker_resources?.find(r=>r.id===id),x=inspect(id);
      if(!r||r.kind!=='container'||x.generation!==s.generation||x.owner_nonce!==s.nonce)throw Error('Docker stop ownership refusal');
      // Explicit caller cancellation only. Never automatic stop or effect replay.
      if(!x.running)throw Error('Docker process already stopped; do not replay');
      return effect(id,'stopping',()=>{run(['stop','--time','1',id]);const observed=inspect(id);if(observed.running||observed.effects!=='settled')throw Error('Docker drain unproven');run(['logs',id]);return observed;});
    },
    drain(id) {
      const s=state(),r=s.docker_resources?.find(r=>r.id===id),x=inspect(id);
      if(!r || r.effect_state!=='running' || x.generation!==s.generation || x.owner_nonce!==s.nonce || x.running || x.effects!=='settled')throw Error('Docker drain unknown/live');
      run(['logs',id]);r.effect_state='settled';save(s);return x;
    },
    remove(id) {
      const s=state(),r=s.docker_resources?.find(r=>r.id===id),x=inspect(id);
      if(s.phase!=='sealed'||!r||r.state!=='removing'||x.generation!==s.generation||x.owner_nonce!==s.nonce||x.shared||x.running||x.effects!=='settled')throw Error('Docker remove ownership/drain refusal');
      run(r.kind==='container'?['rm',id]:[r.kind,'rm',id]);const absent=inspect(id);if(absent.absent!==true)throw Error('Docker removal uncertain');return {id,kind:r.kind,settled:true,absent:true};
    }
  };
}
