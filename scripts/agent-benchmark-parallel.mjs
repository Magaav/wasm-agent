import assert from 'node:assert/strict';
// One native lifecycle per arm. No detached actors, fail-fast Promise.all, replay,
// registry or scheduler. Synchronous ownership-journal mutations stay one-writer.
export async function runParallelWave(arms,run,{halt=()=>{}}={}){
 assert(arms.length===4&&new Set(arms.map(x=>x.arm)).size===4,'four distinct arms');
 let release,releaseSettled,aborted=false;const ready=new Set(),ended=new Set(),starts=[];
 const barrier=new Promise(r=>release=r),settledBarrier=new Promise(r=>releaseSettled=r);
 startBarrier.settled=async arm=>{assert(!ended.has(arm),'duplicate actor settlement');ended.add(arm);if(ended.size===arms.length)releaseSettled();await settledBarrier;};
 async function startBarrier(arm){assert(!ready.has(arm),'duplicate arm start');ready.add(arm);starts.push({arm,ready_at:Date.now()});if(ready.size===arms.length)release();await barrier;if(aborted)throw Error('wave staging failed; no dispatch');}
 const settled=await Promise.allSettled(arms.map(async arm=>{try{return await run(arm,startBarrier);}catch(e){aborted=true;halt();release();releaseSettled();throw e;}}));
 // Every lifecycle's finally has drained its namespace and all process-tree
 // settlement waits have completed before this function can return or throw.
 const failures=settled.flatMap((x,i)=>x.status==='rejected'?[{arm:arms[i].arm,error:x.reason.message}]:[]);
 if(failures.length)throw Object.assign(Error('parallel wave failed after all lifecycle settlements'),{failures,settled: settled.map((x,i)=>({arm:arms[i].arm,status:x.status,result:x.status==='fulfilled'?x.value:null,error:x.status==='rejected'?x.reason.message:null}))});
 const results=settled.map(x=>x.value),overlap=Math.min(...results.map(x=>x.solver_ended_at))-Math.max(...results.map(x=>x.solver_released_at));
 return {results,starts,overlap_ms:overlap,timing:'concurrent shared-CPU/provider-contention affected; not clean backend latency ranking'};
}
