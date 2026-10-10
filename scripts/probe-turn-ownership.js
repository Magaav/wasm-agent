(async()=>{
 const report=document.createElement('pre');report.id='wa-probe';report.style.display='none';document.body.append(report);
 let checks=0;const check=(ok,label)=>{if(!ok)throw Error(label);checks++;};
 const tick=()=>Promise.resolve();
 try{
  await window.rendererLoaded;for(let i=0;i<200&&!transcriptReady;i++)await new Promise(r=>setTimeout(r,10));
  check(transcriptReady,'startup ready');
  for(let t=1;t<10000;t++){clearTimeout(t);clearInterval(t);}
  document.body.classList.add('expanded');
  busy=false;controller=null;observedRun=null;transcript=messages;clearStatus();runStepState=null;
  const now=Date.now()/1000,oldRows=[{id:'old-user',seq:1,role:'user',content:'OLD REQUEST',created_at:now-10},
   {id:'old-final',seq:2,role:'assistant',phase:'final_answer',content:'OLD FINAL ANSWER',created_at:now-2}];
  repaintMessages(oldRows,{state:'answered',notify:false});
  const oldBubble=messages.querySelector('wa-message.assistant'),oldHtml=oldBubble.innerHTML;
  const oldFetch=window.fetch,oldApi=apiFetch,oldHealth=nodeHealth,oldNative=nativeSessionTask,oldMeta=refreshMeta,oldNotify=notifyMetadataChange;
  const thread=chatSession;let releaseHistory,held,posts=0;
  try{
   // Pause an actual idle restore before a new submission, in the SAME thread.
   apiFetch=async route=>{if(route.startsWith('session?'))return new Promise(resolve=>{releaseHistory=()=>resolve({json:async()=>({session:{id:thread},messages:oldRows,state:{state:'answered'}})});});throw Error('unexpected route '+route);};
   nodeHealth=async()=>({ok:true,run_ids:[],node_threads:[],runs:[],queue:0});nativeSessionTask=async()=>null;
   refreshMeta=()=>{};notifyMetadataChange=()=>{};
   const staleRestore=restoreSessionOnce(thread,conversationEpoch,activeNode);
   for(let i=0;i<20&&!releaseHistory;i++)await tick();check(!!releaseHistory,'old transcript read is held');
   window.fetch=async(url,options)=>{
    if(String(url)==='chat'){posts++;return {body:new ReadableStream({start(c){held=c;}})};}
    return oldFetch(url,options);
   };
   const sending=send('NEW REQUEST');
   for(let i=0;i<40&&!held;i++)await tick();check(!!held&&posts===1,'new chat stream admitted once');
   const request=Array.from(messages.querySelectorAll('wa-message[role="user"]')).at(-1),newBubble=runBubble;
   check(request.textContent.includes('NEW REQUEST')&&newBubble!==oldBubble,'new request and separate assistant bubble exist');
   releaseHistory();await staleRestore;
   check(request.isConnected&&newBubble.isConnected&&runBubble===newBubble,'late same-thread restore cannot erase the optimistic request or rebind its answer');
   const emit=event=>held.enqueue(new TextEncoder().encode('data: '+JSON.stringify(event)+'\n\n'));
   emit({type:'delta',text:'NEW STREAM OUTPUT'});for(let i=0;i<30&&!newBubble.textContent.includes('NEW STREAM OUTPUT');i++)await tick();
   check(newBubble.textContent.includes('NEW STREAM OUTPUT')&&!oldBubble.textContent.includes('NEW STREAM OUTPUT'),'new output never enters old completed bubble');
   // Stale idle health must not free a stream between POST admission and run-list visibility.
   synced=true;await reconcile();
   check(busy&&controller&&request.isConnected,'idle health cannot release the current stream or erase request');
   check(oldBubble.innerHTML===oldHtml,'old answer and completion footer remain unchanged');
   sawTurnInFlight=true;runPolling=false;
   await watchTurn();
   check(busy&&runBubble===newBubble&&request.isConnected,'idle watchTurn with old in-flight marker cannot repaint a current own stream');
   emit({type:'reply',text:'NEW STREAM OUTPUT',message_id:'new-final'});emit({type:'done'});held.close();await sending;
   check(messages.querySelectorAll('wa-message[role="user"]').length===2&&messages.querySelectorAll('wa-message.assistant').length===2,'settlement preserves exactly two ordered turns');
   check(newBubble.querySelector('.finished'),'new turn gets its own final footer');
   // Repaint from authoritative rows after the stream ends is still allowed.
   const newRows=[...oldRows,{id:'new-user',seq:3,role:'user',content:'NEW REQUEST',created_at:now},
    {id:'new-final',seq:4,role:'assistant',content:'NEW STREAM OUTPUT',created_at:now+1}];
   apiFetch=async()=>({json:async()=>({session:{id:thread},messages:newRows,state:{state:'answered'}})});
   check(await restoreSessionOnce(thread,conversationEpoch,activeNode),'post-stream durable restore remains available');
   check(messages.textContent.includes('NEW REQUEST')&&messages.querySelectorAll('wa-message.assistant').length===2,'durable repaint retains turn boundaries');
   // A response begun before Continue is stale even if it arrives after the new stream closes.
   let releaseAgain;
   apiFetch=async()=>new Promise(resolve=>{releaseAgain=()=>resolve({json:async()=>({session:{id:thread},messages:newRows,state:{state:'answered'}})});});
   const staleAgain=restoreSessionOnce(thread,conversationEpoch,activeNode);
   for(let i=0;i<20&&!releaseAgain;i++)await tick();
   const continuing=resumeSession(thread);
   for(let i=0;i<40&&posts<2;i++)await tick();
   check(posts===2,'Continue admits one new request');
   const continuedRequest=Array.from(messages.querySelectorAll('wa-message[role="user"]')).at(-1),continuedBubble=runBubble;
   emit({type:'delta',text:'CONTINUED OUTPUT'});emit({type:'reply',text:'CONTINUED OUTPUT',message_id:'continue-final'});emit({type:'done'});held.close();await continuing;
   releaseAgain();await staleAgain;
   check(!busy&&continuedRequest.isConnected&&continuedBubble.isConnected,'late restore after Continue settlement is fenced by submission generation, not just busy');
   check(messages.querySelectorAll('wa-message[role="user"]').length===3&&messages.querySelectorAll('wa-message.assistant').length===3,'Continue preserves old answer and its new request/answer boundary');
   // Own newly scheduled fixture polling too; the screenshot must show the checked turns.
   for(let t=1;t<10000;t++){clearTimeout(t);clearInterval(t);}
   document.getElementById('panel').style.width='540px';
  }finally{window.fetch=oldFetch;apiFetch=oldApi;nodeHealth=oldHealth;nativeSessionTask=oldNative;refreshMeta=oldMeta;notifyMetadataChange=oldNotify;}
  report.dataset.status='pass';report.textContent=JSON.stringify({checks,skipped:0});
 }catch(e){report.dataset.status='fail';report.textContent=String(e.stack||e);}
})();
