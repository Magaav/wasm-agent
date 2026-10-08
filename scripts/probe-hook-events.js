(async()=>{
 const report=document.createElement('pre');report.id='wa-probe';report.style.display='none';document.body.append(report);let checks=0;
 const check=(v,label)=>{if(!v)throw Error(label);checks++;};
 try{
  await window.rendererLoaded;for(let i=0;i<100;i++)await Promise.resolve();
  await refreshHooks();const panel=document.querySelector('#hooks-box wa-hook-events');
  check(panel.textContent.includes('onSentinelReturn'),'handler listed');
  check(panel.textContent.includes('beforeFinalAnswer')&&panel.textContent.includes('not implemented'),'absent barrier explicit');
  check(!panel.querySelector('button,input'),'no execution/approval controls');
  check(document.querySelector('[data-target="jobs-box"]').closest('.engine-topic').nextElementSibling.querySelector('[data-target="hooks-box"]'),'hooks directly after jobs');
  const data=JSON.parse(JSON.stringify(window.__fixtures.hooks || {schema:1,read_only:true,events:[]}));
  data.events.push({id:'hostile',name:'<img src=x onerror=alert(1)>',kind:'event',producer:'<script>bad</script>',boundary:'read-only',state:'disabled',reliability:'<svg onload=alert(1)>',handlers:[{id:'hostile-job',name:'<img>',enabled:false,last_delivery:{state:'unknown',detail:'<iframe>'}}]});
  panel.catalogue=data;check(!panel.querySelector('img,script,svg,iframe'),'catalogue text not interpreted as HTML');
  panel.catalogue={schema:2,read_only:true,events:[]};check(panel.textContent.includes('unsupported'),'unsupported data visible');
  panel.catalogue={schema:1,read_only:true,events:[null]};check(panel.textContent.includes('unsupported'),'malformed event visible rather than crashing');
  const fetch=apiFetch,originalNode=activeNode,originalEpoch=conversationEpoch;
  try{
   apiFetch=async()=>({ok:false,status:503,json:async()=>({error:'read_capacity_busy'})});await refreshHooks();
   check(panel.textContent.includes('read_capacity_busy'),'read failure named');
   let resolve;apiFetch=()=>new Promise(r=>resolve=r);const pending=refreshHooks();
   conversationEpoch++;panel.message='new target inventory';resolve({ok:true,json:async()=>({schema:1,read_only:true,events:[{id:'stale',name:'stale producer',handlers:[]}]})});await pending;
   check(panel.textContent==='new target inventory','stale async response cannot replace new target');
  }finally{apiFetch=fetch;activeNode=originalNode;conversationEpoch=originalEpoch;}
  await refreshHooks();
  invalidateHookInventory();check(panel.textContent.includes('not loaded for this node'),'node switch invalidates already-rendered inventory');
  await refreshHooks();setEngine(true);document.getElementById('hooks-box').hidden=false;
  document.querySelector('[data-target="hooks-box"]').closest('.engine-topic').classList.add('open');
  report.dataset.status='pass';report.textContent=JSON.stringify({ok:true,checks,skipped:0,scope:'real browser hook inventory'});
 }catch(e){report.dataset.status='fail';report.textContent=String(e.stack||e);}
})();
