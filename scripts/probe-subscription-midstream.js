(async()=>{
 const report=document.createElement('pre');report.id='wa-probe';document.body.append(report);let checks=0;
 const check=(v,label)=>{if(!v)throw Error(label);checks++;};
 try{
  await window.rendererLoaded;for(let i=0;i<100;i++)await Promise.resolve();
  busy=true;activeRunId='fixture-midstream';observedRun=null;runStepState=null;runBubble=null;
  repaintMessages([{id:'midstream-user',seq:1,role:'user',content:'Recover an interrupted tool selection',created_at:Date.now()/1000}],{active:true,notify:false});
  handleEvent({type:'round',n:1});handleEvent({type:'reasoning',text:'OLD THINKING'});
  handleEvent({type:'pending_delta',pending_id:'old:0',text:'OLD COMMENTARY'});
  handleEvent({type:'commentary',message_id:'old-message',pending_id:'old:0',text:'OLD COMMENTARY'});
  handleEvent({type:'decision',call_id:'old-call',name:'write',arguments_text:'incomplete',complete:false});
  const saved={id:'old',tools_executed:0,reasoning:'OLD THINKING',texts:[{pending_id:'old:0',text:'OLD COMMENTARY',phase:'commentary'}],decisions:[{call_id:'old-call',name:'write',arguments_text:'incomplete',complete:false}]};
  const interrupted={type:'retry',retry_id:'fixture',index:1,limit:10,cycle:1,state:'interrupted',reason:'response_body: UND_ERR_SOCKET',discarded_attempt:saved};
  handleEvent(interrupted);
  check(!trace&&!reasoningBlock&&phasePendingText.size===0,'abandoned preview state sealed');
  check(transcript.querySelectorAll('[data-interrupted-attempt]').length===1,'one durable interruption marker');
  check(Array.from(transcript.querySelectorAll('wa-commentary')).filter(n=>n.textContent.includes('OLD COMMENTARY')).length===1,'old commentary not duplicated');
  check(transcript.querySelector('.tool-outcome').textContent==='not executed','abandoned write never painted executed');
  check(transcript.querySelector('[data-pending-id="old:0"]').classList.contains('phase-incomplete'),'completed commentary now explicitly interrupted');
  handleEvent(interrupted);check(transcript.querySelectorAll('[data-interrupted-attempt]').length===1,'duplicate snapshot safe');
  handleEvent({type:'reasoning',text:'NEW THINKING'});check(!reasoningBlock.textContent.includes('OLD THINKING'),'new attempt thinking isolated');
  handleEvent({type:'pending_delta',pending_id:'new:0',text:'NEW ANSWER'});
  handleEvent({type:'decision',call_id:'new-call',name:'write',arguments_text:'{"content":"new"}',complete:true});
  handleEvent({type:'tool',call_id:'new-call',name:'write',arguments:{path:'fixture',content:'new'}});
  handleEvent({type:'tool_result',name:'write',result:{ok:true},failed:false});
  handleEvent({type:'retry',retry_id:'fixture',index:1,limit:10,cycle:1,state:'recovered',reason:'Provider response restored'});
  handleEvent({type:'reply',text:'NEW ANSWER'});handleEvent({type:'done'});
  check(!transcript.querySelector('[data-state="failed"]'),'recovered disconnect does not fail run');
  check(transcript.textContent.includes('OLD THINKING')&&transcript.textContent.includes('NEW ANSWER'),'interrupted evidence and new answer remain');
  check(!transcript.querySelector('.tool-line.pending'),'new tool settled');
  // Repaint only from durable transcript; a browser reload must retain the abandoned snapshot.
  busy=false;runBubble=null;
  repaintMessages([{id:'u',seq:1,role:'user',content:'Recovery history',created_at:Date.now()/1000},
    {id:'r',seq:2,role:'retry',content:JSON.stringify(interrupted),created_at:Date.now()/1000},
    {id:'a',seq:3,role:'assistant',content:'NEW ANSWER',ok:1,created_at:Date.now()/1000}],{active:false,notify:false});
  check(transcript.textContent.includes('OLD THINKING')&&transcript.textContent.includes('OLD COMMENTARY'),'reload reconstructs interrupted output');
  check(transcript.querySelector('.tool-outcome').textContent==='not executed','reload never promotes old preview');
  for(const topic of transcript.querySelectorAll('wa-run,wa-trace,wa-reasoning,wa-commentary,wa-retry'))topic.open=true;
  report.dataset.status='pass';report.textContent=JSON.stringify({ok:true,checks,skipped:0,scope:'live and durable replay recovery rendering'});
 }catch(e){report.dataset.status='fail';report.textContent=String(e.stack||e);}
})();
