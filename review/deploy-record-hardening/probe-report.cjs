let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
  const NAME="the deploy's verdict matches the record";
  try{const j=JSON.parse(s);
    const f=j.results.find(r=>r.name===NAME);
    console.log(f?`[${f.status}] ${f.detail}`:`NO SUCH CHECK (checks=${j.checks}, failed=${j.failed}, skipped=${j.skipped})`);
    const bad=j.results.filter(r=>r.status!=="ok").map(r=>`${r.status}:${r.name}`);
    if(bad.length>1 || !f) console.log("        every non-ok check: "+(bad.join(" | ")||"none"));
  }catch(e){console.log("UNPARSEABLE: "+s.slice(0,300));}});
