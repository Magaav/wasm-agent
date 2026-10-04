(async function () {
  const report = document.createElement('pre');
  report.id = 'wa-probe';
  report.style.display = 'none';
  document.body.append(report);
  let checks = 0;
  const evidence = [];
  function check(condition, label) {
    if (!condition) throw Error(label);
    checks++;
  }
  try {
    await window.rendererLoaded;
    for (let i = 0; i < 100; i++) await Promise.resolve();
    busy = false;
    activeRunId = null;
    liveRunId = null;
    observedRun = { session: chatSession, run_id: 901, ms: 65000 };
    const row = {id:'coordinator-notice',seq:100,role:'user',content:'Worker finished. Review its results.',created_at:(Date.now()-65000)/1000};
    repaintMessages([row], {active:true,notify:false});
    const bubble = currentBubble();
    check(transcript.querySelectorAll('wa-message.assistant').length === 1, 'background admission immediately creates one balloon');
    check(bubble.querySelector('wa-step[data-state="running"]'), 'a background turn has an immediate visible phase');
    check(bubble.body.querySelector(':scope > .chat-content-run-status'), 'live status is inside the balloon');
    check(statusElapsed.textContent === '1:05', 'background elapsed time uses the saved start time');
    check(!!runStatusTicker, 'background turns start the elapsed ticker');
    handleEvent({type:'status',text:'thinking'});
    handleEvent({type:'round',n:1});
    handleEvent({type:'status',text:'model'});
    check(bubble.textContent.includes('Preparing turn') && bubble.textContent.includes('Waiting for model response'), 'preparation and model wait are separate visible steps');
    const waiting = runStepState.active;
    const count = runStepState.steps.length;
    handleEvent({type:'status',text:'model'});
    check(runStepState.steps.length === count, 'duplicate phase updates do not duplicate steps');
    const clock = Date.now;
    try { Date.now = () => clock() + 2000; updateRunElapsed(); }
    finally { Date.now = clock; }
    check(waiting.node.querySelector('.run-step-age').textContent === '2s', 'the current phase has its own measured elapsed time');
    handleEvent({type:'decision',call_id:'inspect-one',name:'read_many',arguments_text:'worker-result.json',complete:true});
    handleEvent({type:'tool',call_id:'inspect-one',name:'read_many',arguments:{requests:[{path:'worker-result.json'}]}});
    check(bubble.textContent.includes('Selecting tools') && bubble.textContent.includes('Executing tools'), 'tool selection and execution are shown as phases');
    check(bubble.querySelectorAll('.tool-line[data-call-id="inspect-one"]').length === 1, 'the actual inspection tool is shown once');
    handleEvent({type:'tool_result',name:'read_many',result:{ok:true,results:[]}});
    handleEvent({type:'round',n:2});
    handleEvent({type:'status',text:'model'});
    const savedNode = runStepState.active.node;
    const rows = [row,
      {id:'inspection-call',seq:101,role:'assistant',content:'',tool_calls:[{id:'inspect-one',function:{name:'read_many',arguments:'{}'}}],created_at:Date.now()/1000},
      {id:'inspection-result',seq:102,role:'tool',tool_call_id:'inspect-one',tool_name:'read_many',content:'Worker result inspected.',created_at:Date.now()/1000}];
    repaintMessages(rows, {active:true,notify:false});
    check(runStepState.active.node === savedNode && savedNode.isConnected, 'a checkpoint repaint keeps the same running phase and its clock');
    check(transcript.querySelectorAll('wa-message.assistant').length === 1, 'a repaint keeps one balloon for the turn');
    check(transcript.querySelectorAll('.tool-line[data-call-id="inspect-one"]').length === 1, 'checkpoint repaint does not duplicate tools');
    const order = Array.from(currentBubble().querySelectorAll('wa-step,wa-trace'));
    check(order.findIndex(e=>e.textContent.includes('Preparing turn')) < order.findIndex(e=>e.tagName==='WA-TRACE'), 'earlier phases stay before their inspection trace');
    check(order[order.length-1] === savedNode, 'the second model wait stays after the inspection');
    const originalPage = sessionEventPage;
    const originalFollowed = followedSeq;
    try {
      followedSeq = 102;
      sessionEventPage = async () => ({ok:true,status:200,json:async()=>({checkpoint_seq:8,checkpoint_message_seq:102,events:[],overflow:false})});
      await syncLiveRun(observedRun);
    } finally { sessionEventPage = originalPage; followedSeq = originalFollowed; }
    check(savedNode.isConnected && statusLine.closest('wa-message.assistant'), 'an empty event tail after a checkpoint does not erase the live step');
    const mainState = runStepState;
    const child = document.createElement('div');
    document.body.append(child);
    paintChildTranscript(child, [{seq:1,role:'user',content:'Child task'}], {active:true,notify:false});
    check(runStepState === mainState && savedNode.isConnected, 'child transcript rendering leaves coordinator progress intact');
    child.remove();
    handleEvent({type:'pending_delta',pending_id:'answer',text:'The review'});
    check(currentBubble().textContent.includes('Receiving model output'), 'provisional output has a visible step');
    handleEvent({type:'delta',pending_id:'answer',text:'The review passed.'});
    check(currentBubble().textContent.includes('Writing response'), 'answer streaming has a visible step');
    handleEvent({type:'reply',text:'The review passed.',message_id:'review-answer'});
    const finished = currentBubble();
    handleEvent({type:'done'});
    check(!finished.querySelector('wa-step[data-state="running"]'), 'settlement stops every phase spinner');
    check(!runStatusTicker, 'settlement clears the elapsed ticker');
    check(finished.body.lastElementChild.classList.contains('finished'), 'the final duration remains the balloon footer');
    evidence.push({case:'background coordinator',steps:Array.from(finished.querySelectorAll('wa-step')).map(e=>e.textContent),tools:finished.querySelectorAll('.tool-line').length});
    observedRun = {session:chatSession,run_id:902,ms:1000};
    repaintMessages([{...row,id:'next-notice',seq:200,content:'Next turn',created_at:(Date.now()-1000)/1000}], {active:true,notify:false});
    check(!currentBubble().textContent.includes('Executing tools'), 'a new turn does not inherit the prior turn phases');
    const oldScope = runStepState.scope;
    chatSession = 'different-chat';
    conversationEpoch++;
    observedRun = {session:chatSession,run_id:903,ms:1000};
    repaintMessages([{...row,id:'different-notice',seq:300,content:'Different chat',created_at:Date.now()/1000}], {active:true,notify:false});
    check(runStepState.scope !== oldScope, 'progress is fenced to the current chat and epoch');
    evidence.push({case:'new conversation',steps:Array.from(currentBubble().querySelectorAll('wa-step')).map(e=>e.textContent)});
    const oldActive = runStepState.active.node;
    observedRun = {session:chatSession,run_id:904,ms:1000};
    const history = [{...row,id:'different-notice',seq:300,content:'Different chat'},
      {seq:301,role:'assistant',phase:'final_answer',content:'Previous turn finished.',created_at:Date.now()/1000},
      {...row,id:'following-notice',seq:400,content:'Following turn',created_at:Date.now()/1000}];
    repaintMessages(history, {active:true,notify:false});
    check(oldActive.dataset.state === 'completed', 'a new run settles the previous cached phase from that turn durable answer');
    check(transcript.querySelectorAll('wa-step[data-state="running"]').length === 1, 'full-history repaint never leaves an orphaned phase spinner');
    check(runStepState.id === '904', 'the new run owns the active phase after a full-history repaint');
    handleEvent({type:'status',text:'model'});
    const interrupted = runStepState.active.node;
    observedRun = null;
    repaintMessages([{...row,id:'following-notice',seq:400,content:'Following turn'},
      {seq:401,role:'assistant',content:'Still evaluating',created_at:Date.now()/1000}],
      {active:false,state:'unfinished',notify:false});
    check(interrupted.dataset.state === 'unfinished' && !interrupted.querySelector('.spinner'), 'a missed terminal event cannot leave a historical phase running');
    check(interrupted.querySelector('.run-step-age').textContent === 'duration unknown', 'missing settlement timing is reported as unknown');
    const stopped = Array.from(transcript.querySelectorAll('wa-message.assistant')).at(-1);
    check(stopped.body.lastElementChild.classList.contains('finished'), 'a no-tool repaint keeps the duration footer last');
    check(Array.from(stopped.body.children).indexOf(interrupted) < Array.from(stopped.body.children).findIndex(e=>e.classList.contains('seg')), 'restored no-tool phases precede the answer');
    busy = true;
    activeRunId = null;
    observedRun = {session:chatSession,run_id:904};
    runStepState = null;
    showRunStep('submitting','Sending message');
    check(runStepState.id === null, 'a new submitted turn never adopts the older observed run identity');
    activeRunId = '905';
    showRunStep('preparing','Preparing turn');
    check(runStepState.id === '905' && runStepState.steps.length === 2, 'submission phases stay with the newly identified turn');
    setLiveness({working:true,run_state:'queued',current_run_id:'904',stalled:10,queue:1});
    check(runStepState.active.key === 'queued', 'exact submitted-run queue state has a visible phase');
    check(document.getElementById('liveness').closest('wa-message.assistant') === currentBubble(), 'queue and heartbeat information live inside the turn balloon');
    setLiveness({working:true,run_state:'running',busy_ms:1000,stalled:10,queue:0});
    check(runStepState.active.label === 'Starting turn', 'queue-to-running transition updates the phase');
    handleEvent({type:'commentary_delta',text:'Checking the worker result.'});
    check(runStepState.active.label === 'Receiving progress update', 'coordinator commentary is a visible phase');
    setLiveness(null);
    finishRunStatus();
    busy = false;
    activeRunId = null;
    observedRun = null;
    runBubble = null;
    report.dataset.status = 'pass';
    report.textContent = JSON.stringify({checks,skipped:0,evidence},null,2);
  } catch (error) {
    report.dataset.status = 'fail';
    report.textContent = String(error.stack || error);
  }
})();
