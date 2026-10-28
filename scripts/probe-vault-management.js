(async()=>{
 const report=document.createElement('pre');report.id='wa-probe';report.style.display='none';document.body.append(report);
 let checks=0;const check=(value,label)=>{checks++;if(!value)throw Error(label);};const tick=async()=>{for(let i=0;i<30;i++)await Promise.resolve();};
 try{
  check(document.getElementById('ocg-key').type==='password'&&document.getElementById('auth-token').type==='password','dedicated password inputs');
  const fixture='synthetic-only-key-should-not-persist',adminFixture='synthetic-admin-only-40-characters-token';
  window.fetch=async(url,options)=>{check(url==='/identity'&&!options.headers,'binding check sends no operator authorization');return{ok:true,json:async()=>({vault_id:'right-vault'})};};
  check(!await bindVault('wrong-vault')&&document.getElementById('auth').hidden,'wrong vault identity refuses enrollment before secret input');
  check(await bindVault('right-vault')&&!document.getElementById('auth').hidden,'matching public vault identity permits explicit enrollment');
  const state={providers:{'opencode-go':{configured:true,enabled:true,generation:'generation-1'}}};
  let calls=[],resolveWrite=null;window.confirm=()=>true;
  window.fetch=async(url,options)=>{calls.push({url,options});
   if(options.method==='POST'&&url==='/api/opencode-go/key')return new Promise(resolve=>{resolveWrite=resolve;});
   return{status:200,ok:true,json:async()=>state};};
  document.getElementById('auth-token').value=adminFixture;document.getElementById('auth-form').dispatchEvent(new Event('submit',{cancelable:true}));await tick();
  check(document.getElementById('auth-token').value==='','admin transient field cleared');
  check(!document.getElementById('opencode-go').hidden,'operator enrollment usable');
  check(document.body.textContent.includes('same exhausted workspace'),'quota explanation rendered');
  document.getElementById('ocg-key').value=fixture;document.getElementById('ocg-cancel').click();
  check(document.getElementById('ocg-key').value===''&&calls.length===1,'cancel clears without write');
  const form=document.getElementById('ocg-form');document.getElementById('ocg-key').value=fixture;
  form.dispatchEvent(new Event('submit',{cancelable:true}));form.dispatchEvent(new Event('submit',{cancelable:true}));await tick();
  check(calls.length===2&&calls[1].url==='/api/opencode-go/key','save is single flight, dedicated write only endpoint');
  const sent=JSON.parse(calls[1].options.body);check(sent.expected_generation==='generation-1'&&!!sent.operation,'write carries CAS and opaque operation');
  check(document.getElementById('ocg-key').value==='','key transient input cleared immediately');
  check(!JSON.stringify(localStorage).includes(fixture)&&!JSON.stringify(sessionStorage).includes(fixture)&&!JSON.stringify(localStorage).includes(adminFixture)&&!JSON.stringify(sessionStorage).includes(adminFixture),'no secret persistence');
  check(!document.documentElement.outerHTML.includes(fixture)&&!document.documentElement.outerHTML.includes(adminFixture),'no secret DOM/transcript/capture text');
  resolveWrite({status:200,ok:true,json:async()=>({ ...state,providers:{...state.providers,'opencode-go':{configured:true,enabled:true,generation:'generation-2',operation:sent.operation}}})});await tick();
  check(document.body.textContent.includes('exact operation committed'),'save reconciled by exact operation, not presence');
  calls=[];window.fetch=async()=>{throw Error('fixture ambiguous send');};document.getElementById('ocg-key').value=fixture;form.dispatchEvent(new Event('submit',{cancelable:true}));await tick();
  check(document.body.textContent.includes('outcome unknown')&&form.querySelector('button').disabled,'unknown outcome visible and cannot be replayed');
  check(document.getElementById('ocg-key').value==='','failed save clears transient key');
  check(!location.href.includes(fixture)&&!location.href.includes(adminFixture),'secrets not in URL');
  report.dataset.status='pass';report.textContent=JSON.stringify({checks,skipped:0});
 }catch(error){report.dataset.status='fail';report.textContent=String(error.stack||error);}
})();
