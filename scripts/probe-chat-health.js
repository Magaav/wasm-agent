(async()=>{
 const errors=[],evidence=[];let checks=0;
 function check(value,label){checks++;if(!value)errors.push(label);}
 const tick=()=>Promise.resolve();
 await window.rendererLoaded;
 for(let i=0;i<200&&!transcriptReady;i++)await new Promise(r=>setTimeout(r,10));
 document.body.classList.add('expanded');
 // Stop disposable fixture timers only; production creates no extra liveness interval.
 for(let id=1;id<10000;id++){clearTimeout(id);clearInterval(id);}
 clearStatus();transcript=messages;messages.replaceChildren();runBubble=null;runStepState=null;
 busy=true;observedRun=null;activeRunId='9901';submittedRunIds=null;setFollow(false);startLiveness();
 for(let i=0;i<15;i++)add('user','Retained history '+('readable evidence '.repeat(40)));
 messages.scrollTop=100;
 const warning=chatShell.warning,position=messages.scrollTop,viewTop=messages.getBoundingClientRect().top;
 const nativeFetch=window.fetch,clock=Date.now;let now=clock();Date.now=()=>now;
 const health=age=>({ok:true,worker:'stalled',stalled_ms:999999,queue:0,
  node_threads:[{role:'runs',label:'POST /chat',session:chatSession,run_id:9901,age_ms:age,state:'busy'},
    {role:'reads',session:'another',run_id:111,age_ms:999999,state:'stalled'}],
  run_ids:[{conversation:chatSession,run_id:9901,state:'running'}],operations:[]});
 try {
  observeRunHealth(health(97));check(warning.hidden&&!document.getElementById('liveness'),'healthy exact-run heartbeat stays quiet despite aggregate/read-thread stall');
  const mutation=new MutationObserver(()=>{});mutation.observe(warning,{attributes:true,childList:true,characterData:true,subtree:true});
  for(let i=0;i<5;i++)observeRunHealth(health(97));
  check(mutation.takeRecords().length===0,'unchanged healthy observations do not repaint warning');mutation.disconnect();
  now+=1000;observeRunHealth(health(50000));check(warning.hidden,'one old sample is not a sustained stall');
  now+=5000;observeRunHealth(health(55000));check(!warning.hidden&&warning.textContent.includes('55s'),'sustained exact-run beat stagnation shows seconds-based worker warning');
  check(!messages.contains(warning)&&!warning.closest('wa-message'),'warning never enters transcript/turn balloon');
  check(Math.abs(messages.scrollTop-position)<1&&Math.abs(messages.getBoundingClientRect().top-viewTop)<1,'warning does not change scroll or viewport geometry');
  const before=warning.getBoundingClientRect().top;messages.scrollTop+=80;
  check(Math.abs(warning.getBoundingClientRect().top-before)<1,'warning remains pinned while chat scrolls');
  observeRunHealth(health(30));check(warning.hidden,'fresh exact-run beat clears worker warning');
  setLiveness({kind:'worker',working:false,seconds:12});
  observeRunHealth({...health(30),node_threads:[]});check(warning.hidden,'missing exact worker evidence never sustains a foreign/aggregate alarm');
  startLiveness();observeRunHealth({...health(30),node_threads:[{role:'runs',session:'foreign',run_id:22,age_ms:100000}]});
  now+=10000;observeRunHealth({...health(30),node_threads:[{role:'runs',session:'foreign',run_id:22,age_ms:110000}]});
  check(warning.hidden,'foreign run cannot create a worker alarm');
  startLiveness();observeRunHealth(null);check(warning.hidden,'one failed observation stays quiet');
  now+=6000;observeRunHealth(null);check(!warning.hidden&&warning.textContent.includes('Connection uncertain'),'repeated failed health with quiet stream warns');
  markRunStreamAlive();check(warning.hidden,'arriving own-stream event clears transport uncertainty');
  now+=1000;observeRunHealth(null);check(warning.hidden,'fresh stream avoids false transport warning despite health read failure');
  observeRunHealth(health(20));check(warning.hidden,'authoritative health recovery clears uncertainty');
  startLiveness();observeRunHealth(null);now+=6000;observeRunHealth(null);
  activeRunId='9902';observeRunHealth(null);check(warning.hidden,'new run never inherits prior alarm');
  activeRunId='9901';startLiveness();observeRunHealth(null);now+=6000;observeRunHealth(null);
  handleEvent({type:'done'});check(warning.hidden,'terminal event clears alarm');
  runStepState=null;busy=true;startLiveness();
  observeRunHealth(null);now+=6000;observeRunHealth(null);
  const previousSession=chatSession;rememberSession('chat-health-switched');check(warning.hidden,'conversation switch clears warning and evidence');
  rememberSession(previousSession);busy=true;activeRunId='9901';runStepState=null;
  // One request shared by concurrent callers; bounded reuse only when explicitly requested.
  let reads=0,deliver;healthFlight=null;healthSample=null;
  window.fetch=(url,init)=>{if(String(url)==='health'){reads++;return new Promise(r=>deliver=()=>r({ok:true,json:async()=>health(10)}));}return nativeFetch(url,init);};
  const a=nodeHealth(),b=nodeHealth();check(a===b&&reads===1,'concurrent health consumers share one fetch');deliver();await a;await b;
  await nodeHealth(1000);check(reads===1,'explicit one-second sample reuse avoids duplicate fetch');
  now+=1001;const c=nodeHealth(1000);check(reads===2,'expired observation requires a new authoritative read');deliver();await c;
  // Health polling is slower during fresh streamed output but remains fast for quiet execution.
  trace=null;markRunStreamAlive();check(turnHealthDelay()===5000,'fresh own stream uses five-second health fallback');
  now+=6000;check(turnHealthDelay()===1000,'quiet active run retains bounded one-second observation');
  markRunStreamAlive();trace={pending:true};check(turnHealthDelay()===1000,'pending operations keep immediate progress observation');trace=null;
  const hidden=Object.getOwnPropertyDescriptor(document,'hidden');Object.defineProperty(document,'hidden',{configurable:true,value:true});
  check(turnHealthDelay()===15000,'hidden surface avoids frequent health reads');
  if(hidden)Object.defineProperty(document,'hidden',hidden);else delete document.hidden;
  healthFlight=null;healthSample={scope:activeNode+':'+session+':'+chatSession+':'+conversationEpoch,at:now,value:health(10)};
  window.fetch=(url,init)=>String(url)==='health'?Promise.reject(Error('private read failure')):nativeFetch(url,init);
  check(await nodeHealth()===null&&healthSample===null,'failed fresh read invalidates old reusable observation');
  const value=nodeHealth(1000);check(await value===null,'failed observation never silently reuses earlier healthy state');
  window.fetch=(url,init)=>{if(String(url)==='health'){reads++;return new Promise(r=>deliver=()=>r({ok:true,json:async()=>health(10)}));}return nativeFetch(url,init);};
  const countBefore=reads;healthFlight=null;healthSample=null;
  const old=nodeHealth();const oldDeliver=deliver;
  const savedEpoch=conversationEpoch;conversationEpoch++;const next=nodeHealth();const newDeliver=deliver;
  check(reads===countBefore+2,'epoch switch never shares old in-flight health');oldDeliver();await old;
  check(!healthSample||healthSample.scope!==activeNode+':'+session+':'+chatSession+':'+conversationEpoch,'old health cannot populate new scope');
  newDeliver();await next;conversationEpoch=savedEpoch;
  evidence.push({shared_reads:1,concurrent_consumers:2,healthy_warning_hidden:true});
 } finally {window.fetch=nativeFetch;Date.now=clock;healthFlight=null;healthSample=null;stopLiveness();}
 // Screenshot one controlled warning over original readable history.
 busy=true;runStepState=null;setLiveness({kind:'connection',working:false,seconds:8});
 document.getElementById('panel').style.width='540px';
 const log=document.createElement('pre');log.id='wa-probe';log.hidden=true;
 log.dataset.status=errors.length?'fail':'pass';log.textContent=errors.length?errors.join(' ;; '):JSON.stringify({checks,skipped:0,evidence});document.body.append(log);
})();
