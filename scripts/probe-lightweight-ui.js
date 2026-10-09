(async()=>{
 const out=document.createElement('pre');out.id='wa-probe';document.body.append(out);let checks=0;
 const check=(v,label)=>{if(!v)throw Error(label);checks++;};
 try {
  await window.rendererLoaded;for(let i=0;i<100;i++)await Promise.resolve();
  busy=false;observedRun=null;applyMode('expanded');
  const panelStyle=getComputedStyle(document.querySelector('.panel'));
  check(panelStyle.backdropFilter==='none','panel does not sample backdrop');
  check(getComputedStyle(document.querySelector('.orb-core')).animationName==='none','orb has no perpetual animation');
  const bubble=document.createElement('wa-message');bubble.setAttribute('role','user');bubble.body.textContent='Searchable older evidence';transcript.prepend(bubble);
  bubble.classList.add('render-contained');bubble.style.containIntrinsicSize='auto 150px';
  check(getComputedStyle(bubble).contentVisibility==='auto','browser skips measured off-screen layout and paint');
  check(bubble.textContent.includes('Searchable older evidence'),'virtualized DOM retains evidence');
  const step=document.createElement('wa-step');document.body.append(step);step.setStep('Thinking','running',4000);
  const observer=new MutationObserver(()=>{});observer.observe(step,{subtree:true,attributes:true,childList:true,characterData:true});
  step.setStep('Thinking','running',4200);
  check(observer.takeRecords().length===0,'same-second phase clock has zero DOM mutations');
  step.setStep('Thinking','running',5000);check(observer.takeRecords().length===1,'only elapsed text changes');observer.disconnect();step.remove();
  renderMetadataParts();const observer2=new MutationObserver(()=>{});observer2.observe(document.querySelector('.panel'),{subtree:true,childList:true,characterData:true});
  renderMetadataParts();check(observer2.takeRecords().length===0,'unchanged metadata has no DOM replacement');observer2.disconnect();
  balloon.show();renderMetadataParts();const selectOption=modelSelect.firstElementChild;renderMetadataParts();check(modelSelect.firstElementChild===selectOption,'unchanged option identity and focus preserved');balloon.close();
  const oldFetch=window.fetch,oldDate=Date.now,now=oldDate();let metadataCalls=0;
  window.fetch=function(p,o){if(String(p).startsWith('models?'))metadataCalls++;return oldFetch.call(this,p,o);};
  metaReady=true;metadataRefreshedAt=now;metadataRetryAt=0;
  Date.now=()=>now+6000;await ensureMeta();check(metadataCalls===0,'idle does not scan metadata every five seconds');
  Date.now=()=>now+31000;await ensureMeta();check(metadataCalls===1,'idle fallback reconciles authoritative settings');
  Date.now=oldDate;window.fetch=oldFetch;
  applyMode('compact');check(!uiVisible()&&document.body.classList.contains('ui-resting'),'compact mode rests visual work');applyMode('expanded');
  busy=true;runBubble=null;handleEvent({type:'delta',text:'Instant streaming'});check(transcript.textContent.includes('Instant streaming'),'stream stays synchronous, not frame-dependent');handleEvent({type:'reply',text:'Instant streaming'});handleEvent({type:'done'});busy=false;
  check(transcript.textContent.includes('Searchable older evidence'),'stream updates never delete older evidence');
  document.title='wasm-agent';out.dataset.status='pass';out.textContent='LIGHTWEIGHT PASS '+checks;
 }catch(e){out.dataset.status='fail';out.textContent=e.stack||String(e);}
})();
