(async()=>{
 const problems=[];const check=(ok,label)=>{if(!ok)problems.push(label);};
 await window.rendererLoaded;
 await refreshMe();await restoreSession();
 synced=true;syncRunning=false;
 document.body.classList.add('expanded');
 messages.replaceChildren();runBubble=null;streamBody=null;streamText='';runStepState=null;
 busy=true;
 const retry=(index,state,reason)=>({type:'retry',retry_id:'fixture-recovery',index,limit:10,state,reason,window_ms:60000,elapsed_ms:(index-1)*6000});
 handleEvent(retry(1,'waiting','response_body: UND_ERR_SOCKET — other side closed'));
 handleEvent(retry(1,'attempting','Reconnecting to provider'));
 let topic=messages.querySelector('wa-retry');
 check(!!topic&&topic.closest('wa-message')?.getAttribute('role')==='assistant','retry topic belongs to turn bubble');
 check(topic.querySelector('.trace-label').textContent==='Retry 1/10','numbered retry header');
 check(topic.querySelectorAll('.retry-line').length===1,'states update one row per attempt');
 for(let n=2;n<=10;n++){
  handleEvent(retry(n,'waiting','ECONNRESET <img src=x onerror=alert(1)>'));
  handleEvent(retry(n,'attempting','Reconnecting to provider'));
  handleEvent(retry(n,'failed','Could not establish connection'));
 }
 handleEvent(retry(10,'exhausted','Recovery window expired'));
 check(topic.querySelectorAll('.retry-line').length===10,'ten distinct attempts retained');
 handleEvent({...retry(10,'reconnecting','Other side closed'),cycle:1,wait_ms:180000});
 check(topic.querySelector('.trace-label').textContent==='Reconnecting in 3 minutes','cooldown header clearly names delayed recheck');
 check(topic.querySelector('.trace-meta').textContent.includes('180s'),'cooldown has visible countdown');
 handleEvent({...retry(1,'attempting','Second reconnect cycle'),cycle:2});
 check(topic.querySelectorAll('.retry-line').length===11,'cycle2 does not erase cycle1 history');
 handleEvent({...retry(10,'exhausted','Recovery deadline reached'),cycle:2});
 check(topic.textContent.includes('UND_ERR_SOCKET')&&topic.textContent.includes('10/10'),'first cause and last count retained');
 check(!topic.querySelector('img'),'untrusted reasons rendered as text');
 check(topic.open&&topic.dataset.state==='exhausted','exhaustion visible and expanded');
 handleEvent({type:'reply',text:'Recovery failed; task state preserved.'});
 handleEvent({type:'done'});busy=false;
 check(!!messages.querySelector('wa-run wa-retry'),'retry topic remains within finished run history');
 const rows=[{seq:1,id:'u',role:'user',content:'fixture question',created_at:100},
  ...[retry(1,'waiting','socket failed'),retry(1,'attempting','connecting'),retry(1,'recovered','Provider response restored')]
   .map((event,i)=>({seq:i+2,id:'retry-'+i,role:'retry',content:JSON.stringify(event),created_at:101+i})),
  {seq:5,id:'answer',role:'assistant',content:'Recovered answer',created_at:105,tool_calls:[]}];
 repaintMessages(rows,{state:'answered'});
 topic=messages.querySelector('wa-retry');
 check(topic&&topic.dataset.state==='recovered','repaint restores actual recovery outcome');
 check(topic.querySelectorAll('.retry-line').length===1,'replay states do not duplicate attempt');
 check(!topic.open,'successful recovery folds away');
 const child=document.createElement('div');child.className='agent-transcript';document.body.append(child);
 paintChildTranscript(child,rows,{state:'answered'});
 check(child.querySelector('wa-retry')?.dataset.state==='recovered','same renderer works in child host without spawning child');
 child.remove();
 const activeRows=[rows[0],{seq:2,id:'cooldown',role:'retry',created_at:Date.now()/1000-30,
   content:JSON.stringify({...retry(10,'reconnecting','last socket failure'),wait_ms:180000})}];
 repaintMessages(activeRows,{state:'unfinished',active:true});
 topic=messages.querySelector('wa-retry');
 check(topic.dataset.state==='reconnecting'&&topic._event.wait_ms<=150000&&topic._event.wait_ms>148000,
   'active repaint subtracts already elapsed cooldown rather than restarting three minutes');
 repaintMessages(activeRows,{state:'unfinished',active:false});
 check(messages.querySelector('wa-retry')?.dataset.state==='unfinished','historical unfinished retry does not claim active reconnection');
 const orphan=document.createElement('wa-retry');document.body.append(orphan);orphan.update(retry(2,'waiting','cancel fixture'));orphan.interrupt('cancelled');
 check(orphan.dataset.state==='cancelled'&&orphan.open,'cancelled recovery does not look restored');orphan.remove();
 const fixtureFetch=window.fetch;
 window.fetch=async(url,init)=>String(url).replace(/^.*\//,'').startsWith('health')
   ? {ok:true,json:async()=>({ok:true,current:{session:chatSession,run_id:'retry-fixture',state:'running'},run_ids:[{conversation:chatSession,run_id:'retry-fixture',state:'running'}],runs:[{conversation:chatSession}],stalled_ms:0})}
   : fixtureFetch(url,init);
 activeRunId={run_id:'retry-fixture'};
 messages.replaceChildren();runBubble=null;streamBody=null;streamText='';runStepState=null;busy=true;runStartedAt=Date.now();
 add('user','A temporary provider disconnect');
 for(let n=1;n<=10;n++)handleEvent(retry(n,'failed','response_headers: ECONNRESET — connection closed'));
 handleEvent({...retry(10,'reconnecting','Last connection attempt failed; task preserved'),wait_ms:180000});
 const output=document.createElement('pre');output.id='wa-probe';output.dataset.status=problems.length?'fail':'pass';
 output.textContent=problems.length?problems.join('; '):'retry UI ok';document.body.append(output);
})();
