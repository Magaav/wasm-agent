(async function () {
  const report=document.createElement('pre');report.id='wa-probe';report.style.display='none';document.body.append(report);
  let checks=0;
  const check=(ok,label)=>{if(!ok)throw Error(label);checks++;};
  const snapshot=(models,tools,extra={})=>({kind:'run_counts',version:1,run_id:'counted-run',model_calls:models,tool_calls:tools,...extra});
  try {
    await window.rendererLoaded;
    for(let i=0;i<200&&!transcriptReady;i++)await new Promise(resolve=>setTimeout(resolve,10));
    check(transcriptReady,'startup ready');
    const now=Date.now();
    const user={id:'counted-run',seq:100,role:'user',content:'Count this turn',created_at:(now-68000)/1000,trace:[snapshot(0,0)]};
    busy=false;activeRunId=null;observedRun={session:chatSession,run_id:901};
    repaintMessages([user],{active:true,notify:false});
    handleEvent({type:'run_counts',counts:snapshot(1,0)});
    handleEvent({type:'status',text:'model'});
    check(statusPhase.textContent==='0s'&&statusElapsed.textContent.includes('|✧ 1|⚒ 0|◷ '),'one provider attempt live');
    handleEvent({type:'round',n:1});handleEvent({type:'round',n:1});
    check(runCounts.model_calls===1,'round events never count model attempts');
    handleEvent({type:'run_counts',counts:snapshot(2,0)});
    handleEvent({type:'run_counts',counts:snapshot(2,0)});
    handleEvent({type:'run_counts',counts:snapshot(1,0)});
    check(runCounts.model_calls===2,'retry snapshot counted once; stale snapshot cannot roll back');
    handleEvent({type:'decision',call_id:'read',name:'read_many',arguments_text:'source',complete:true});
    check(statusPhase.textContent==='0s'&&statusPhase.title==='Selecting tools'&&statusElapsed.textContent.includes('|✧ 2|'),'count precedes selection phase');
    const calls={id:'calls',seq:101,role:'assistant',content:'',created_at:now/1000,
      tool_calls:[{id:'read',function:{name:'read_many',arguments:'{}'}}],trace:[snapshot(2,1)]};
    handleEvent({type:'run_counts',counts:snapshot(2,1)});
    handleEvent({type:'tool',call_id:'read',name:'read_many',arguments:{requests:[{path:'one'},{path:'two'}]}});
    handleEvent({type:'tool_result',name:'read_many',result:{ok:true}});
    handleEvent({type:'run_counts',counts:snapshot(3,1)});
    repaintMessages([user,calls],{active:true,notify:false});
    check(runCounts.model_calls===3&&runCounts.tool_calls===1,'checkpoint preserves newer live counts without summing durable snapshots');
    const main=runCounts;
    const child=document.createElement('div');document.body.append(child);
    paintChildTranscript(child,[{...user,id:'child',trace:[snapshot(7,4,{run_id:'child'})]},
      {seq:2,role:'assistant',content:'Child answer',created_at:now/1000,trace:[snapshot(8,4,{run_id:'child',complete:true})]}],{notify:false});
    check(child.querySelector('.finished .chat-content-run-elapsed').textContent.includes('✧ 8 · ⚒ 4'),'child has its own totals');
    check(runCounts===main,'child cannot replace main counts');child.remove();
    handleEvent({type:'reply',text:'Answer.',message_id:'answer'});handleEvent({type:'done'});
    const footer=transcript.querySelector('.finished');
    check(footer.querySelector('.chat-content-run-label').textContent==='completed','completion stays left');
    check(footer.querySelector('.chat-content-run-elapsed').textContent==='✧ 3 · ⚒ 1 · ◷ 1:08','model/tool/time totals preserved right');
    const answer={id:'answer',seq:102,role:'assistant',content:'Answer.',created_at:now/1000,trace:[snapshot(3,1,{complete:true,elapsed_ms:68000})]};
    observedRun=null;runCounts=null;
    repaintMessages([user,calls,answer],{state:'answered',notify:false});
    check(transcript.querySelector('.finished .chat-content-run-elapsed').textContent==='✧ 3 · ⚒ 1 · ◷ 1:08','durable replay restores exact totals after reload');
    repaintMessages([{...user,trace:[]},{...answer,trace:[]}],{state:'answered',notify:false});
    check(transcript.querySelector('.finished .chat-content-run-elapsed').textContent.includes('✧ ? · ⚒ ?'),'historical missing counts remain unknown');
    repaintMessages([user,calls],{state:'unfinished',notify:false});
    check(transcript.querySelector('.finished .chat-content-run-elapsed').textContent.includes('✧ ≥2 · ⚒ ≥1'),'unfinished snapshot is a lower bound, not exact total');
    repaintMessages([user,answer,{...user,id:'new-run',seq:200,trace:[snapshot(0,0,{run_id:'new-run'})]},
      {...answer,seq:201,trace:[snapshot(1,0,{run_id:'new-run',complete:true})]}],{state:'answered',notify:false});
    check(Array.from(transcript.querySelectorAll('.finished .chat-content-run-elapsed')).map(node=>node.textContent).join('|').includes('✧ 3 · ⚒ 1')&&runCounts.model_calls===1,'separate turns never borrow totals');
    document.getElementById('panel').style.width='360px';
    for(const line of transcript.querySelectorAll('.finished'))check(line.scrollWidth<=line.clientWidth+1,'narrow footer fits');
    report.dataset.status='pass';report.textContent=JSON.stringify({checks,skipped:0});
  } catch(error){report.dataset.status='fail';report.textContent=String(error.stack||error);}
})();
