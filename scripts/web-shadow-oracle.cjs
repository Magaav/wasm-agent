'use strict';
const assert=require('node:assert/strict');
// Independent read-only acceptance: no implementation imports, model or code-shape checks.
module.exports=function oracle(arm,fixture,protocol,fetches){
 const facts=fixture.required_facts;assert(arm.ok,'arm failed');assert(arm.answer.includes(facts[0])&&arm.answer.includes(facts[1]),'initial facts missing');assert(arm.followup.includes(facts[2]),'followup fact missing');for(const s of fixture.sources)assert(arm.answer.includes(s.url),'citation missing');assert(arm.followup.includes(fixture.sources[1].url),'followup citation missing');
 const calls=protocol.filter(x=>x.method==='tools/call');assert.equal(calls.length,fixture.expected_tool_calls,'missing/duplicate app calls');assert.equal(fetches.filter(x=>x.url===fixture.sources[0].url).length,1,'source A fetch count');assert.equal(fetches.filter(x=>x.url===fixture.sources[1].url).length,1,'cached followup must not refetch source B');assert.equal(fetches.length,3,'unexpected network input');
 const content=arm.tool_results.map(x=>x.content).join('\n');assert(content.includes(facts[0])&&content.includes(facts[1])&&content.includes(facts[2]),'necessary source facts not model-visible');assert(arm.requests.length>=5,'missing model-facing envelope captures');
 return {ok:true,checks:12,agent_quality_measured:false};
};
