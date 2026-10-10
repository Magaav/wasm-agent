(async()=>{
 const report=document.createElement('pre');report.id='wa-probe';report.hidden=true;document.body.append(report);
 let checks=0;const check=(ok,label)=>{if(!ok)throw Error(label);checks++;};
 try {
  await rendererLoaded;
  for(let i=0;i<100;i++)await Promise.resolve();
  check(!!orchestratorPanel,'actual orchestration view mounted');
  const startup=window.__calls || [];
  check(!startup.some(call=>/^(me|models|session)(\?|$)/.test(call.url) || call.url==='subagents'&&JSON.parse(call.body||'{}').action==='lookup_session'),'component view never starts invisible main-chat recovery/metadata');
  for(let i=1;i<10000;i++){clearTimeout(i);clearInterval(i);}
  while(orchestratorPolling)await Promise.resolve();
  const panel=orchestratorPanel;
  const task={subagent_id:'native-one',task_id:'task-one',attempt_id:'attempt-one',session_id:'child-one',node_id:'node-one',event_node_id:'node-one',event_epoch:'epoch-one',execution_node:'local',transport:'native',state:'running',settled:false,model:'fixture-model'};
  const rows=[{id:'one',seq:1,role:'user',content:'Keep exact originals.'},{id:'two',seq:2,role:'assistant',phase:'commentary',content:'Original reasoning evidence.'},{id:'three',seq:3,role:'assistant',content:'Stored answer.'}];
  let checkpoint=4,messageSeq=3,events=[{seq:5,event:{type:'delta',text:'live tail'}}],fail=false,foreign=false,occupied=0,maxReads=0,busyReplies=0,hold=null;
  const calls=[];const original=apiFetch;
  apiFetch=async(route,options={})=>{
   if(route==='version')return new Response(JSON.stringify({version}));
   const args=route==='subagents'?JSON.parse(options.body):{};
   const control=['cancel','message','steer','placement'].includes(args.action);
   calls.push({route,...args});
   if(control)return new Response(JSON.stringify({ok:true,state:'accepted'}));
   occupied++;maxReads=Math.max(maxReads,occupied);
   if(occupied>1){occupied--;busyReplies++;return new Response(JSON.stringify({error:'read_capacity_busy'}),{status:503});}
   try {
    if(hold)await hold.promise;else await Promise.resolve();
    if(fail)return new Response(JSON.stringify({error:'read_capacity_busy'}),{status:503});
    let value;
    if(route==='health')value={subagents:{running:1,active:1,queued:0}};
    else if(route==='sessions')value={sessions:[{id:task.session_id,workspace_branch:'change/one',worktree:'private'}]};
    else if(args.action==='fleet')value={nodes:[],policy:{}};
    else if(args.action==='list')value={subagents:[task]};
    else if(args.action==='events') {
     const tail=events.filter(item=>item.seq>Math.max(args.after,checkpoint)).slice(0,256),next=tail.at(-1)?.seq||Math.max(args.after,checkpoint);
     value={...task,...(foreign?{attempt_id:'foreign-attempt'}:{}),durable:true,checkpoint_seq:checkpoint,checkpoint_message_seq:messageSeq,events:tail,next_seq:next,has_more:next<(events.at(-1)?.seq||checkpoint)};
    }
    else if(args.action==='session'&&args.message_id){const row=rows.find(row=>row.id===args.message_id),content=JSON.stringify(row);value={encoding:'exact_message_json',message_id:row.id,message_version:'v-'+row.id,content,bytes:new TextEncoder().encode(content).length,next_offset:new TextEncoder().encode(content).length+1,eof:true};}
    else if(args.action==='session')value={session_id:task.session_id,messages:(args.before_seq?rows.slice(0,1):rows.slice(1)).map(row=>({id:row.id,seq:row.seq,role:row.role,omitted:true,evidence:{}})),has_more_before:!args.before_seq,next_before_seq:2};
    else throw Error('unexpected request '+route+' '+args.action);
    return new Response(JSON.stringify(value));
   }finally{occupied--;}
  };
  // Exercise production mount layout, poll, exact history recovery and promotion.
  panel.fleet=null;panel.restored=true;panel.data=[task];
  const pane=panel.pin(task);pane.input.value='unsent original draft';
  await Promise.all([refreshOrchestrator(),refreshAgentPane(pane),refreshAgentPane(pane)]);
  clearTimeout(orchestratorTimer);
  check(maxReads===1&&busyReplies===0,'one occupied external slot leaves zero self-inflicted refusals');
  check(calls.filter(call=>call.action==='session'&&!call.message_id&&!call.before_seq).length===1,'history first page read exactly once, not three times');
  check(calls.filter(call=>call.message_id).length===3,'all oversized original rows loaded, never dropped');
  check(pane.transcript.textContent.includes('Stored answer.')&&pane.transcript.textContent.includes('live tail'),'stored rows and live tail render together');
  const firstReads=calls.length;
  await refreshOrchestrator();clearTimeout(orchestratorTimer);
  const unchanged=calls.slice(firstReads);
  check(unchanged.filter(call=>call.action==='events').length===1&&unchanged.find(call=>call.action==='events').after===5,'unchanged poll follows validated cursor');
  check(!unchanged.some(call=>call.action==='session'||call.action==='fleet'),'unchanged poll rereads neither history nor placement');
  check(unchanged.length===4,'steady running pane: list, sessions, health and one journal read');
  events.push({seq:6,event:{type:'delta',text:' plus new output'}});
  await refreshAgentPane(pane);
  check(pane.transcript.textContent.includes('live tail plus new output'),'incremental tail retains old output and appends new event exactly once');
  const beforeCheckpoint=calls.filter(call=>call.action==='session'&&!call.message_id).length;
  checkpoint=7;messageSeq=4;rows.push({id:'four',seq:4,role:'assistant',content:'New durable checkpoint.'});events=[{seq:8,event:{type:'delta',text:'new tail'}}];
  await refreshAgentPane(pane);
  check(calls.filter(call=>call.action==='session'&&!call.message_id).length>beforeCheckpoint&&pane.transcript.textContent.includes('New durable checkpoint.'),'changed checkpoint reloads original ledger');
  const retained=pane.transcript.textContent;
  checkpoint=3;await refreshAgentPane(pane);
  check(pane.notice.textContent.includes('checkpoint_regressed')&&pane.transcript.textContent===retained,'regressed checkpoint refuses without clearing confirmed view');
  const backoffReads=calls.length;await refreshAgentPane(pane);
  check(calls.length===backoffReads,'pane failures back off rather than hammer reads');
  paneRetries.delete(pane);checkpoint=7;
  fail=true;await refreshAgentPane(pane);const refused=calls.length;await refreshAgentPane(pane);
  check(calls.length===refused&&pane.notice.textContent.includes('read_capacity_busy')&&pane.transcript.textContent===retained,'overload remains visible with backoff and retained output');
  fail=false;paneRetries.delete(pane);await refreshAgentPane(pane);
  check(!pane.notice.textContent.includes('read_capacity_busy'),'successful recovery clears overload warning');
  check(pane.input.value==='unsent original draft','all refreshes retain unsent draft');
  foreign=true;const beforeForeign=calls.length;await refreshAgentPane(pane);
  check(pane.notice.textContent.includes('identity_mismatch')&&calls.slice(beforeForeign).every(call=>call.action==='events'),'foreign journal identity refuses before any history fallback');
  foreign=false;paneRetries.delete(pane);
  events=events.concat(Array.from({length:260},(_,i)=>({seq:9+i,event:{type:'delta',text:i===0?'PAGED-START':i===259?'PAGED-END':'.'}})));
  const beforePages=calls.length;await refreshAgentPane(pane);
  check(calls.slice(beforePages).filter(call=>call.action==='events').map(call=>call.after).join(',')==='8,264','large tail requests only successive bounded pages');
  check(pane.transcript.textContent.includes('PAGED-START')&&pane.transcript.textContent.includes('PAGED-END'),'multi-page tail keeps all original events');
  // Promoted panes are separate render hosts, not concurrent read consumers.
  const promoted=panel.promote(pane);await Promise.all([refreshAgentPane(pane),refreshAgentPane(promoted)]);
  check(maxReads===1&&promoted.transcript.textContent.includes('PAGED-END'),'promotion keeps exact output with one in-flight read');
  // Cancellation must not wait for the read chain or acquire a read retry policy.
  let release;hold={promise:new Promise(resolve=>release=resolve)};
  const pending=orchestratorRequest({action:'events',...task,after:268});await Promise.resolve();await Promise.resolve();
  check(occupied===1,'controlled read is held');
  const control=await orchestratorRequest({action:'cancel',id:task.subagent_id});
  check(control.ok&&occupied===1,'explicit control bypasses read queue');release();hold=null;await pending;
  task.state='completed';task.settled=true;await refreshAgentPane(pane);
  const settledReads=calls.length;await refreshAgentPane(pane);
  check(calls.length===settledReads,'settled unchanged pane stops transcript/journal reads between freshness samples');
  paneJournals.get(pane).at=Date.now()-31000;await refreshAgentPane(pane);
  check(calls.length===settledReads+1,'settled journal receives bounded thirty-second freshness sample');
  // Failure/backoff and journal cursor belong to an exact attempt, not a DOM pane.
  paneReadFailed(pane,Error('old attempt overload'));task.attempt_id='next-attempt';task.state='running';task.settled=false;pane.task={...task};
  const beforeAttempt=calls.length;await refreshAgentPane(pane);
  check(calls.slice(beforeAttempt).find(call=>call.action==='events').after===0&&!pane.notice.textContent.includes('old attempt'),'new attempt resets stale cursor and old failure backoff');
  check(orchestratorDelay()===2000,'visible active poll remains two seconds');panel.data=[];
  check(orchestratorDelay()===10000,'idle poll slows to ten seconds');orchestratorFailures=4;
  check(orchestratorDelay()===30000,'failed workspace poll has bounded backoff');orchestratorFailures=0;
  apiFetch=original;
  for(let i=1;i<10000;i++){clearTimeout(i);clearInterval(i);}
  report.dataset.status='pass';report.textContent=JSON.stringify({checks,skipped:0,steady_reads:unchanged.length,peak_reads:maxReads,self_inflicted_refusals:busyReplies});
 }catch(error){report.dataset.status='fail';report.textContent=String(error.stack||error);}
})();
