(async () => {
  const problems = [];
  const check = (ok, label) => { if (!ok) problems.push(label); };
  await window.rendererLoaded;
  if (window.__productionFinalEvents) {
    for (const scenario of window.__productionFinalEvents) {
      messages.replaceChildren();runBubble=null;streamBody=null;streamText='';
      for (const event of scenario.events) handleEvent(event);
      if (['tool','steer','followup'].includes(scenario.scenario)) check(messages.textContent.includes('Settled '+scenario.scenario),'production continuation rendered '+scenario.scenario);
      if (['cancel','failure'].includes(scenario.scenario)) check(messages.textContent.includes('Candidate '+scenario.scenario),'production interrupted text retained');
    }
  }
  const originalFetch=window.fetch;
  const lookups=[];
  let lookupReply={found:false};
  window.fetch=async (url,init)=>{lookups.push({url:String(url),init});return {ok:!lookupReply.error,json:async()=>lookupReply};};
  check(await nativeSessionTask('normal-chat')===null, 'normal chat targeted null');
  const task={transport:'native',session_id:'child',subagent_id:'dispatch-alias',task_id:'native-task',
    attempt_id:'latest',node_id:'worker',event_node_id:'worker',event_epoch:'epoch'};
  lookupReply={found:true,task};
  check(await nativeSessionTask('child')===task, 'latest native summary preserved');
  lookupReply={error:'forbidden'};
  let refused=false;try {await nativeSessionTask('child');}catch(e){refused=e.message==='forbidden';}
  check(refused, 'auth error visible');
  for (const malformed of [{}, {found:true}, {found:false,task}, {found:'false'},
    {found:true,task:{...task,session_id:'other'}}, {found:true,task:{...task,event_epoch:''}}]) {
    lookupReply=malformed;
    let rejected=false;try {await nativeSessionTask('child');}catch {rejected=true;}
    check(rejected, 'malformed/identity contract refused: '+JSON.stringify(malformed));
  }
  lookupReply={error:'native_session_unavailable'};
  refused=false;try {await nativeSessionTask('child');}catch(e){refused=e.message==='native_session_unavailable';}
  check(refused, 'native error visible');
  check(lookups.length===10 && lookups.every(call=>call.init.method==='POST' &&
    call.init.headers['Content-Type']==='application/json' && JSON.parse(call.init.body).action==='lookup_session'), 'no full-list fallback; JSON content type');
  window.fetch=originalFetch;
  document.body.classList.add('expanded');
  messages.replaceChildren(); runBubble=null; streamBody=null; streamText='';
  handleEvent({type:'round', n:1});
  handleEvent({type:'commentary', text:'Checking evidence'});
  handleEvent({type:'tool', name:'read', arguments:{path:'fixture'}});
  handleEvent({type:'tool_result', name:'read', result:'evidence'});
  handleEvent({type:'final_answer_begin', message_id:'msg-explicit', source:'responses.output_item.added'});
  check(!!streamBody && streamText === '', 'explicit start before text');
  check(runBubble.body.querySelector('wa-run')?.open === false, 'activity collapsed early');
  const answer = streamBody;
  handleEvent({type:'final_answer_begin', message_id:'msg-explicit'});
  check(streamBody===answer && runBubble.body.querySelectorAll('.final-answer').length===1, 'duplicate begin idempotent');
  handleEvent({type:'delta', text:'# Answer\n\n**Verified** fixture, not task correctness.'});
  check(!!answer.querySelector('h1') && !!answer.querySelector('strong'), 'streaming Markdown');
  check(!answer.closest('wa-run'), 'answer outside activity topic');
  check(answerAnchors.get(messages)===answer, 'start anchor active');
  messages.dispatchEvent(new WheelEvent('wheel', {deltaY:1}));
  check(!answerAnchors.has(messages), 'wheel releases anchor');
  handleEvent({type:'tool', name:'read', arguments:{path:'continuation'}});
  check(!answer.classList.contains('final-answer') && answer.isConnected, 'text then tool preserves candidate as activity');
  handleEvent({type:'round', n:2});
  handleEvent({type:'pending_delta', pending_id:'unknown', text:'provisional'});
  check(!streamBody && !!messages.querySelector('.phase-pending'), 'unknown stays provisional');
  handleEvent({type:'commentary', pending_id:'unknown', text:'provisional'});
  check(!messages.querySelector('.phase-pending'), 'commentary resolves provisional');
  handleEvent({type:'reply', message_id:'9007199254740999', text:'# Final\n\nThe retained answer.'});
  check(messages.textContent.includes('The retained answer.'), 'late harness answer retained');
  // Different final candidates must not share buffers; duplicates across sources stay idempotent.
  handleEvent({type:'done'});
  setFollow(true); // a newly submitted turn follows; old scrollback remains opt-out
  handleEvent({type:'final_answer_begin',run_id:'r2',response_id:'p2',message_id:'same'});
  handleEvent({type:'delta',text:'First candidate'});
  const first=streamBody;
  handleEvent({type:'final_answer_begin',run_id:'r2',response_id:'p2',message_id:'other'});
  handleEvent({type:'delta',text:'Second candidate'});
  check(streamBody!==first && first.textContent==='First candidate' && streamBody.textContent==='Second candidate','multiple candidate isolation');
  const second=streamBody;
  handleEvent({type:'final_answer_begin',run_id:'r2',response_id:'p2',message_id:'same',source:'done'});
  check(streamBody===second,'old duplicate does not replace newest candidate');
  messages.dispatchEvent(new KeyboardEvent('keydown',{key:'a'}));
  check(answerAnchors.has(messages),'non-scroll key retains anchor');
  messages.dispatchEvent(new KeyboardEvent('keydown',{key:'PageUp'}));
  handleEvent({type:'reply',text:'Second candidate'});
  check(!answerAnchors.has(messages),'reply cannot resurrect reader-released anchor');
  for (const terminal of ['error','done']) {
    handleEvent({type:'done'});
    handleEvent({type:'final_answer_begin',message_id:'terminal-'+terminal});
    handleEvent({type:'delta',text:'Retained '+terminal});
    handleEvent({type:terminal,error:'cancelled'});
    check(!answerAnchors.has(messages) && messages.textContent.includes('Retained '+terminal),'terminal invalidation preserves '+terminal);
  }
  // Real asynchronous chunks: short output rises, then overflow grows below
  // the first line, even when the provider cannot classify it until text_end.
  const samples=[];
  function readingFixture() {
    handleEvent({type:'done'});clearStatus();
    messages.replaceChildren();runBubble=null;streamBody=null;streamText='';
    setFollow(true);
    for(let i=0;i<12;i++)add('user','Earlier evidence '+('retained text '.repeat(35)));
  }
  for(const mode of ['explicit','pending','delta']) {
    readingFixture();
    if(mode==='explicit')handleEvent({type:'final_answer_begin',message_id:'grow-'+mode});
    const rows=[];
    for(let i=0;i<24;i++) {
      handleEvent({type:mode==='pending'?'pending_delta':'delta',pending_id:'grow-'+mode,
        text:(i===0?'Read this answer from the beginning.\n\n':'')+'Paragraph '+i+' '+('readable evidence '.repeat(8))+'\n\n'});
      await new Promise(resolve=>setTimeout(resolve,25));
      const node=mode==='pending'?phasePendingText.get('grow-'+mode).node:streamBody;
      rows.push({top:node.getBoundingClientRect().top-messages.getBoundingClientRect().top,
        height:node.getBoundingClientRect().height,view:messages.clientHeight,
        scroll:messages.scrollTop,anchored:answerAnchors.get(messages)===node});
    }
    samples.push({mode,rows});
    check(rows.every(row=>row.anchored),'chunk/frame retains '+mode+' reading anchor');
    check(rows[0].top>30 && rows[2].top<rows[0].top-20,'short '+mode+' answer grows upward');
    const long=rows.filter(row=>row.height>row.view+50);
    check(long.length>3 && long.every(row=>Math.abs(row.top)<3),'overflow '+mode+' keeps first line at viewport top');
    check(long.length>3 && long.every(row=>Math.abs(row.scroll-long[0].scroll)<2),'overflow '+mode+' grows scroll range instead of chasing bottom');
    check(mode!=='pending'||!messages.querySelector('wa-run'),'unclassified streaming never claims final phase or collapses activity');
    if(mode==='pending') {
      const text=phasePendingText.get('grow-'+mode).text;
      handleEvent({type:'final_answer_begin',message_id:'grow-'+mode,pending_id:'grow-'+mode});
      handleEvent({type:'delta',pending_id:'grow-'+mode,text});
      check(!messages.querySelector('.phase-pending') && streamBody.textContent.includes('Paragraph 23'),'late final phase replaces provisional text without loss');
    }
    handleEvent({type:'reply',text:streamText});
    check(Math.abs(answerAnchors.get(messages)?.getBoundingClientRect().top-messages.getBoundingClientRect().top)<3,'reply retains '+mode+' beginning');
    if(mode==='delta') {
      jump.click();
      handleEvent({type:'delta',text:'\n\n'+('Following latest output.\n\n'.repeat(20))});
      check(atBottom()&&!answerAnchors.has(messages),'jump-to-latest explicitly resumes tail following');
    }
  }
  // Starting a response must not steal a reader already reviewing older messages.
  readingFixture();messages.scrollTop=0;setFollow(false);
  handleEvent({type:'final_answer_begin',message_id:'scrollback'});
  handleEvent({type:'delta',text:'New answer '+('evidence '.repeat(200))});
  check(messages.scrollTop===0&&!answerAnchors.has(messages),'final begin respects existing scrollback');
  readingFixture();
  // Real layout: grow well past viewport, keep the start rather than chasing the bottom.
  handleEvent({type:'final_answer_begin',message_id:'layout'});
  const layout=streamBody;
  handleEvent({type:'delta',text:'# Layout start\n\n'+('paragraph of evidence\n\n'.repeat(100))});
  pin();
  check(Math.abs(layout.getBoundingClientRect().top-messages.getBoundingClientRect().top)<3,'pixel answer start anchored during large growth');
  messages.scrollTop=Math.max(0,messages.scrollTop-30);
  messages.dispatchEvent(new Event('scroll'));
  const manual=messages.scrollTop;
  handleEvent({type:'delta',text:'\n\n```js\nconst fixture = true;\n```\n\n| a | b |\n|---|---|\n|1|2|'});
  check(messages.scrollTop===manual && !answerAnchors.has(messages),'manual scroll remains released during code/table growth');
  // Use actual shared child chat hosts, not substitute transcript DOM.
  const childA=document.createElement('wa-agent-session');
  const childB=document.createElement('wa-agent-session');
  document.body.append(childA,childB);
  const savedTranscript=transcript;
  const mainPosition=messages.scrollTop;
  const otherPosition=childB.transcript.scrollTop;
  transcript=childA.transcript;runBubble=null;streamBody=null;streamText='';
  handleEvent({type:'final_answer_begin',message_id:'child-a'});
  handleEvent({type:'delta',text:'# Child answer\n\n'+('child evidence\n\n'.repeat(100))});
  pin();
  check(answerAnchors.has(childA.transcript),'child has independent anchor');
  check(messages.scrollTop===mainPosition && childB.transcript.scrollTop===otherPosition,'child growth does not move main or sibling');
  childA.transcript.dispatchEvent(new WheelEvent('wheel',{deltaY:1}));
  check(!answerAnchors.has(childA.transcript),'child wheel releases only child');
  childA.transcript.scrollTop=0;
  const childPosition=childA.transcript.scrollTop;
  handleEvent({type:'delta',text:'more\n\n'.repeat(50)});
  handleEvent({type:'reply',text:streamText});
  await new Promise(resolve=>setTimeout(resolve,50));
  check(childA.transcript.scrollTop===childPosition,'reviewer regression child stays at zero after delta/reply/frame');
  check(messages.scrollTop===mainPosition && childB.transcript.scrollTop===otherPosition,'child release leaves main/sibling position unchanged');
  transcript=savedTranscript;runBubble=null;streamBody=null;streamText='';
  // Race a manual gesture against the pending real pin frame; test after real browser timer turn.
  handleEvent({type:'final_answer_begin',message_id:'race'});
  handleEvent({type:'delta',text:'# Race\n\n'+('race evidence\n\n'.repeat(100))});
  pin();
  messages.dispatchEvent(new WheelEvent('wheel',{deltaY:-1}));
  messages.scrollTop=Math.max(0,messages.scrollTop-40);
  messages.dispatchEvent(new Event('scroll'));
  const racePosition=messages.scrollTop;
  await new Promise(resolve=>setTimeout(resolve,50));
  handleEvent({type:'delta',text:'more evidence'});
  handleEvent({type:'reply',text:streamText+' race retained'});
  check(!answerAnchors.has(messages) && messages.scrollTop===racePosition,'pending pin frame cannot overwrite manual intent');
  messages.scrollTop=messages.scrollHeight;
  messages.dispatchEvent(new Event('scroll'));
  check(follow && !answerAnchors.has(messages),'async return bottom resumes main follow without rearming anchor');
  handleEvent({type:'delta',text:'\n\n'+('resumed growth\n\n'.repeat(20))});
  check(atBottom(),'return-bottom follows subsequent growth');
  childA.remove();childB.remove();
  // Leave the screenshot on the requested reading position, not a tail-follow fixture.
  readingFixture();
  document.getElementById('panel').style.width='540px';
  handleEvent({type:'final_answer_begin',message_id:'visual-reading'});
  handleEvent({type:'delta',text:'# Read from the beginning\n\nThe first lines stay here while the rest of the answer arrives below.\n\n'+('Additional output grows below the viewport; scroll down when you are ready.\n\n'.repeat(30))});
  pin();
  check(Math.abs(streamBody.getBoundingClientRect().top-messages.getBoundingClientRect().top)<3,'narrow-window answer starts at top');
  const log=document.createElement('pre'); log.id='wa-probe';log.hidden=true;
  log.dataset.status=problems.length?'fail':'pass';
  log.textContent=problems.length?problems.join(' ;; '):'final-answer UI causal checks pass';
  log.dataset.growth=JSON.stringify(samples);
  document.body.append(log);
})();
