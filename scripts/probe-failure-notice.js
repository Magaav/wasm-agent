(async()=>{
 const report=document.createElement('pre');report.id='wa-probe';report.style.display='none';document.body.append(report);
 let checks=0;const check=(ok,label)=>{if(!ok)throw Error(label);checks++;};
 try{
  await window.rendererLoaded;
  for(let i=0;i<200&&!transcriptReady;i++)await new Promise(resolve=>setTimeout(resolve,10));
  check(transcriptReady,'startup ready');
  for(let timer=1;timer<10000;timer++){clearTimeout(timer);clearInterval(timer);}
  busy=false;observedRun=null;activeRunId=null;blankSession='';transcript=messages;clearStatus();runBubble=null;
  const oldFetch=apiFetch,oldHealth=nodeHealth,oldNative=nativeSessionTask,thread=chatSession,epoch=conversationEpoch;
  const error='operation_output_open_failed: operation=op-fixture stream=stdout path=fixture/stdout: missing <img src=x onerror=alert(1)>';
  const now=Date.now()/1000;
  const rows=[{seq:1,role:'user',content:'Complete the work',created_at:now-10},
   {seq:2,role:'assistant',content:'',tool_calls:[{id:'checked',function:{name:'read',arguments:'{}'}}],created_at:now-3},
   {seq:3,role:'tool',tool_name:'read',tool_call_id:'checked',content:'Verified completed work',ok:1,created_at:now-2},
   {seq:4,role:'assistant',content:'',ok:0,created_at:now,trace:[{kind:'tool',ok:false,error:'older failure'},{kind:'model_call',ok:false,error},{kind:'run_counts',version:1,run_id:'fixture',model_calls:2,tool_calls:1,complete:true}]}];
  try{
   const full={session:{id:thread,mode:'default'},messages:rows,state:{state:'failed',detail:'the last run failed (inspect its error and transcript)'}};
   apiFetch=async route=>{check(route==='session?id='+encodeURIComponent(thread),'known thread reads only its ledger');return {ok:true,json:async()=>full};};
   nativeSessionTask=async()=>null;
   nodeHealth=async()=>({ok:true,run_ids:[],node_threads:[],queue:0});
   check(await restoreSessionOnce(thread,epoch,activeNode),'failure restore succeeds');
   const notice=messages.querySelector('.unfinished-notice');
   check(notice&&notice.textContent.includes(error),'yellow notice shows actual failed model error on older generic nodes');
   check(!notice.textContent.includes('older failure'),'notice never blames an earlier tool');
   check(!notice.querySelector('img'),'recorded error is text, never executable HTML');
   check(notice.querySelector('button')?.textContent==='continue','explicit continuation control retained');
   check(messages.querySelector('.finished .chat-content-run-label').textContent==='failed','actual failure remains failed');
   const fallback=sessionOutcome({...full,messages:[{...rows.at(-1),trace:[]}]});
   check(fallback.detail===full.state.detail,'missing evidence does not invent a cause');
   check(sessionOutcome({state:'answered',messages:rows}).name==='answered','only terminal failed state extracts errors');
   check(sessionOutcome({...full,state:{state:'failed',detail:'authoritative redacted cause'}}).detail==='authoritative redacted cause','authoritative non-generic error is not overwritten');
   const malformed={...rows.at(-1),trace:[null,{ok:false,error:'after null'}]};
   check(sessionOutcome({...full,messages:[malformed]}).detail==='after null','malformed historical trace entries cannot hide remaining error');
   document.getElementById('panel').style.width='540px';
  }finally{apiFetch=oldFetch;nodeHealth=oldHealth;nativeSessionTask=oldNative;}
  report.dataset.status='pass';report.textContent=JSON.stringify({checks,skipped:0});
 }catch(e){report.dataset.status='fail';report.textContent=String(e.stack||e);}
})();
