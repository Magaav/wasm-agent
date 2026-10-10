(async()=>{
 const report=document.createElement('pre');report.id='wa-probe';report.style.display='none';document.body.append(report);
 let checks=0;const check=(v,label)=>{if(!v)throw Error(label);checks++;};
 try{
  await window.rendererLoaded;for(let i=0;i<200&&!transcriptReady;i++)await new Promise(r=>setTimeout(r,10));
  check(transcriptReady,'startup ready');for(let t=1;t<10000;t++){clearTimeout(t);clearInterval(t);}
  let state={enabled:false,revision:0,thread:chatSession},calls=0;const old=orchestratorRequest;
  try{
   orchestratorRequest=async args=>{calls++;check(args.thread===chatSession&&args.action==='orchestration_mode','mode route scoped to conversation');
    if(args.mode_action==='toggle'){check(args.revision===state.revision,'toggle carries observed revision');state={...state,enabled:!state.enabled,revision:state.revision+1};}
    return {ok:true,orchestration:{...state}};};
   await readOrchestrationMode();input.value='/orchestration';syncCommands();
   check(commandMenu.textContent.includes('OFF'),'command balloon shows off');
   check(commandMatches('/ochestration')[0].name==='/orchestration','misspelled alias works');
   await toggleOrchestration();input.value='/orchestration';syncCommands();
   check(commandMenu.textContent.includes('ON')&&messages.textContent.includes('I remain available'),'on displayed only after acknowledged state');
   await toggleOrchestration();check(!orchestrationMode.enabled,'second toggle turns off without cancelling workers');
   const oldThread=chatSession;rememberSession('another-mode-thread');check(orchestrationMode===null,'mode not borrowed across conversations');rememberSession(oldThread);
   orchestratorRequest=async()=>{throw Error('offline');};await readOrchestrationMode();input.value='/orchestration';syncCommands();check(commandMenu.textContent.includes('unknown'),'unavailable mode not guessed off');
   check(!busy,'mode command never occupies inference stream');
   let release,readCalls=0;
   orchestratorRequest=()=>{readCalls++;return new Promise(resolve=>{release=resolve;});};
   const a=readOrchestrationMode(),b=readOrchestrationMode();
   check(readCalls===1,'same target mode reads are single-flight');
   release({ok:true,orchestration:{enabled:false,revision:0,thread:chatSession}});await Promise.all([a,b]);
   check(orchestrationRead===null,'mode single-flight settles without another polling loop');
   const pane=document.createElement('wa-agent-session');document.body.append(pane);
   pane.task={subagent_id:'mode-worker',profile:'orchestration-worker',state:'running',settled:false};pane.input.value='keep followup';
   let emits=0;pane.addEventListener('agent-action',()=>emits++);pane.sendDraft('message');pane.sendDraft('steer');
   check(emits===0&&pane.input.value==='keep followup'&&pane.notice.textContent.includes('wait'),'worker draft is preserved rather than interrupting active execution');pane.remove();
   // Leave the screenshot on the requested command balloon, not a transient unknown.
   orchestrationMode={enabled:false,revision:2,thread:chatSession};input.value='/orchestration';syncCommands();
  }finally{orchestratorRequest=old;}
  for(let t=1;t<10000;t++){clearTimeout(t);clearInterval(t);}
  report.dataset.status='pass';report.textContent=JSON.stringify({checks,skipped:0});
 }catch(e){report.dataset.status='fail';report.textContent=String(e.stack||e);}
})();
