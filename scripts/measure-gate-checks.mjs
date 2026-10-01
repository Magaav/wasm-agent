import fs from 'node:fs';
import path from 'node:path';
import {executeChecks} from './gate-check.mjs';
import {catalog} from './gate-checks.mjs';
const destination=path.resolve(process.argv[2]||'.git/throughput-measurements');
const repo=process.cwd(), rows=[];
for(let sample=1;sample<=3;sample++)for(const workload of ['single','batch'])for(const jobs of [1,2]){
  const ids=workload==='single'?['js:composer-input.js']:catalog(repo).filter(c=>c.id.startsWith('js:')).map(c=>c.id);
  const output=path.join(destination,`${workload}-${jobs}-${sample}`);
  const result=await executeChecks(repo,ids,{jobs,output,emit:false});
  rows.push({workload,jobs,sample,passed:result.passed,ms:result.ms,total_check_ms:result.results.reduce((sum,r)=>sum+r.ms,0),checks:result.results.length,receipt:path.join(output,'checks.json')});
  console.log(JSON.stringify(rows.at(-1)));if(!result.passed)throw Error('measurement workload failed');
}
fs.writeFileSync(path.join(destination,'summary.json'),JSON.stringify({n:3,rows,limits:'same source and test IDs; alternating 1/2 width; wall and summed child duration only; source fixtures, not reviewed delivery-to-deployment latency; no resource telemetry; other lanes may be active'},null,2)+'\n');
