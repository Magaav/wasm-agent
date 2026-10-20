(async()=>{
 const report=document.createElement('pre');report.id='wa-probe';report.hidden=true;document.body.append(report);
 let checks=0;const check=(ok,label)=>{if(!ok)throw Error(label);checks++;};const tick=()=>Promise.resolve();
 try{
  await window.rendererLoaded;for(let i=0;i<200&&!transcriptReady;i++)await new Promise(r=>setTimeout(r,10));
  check(transcriptReady,'startup transcript ready');for(let i=1;i<10000;i++){clearTimeout(i);clearInterval(i);}document.body.classList.add('expanded');pendingReload=false;
  const saved={apiFetch,nodeHealth,fetch:window.fetch,watchTurn,refreshMeta,notifyMetadataChange};
  const thread=chatSession,now=Date.now()/1000;
  const health={ok:true,run_ids:[{conversation:thread,run_id:700,run_key:'700',state:'running'}],node_threads:[{role:'runs',label:'child completion',session:thread,run_id:700,run_key:'700',age_ms:10,busy_ms:5000}],runs:[{conversation:thread,pending:1}]};
  const idle={ok:true,run_ids:[],node_threads:[],runs:[]};
  const rows=[{id:'old-user',seq:1,role:'user',content:'Previous task',created_at:now-20},{id:'old-answer',seq:2,role:'assistant',content:'The child is working.',created_at:now-15},{id:'background-request',seq:3,role:'user',content:'[Child completion notice] private fixture',created_at:now-5}];
  let scenario='known',expected='HUMAN CORRECTION',chatPosts=0,steeringPosts=0,healthReads=0,watchRequests=0,cancelPosts=0,eventReads=0;
  watchTurn=async()=>{watchRequests++;};refreshMeta=()=>{};notifyMetadataChange=()=>{};
  nodeHealth=async()=>{
   healthReads++;
   if(scenario==='scope-only'){rememberSession('private-other-view');return health;}
   if(scenario==='navigation'){detachConversationView();rememberSession('private-other-view');return health;}
   if(scenario==='account'){detachConversationView();session='private-other-account';return health;}
   return scenario==='raced'&&healthReads===1?idle:scenario==='idle'||scenario==='refused'||scenario==='json-error'?idle:health;
  };
  apiFetch=async(route,options)=>{
   if(route==='subagents'){
    const body=JSON.parse(options.body);if(scenario==='files')check(body.action==='steer_session'&&body.text.includes('[file: keep.txt]')&&body.text.includes('private fixture')&&body.text.includes(expected),'text attachment is inlined into the steering prompt');else check(body.action==='steer_session'&&body.session_id===thread&&body.text===expected&&body.idempotency_key,'owned correction uses stable scoped key');steeringPosts++;
    if(scenario==='lost')throw Error('private lost steering response');
    if(scenario==='newer'){input.value='NEWER DRAFT';draftGeneration++;}
    return {ok:true,status:200,json:async()=>({id:'steering-'+scenario,state:'queued',run_id:'background-run',ordinal:1})};
   }
   if(route==='runs'){
    const body=JSON.parse(options.body);check(body.action==='cancel'&&String(body.run_id)==='901'&&body.thread===thread,'Stop cancels queued request, never background owner');cancelPosts++;
    return {ok:true,status:200,json:async()=>({ok:true,cancel_requested:true,state:'queued',run_id:901,run_key:'901'})};
   }
   if(route==='sessions')return {ok:true,json:async()=>({sessions:[{id:thread,last_seq:3}]})};
   if(route.startsWith('session?'))return {ok:true,json:async()=>({session:{id:thread},messages:rows,state:{state:'unfinished'}})};
   if(route==='run-events'){
    eventReads++;const body=JSON.parse(options.body);check(body.thread===thread&&String(body.run_id)==='700','live replay follows authoritative background identity');
    return {ok:true,json:async()=>({checkpoint_seq:0,checkpoint_message_seq:3,overflow:false,next_seq:1,events:[{seq:1,event:{type:'delta',text:'VISIBLE BACKGROUND PROGRESS'}}]})};
   }
   return saved.apiFetch(route,options);
  };
  window.fetch=async(url,options)=>{
   if(String(url)!=='chat')return saved.fetch(url,options);
   chatPosts++;
   if(scenario==='raced'||scenario==='refused'||scenario==='idle')check(JSON.parse(options.body).if_idle===true,'UI requests atomic native start-if-idle');
   if(scenario==='refused')return {ok:false,status:503,json:async()=>({error:'admission_busy'})};
   if(scenario==='json-error')return {ok:true,status:200,headers:{get:()=> 'application/json'},body:{},json:async()=>({error:'private-json-error'})};
   if(scenario==='idle')return {ok:true,status:200,body:new ReadableStream({start(c){for(const e of [{type:'reply',text:'IDLE ACK',message_id:'idle-answer'},{type:'done'}])c.enqueue(new TextEncoder().encode('data: '+JSON.stringify(e)+'\n\n'));c.close();}})};
   return {ok:false,status:409,json:async()=>({error:'session_busy',effect:'none',not_started:true,thread})};
  };
  function reset(kind,text){scenario=kind;expected=text;chatPosts=0;steeringPosts=0;healthReads=0;watchRequests=0;cancelPosts=0;busy=false;controller=null;observedRun=null;activeRunId=null;submittedRunIds=null;steeringPending=false;steeringSubmission=null;runBubble=null;runStepState=null;runCounts=null;transcript=messages;messages.replaceChildren();clearStatus();chatShell.warning.clearNotices();attachments.splice(0);chatShell.renderAttachments();input.value=text;draftGeneration++;applyRunControls();}
  reset('known','HUMAN CORRECTION');await send(expected);
  check(chatPosts===0,'known background owner must receive steering, not a second chat admission');
  check(steeringPosts===1,'one correction reaches coordinator');check(!busy&&composerBusy()&&observedRun?.session===thread,'follower controls remain busy without owning a stream');check(sendButton.title==='Stop','running coordinator visible with usable Stop');check(input.value==='','confirmed correction clears only its draft');check(!!messages.querySelector('wa-steering'),'steering receipt visible');check(!messages.textContent.includes('Queued — waiting for the current turn'),'human does not enter hidden chat backlog');check(watchRequests>0,'handoff resumes existing follower loop');
  reset('raced','ARRIVED DURING ADMISSION');await send(expected);
  check(chatPosts===1&&steeringPosts===1,'race after idle sample uses one typed refusal then one steering effect, no chat retry');check(!busy&&composerBusy()&&input.value==='','race releases local socket ownership and acknowledges correction');check(!!messages.querySelector('wa-steering'),'known no-effect handoff is not erased by a false lost-stream restore');
  reset('raced','FIRST UNKNOWN THREAD');chatSession='';conversationEpoch++;await send(expected);
  check(chatPosts===1&&steeringPosts===1&&chatSession===thread,'first no-effect refusal learns only its authenticated owned thread');check(!busy&&composerBusy()&&input.value==='','first-thread rebasing releases local ownership and preserves steering acknowledgement');
  reset('scope-only','KEEP SCOPE-CHANGED DRAFT');await send(expected);check(chatPosts===0&&steeringPosts===0&&!busy&&controller===null&&input.value===expected,'scope change without explicit detach releases only the unadmitted controller');rememberSession(thread);
  reset('navigation','KEEP UNSENT VIEW DRAFT');await send(expected);check(chatPosts===0&&steeringPosts===0&&input.value===expected,'navigation before admission never dispatches into another view or clears draft');rememberSession(thread);
  const accountBefore=session;reset('account','KEEP PRIOR ACCOUNT DRAFT');await send(expected);check(chatPosts===0&&steeringPosts===0&&input.value===expected,'account change fences pending intent even without an epoch update');session=accountBefore;
  reset('keyboard','CTRL ENTER CORRECTION');input.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',ctrlKey:true,bubbles:true,cancelable:true}));for(let i=0;i<150&&(steeringPosts===0||steeringPending);i++)await tick();
  check(chatPosts===0&&steeringPosts===1,'Ctrl+Enter works when stale UI thought the background conversation idle');check(composerBusy()&&input.value==='','keyboard leaves follower active and clears confirmed text');
  reset('newer','ORIGINAL CORRECTION');await send(expected);check(input.value==='NEWER DRAFT','late acknowledgement cannot erase newer typing');check(steeringPosts===1,'newer draft does not trigger another effect');
  reset('lost','RECEIPT UNCERTAIN');await send(expected);check(steeringPosts===1&&input.value===expected,'uncertain steering retains draft and never auto-replays');check(!busy&&composerBusy(),'uncertainty never locks out background controls');
  reset('files','KEEP FILES');attachments.push({kind:'text',name:'keep.txt',text:'private fixture',state:'ready'});chatShell.renderAttachments();await send(expected);check(chatPosts===0&&steeringPosts===1,'text attachment rides into steering instead of being refused');check(attachments.length===0&&input.value==='','confirmed steering clears the files it carried');
  reset('refused','KEEP REJECTED MESSAGE');await send(expected);check(chatPosts===1&&input.value===expected,'HTTP admission refusal preserves draft');check(!chatShell.warning.hidden&&chatShell.warning.textContent.includes('admission_busy'),'non-SSE refusal stays visible instead of disappearing in an SSE reader');
  reset('json-error','KEEP JSON ERROR DRAFT');await send(expected);check(chatPosts===1&&input.value===expected,'JSON error with HTTP200 is not mistaken for accepted delivery');
  reset('idle','NORMAL IDLE MESSAGE');await send(expected);check(chatPosts===1&&steeringPosts===0&&input.value==='','genuinely idle send remains normal chat');check(messages.textContent.includes('IDLE ACK'),'idle answer renders normally');
  reset('cancel','DO NOT REPLAY CANCELLED QUEUE');let aborted=0;busy=true;activeRunId='901';submittedRunIds=new Set(['700']);controller={abort(){aborted++;}};applyRunControls();await cancelRun('901');
  check(cancelPosts===1&&aborted===1,'acknowledged queued cancellation detaches only its waiting socket');check(!busy&&composerBusy()&&runKey(observedRun)==='700','queued cancellation reattaches active background owner');check(steeringPosts===0,'cancelled queued text is not replayed as steering');
  const handoffApi=apiFetch;let learningRelease,learningReads=0;
  apiFetch=async(route,options)=>{if(route==='sessions'){learningReads++;return new Promise(resolve=>{learningRelease=()=>resolve({ok:true,json:async()=>({sessions:[{id:'private-stale-learn',user_id:me.user?.id}]})});});}return handoffApi(route,options);};
  await learnSession();check(learningReads===0&&chatSession===thread,'known conversation never follows newest-session discovery');
  chatSession='';conversationEpoch++;const oldLearning=learnSession();for(let i=0;i<20&&!learningRelease;i++)await tick();rememberSession('manual-learning-choice');learningRelease();await oldLearning;check(chatSession==='manual-learning-choice','late discovery cannot steal the explicitly selected conversation');rememberSession(thread);
  chatSession='';conversationEpoch++;learningRelease=null;const beforeIntent=learnSession();for(let i=0;i<20&&!learningRelease;i++)await tick();submissionEpoch++;learningRelease();await beforeIntent;check(chatSession==='','a discovery begun before a new send cannot rebind its in-flight intent');rememberSession(thread);apiFetch=handoffApi;
  reset('live','VISIBLE CORRECTION');await send(expected);followedSeq=3;lastFollowAt=Date.now();liveRunId=null;liveCheckpointSeq=null;liveEventSeq=0;liveRunPolling=null;runPolling=false;
  await saved.watchTurn();
  check(eventReads>0&&messages.textContent.includes('VISIBLE BACKGROUND PROGRESS'),'real follower consumes new background events without Ctrl+F5');check(composerBusy()&&sendButton.title==='Stop','live replay does not clear active controls');
  for(let i=1;i<10000;i++){clearTimeout(i);clearInterval(i);}document.getElementById('panel').style.width='540px';
  // This entire page is disposable. Keep its scoped fakes in place until capture;
  // restoring fixture globals would let late startup reads repaint an unrelated view.
  report.dataset.status='pass';report.textContent=JSON.stringify({checks,skipped:0});
 }catch(error){report.dataset.status='fail';report.textContent=String(error.stack||error);}
})();
