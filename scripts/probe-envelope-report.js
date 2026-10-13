// Headless, synchronous assertions for the standalone report, never the installed UI.
(function(){var checks=0;var check=(v,label)=>{checks++;if(!v)throw Error(label);};var node=document.createElement('pre');node.id='wa-probe';node.style.display='none';try{
 check(document.title==='wasm-agent — progressive envelope before and after','exact report title');
 ['before-after','empty-session','expansion','benchmark','causality','web-proof','power','delivery'].forEach(id=>check(!!document.getElementById(id),'section '+id));
 check(document.querySelectorAll('#empty-session details').length===3,'all three empty envelopes');
 var text=document.body.textContent;
 ['71,357','34,963','43,964','9,020','4,479','Net growth','model-free shadow replay','not general AI task quality','thirteen declarations stay stable','219.08 seconds','Self-review, not independent review','gate_verified:false'].forEach(s=>check(text.includes(s),'reported claim '+s));
 var patched=document.querySelectorAll('#empty-session details')[1],pres=patched.querySelectorAll('pre');var tools=JSON.parse(pres[1].textContent);check(tools.length===13,'actual bootstrap13');
 check(pres[0].textContent.includes('Additional capabilities')&&pres[0].textContent.includes('<available_skills>'),'complete role and skill pointers retained');
 var stages=[...document.querySelectorAll('#expansion details')];check(stages.length===6,'six recorded requests');var prefix=null;stages.forEach((d,i)=>{var r=JSON.parse(d.querySelector('pre').textContent);var p=JSON.stringify(r.tools);check(r.tools.length===13,'stable count '+i);check(prefix===null||prefix===p,'identical declaration array '+i);prefix=p;});
 check(document.querySelector('.cards strong').textContent==='51.0% smaller','measured reduction, causal oracle');
 check(!document.querySelector('img,iframe,script[src^="http"],link[href^="http"]'),'standalone with no remote assets');
 check(document.body.scrollWidth<=innerWidth+1,'desktop no horizontal overflow');
 check(getComputedStyle(document.querySelector('h1')).fontSize==='36px','readable header');
 node.dataset.status='pass';node.textContent=JSON.stringify({ok:true,checks,skipped:0});
}catch(e){node.dataset.status='fail';node.textContent=JSON.stringify({ok:false,checks,error:e.message});}document.body.append(node);})();
