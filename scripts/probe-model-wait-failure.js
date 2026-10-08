(async()=>{
 const report=document.createElement('pre');report.id='wa-probe';document.body.append(report);let checks=0;
 const check=(v,label)=>{if(!v)throw Error(label);checks++;};
 try{
  await window.rendererLoaded;for(let i=0;i<100;i++)await Promise.resolve();
  busy=true;activeRunId='fixture-wait';observedRun=null;runStepState=null;runBubble=null;
  repaintMessages([{id:'wait-user',seq:1,role:'user',content:'Private failure diagnosis',created_at:Date.now()/1000}],{active:true,notify:false});
  handleEvent({type:'round',n:45});handleEvent({type:'status',text:'model'});
  const wait=runStepState.active;check(wait.label==='Waiting for model response','original phase label');
  wait.started=Date.now()-20236;
  handleEvent({type:'error',error:'subscription_stream_failure: stage=response_body cause=UND_ERR_SOCKET attempt=1 model_output_seen=true; terminated'});
  check(wait.node.dataset.state==='failed','actual error marks phase failed');
  check(wait.node.querySelector('.run-step-glyph').textContent==='!','exclamation is failure glyph');
  check(wait.node.querySelector('.run-step-age').textContent==='20s','20 is elapsed floor, not timeout/retry count');
  check(wait.node.querySelector('.run-step-label').textContent==='Waiting for model response','old label remains after failure');
  check(!wait.node.querySelector('.spinner'),'failure stops spinner');
  check(transcript.textContent.includes('UND_ERR_SOCKET'),'underlying failure remains visible');
  handleEvent({type:'done'});check(wait.node.dataset.state==='failed','done cannot erase preceding failure');
  check(!runStatusTicker,'terminal events clear ticker');
  report.dataset.status='pass';report.textContent=JSON.stringify({ok:true,checks,skipped:0,paid_calls:0,scope:'reproduction of original model-wait failure rendering'});
 }catch(e){report.dataset.status='fail';report.textContent=String(e.stack||e);}
})();
