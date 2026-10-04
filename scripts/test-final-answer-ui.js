(async () => {
  const problems = [];
  const check = (ok, label) => { if (!ok) problems.push(label); };
  await window.rendererLoaded;
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
  const log=document.createElement('pre'); log.id='wa-probe';
  log.dataset.status=problems.length?'fail':'pass';
  log.textContent=problems.length?problems.join(' ;; '):'final-answer UI causal checks pass';
  document.body.append(log);
})();
