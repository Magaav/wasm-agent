// Local HTTP only: no model provider, credentials or external network.
import http from 'node:http';
import crypto from 'node:crypto';
const records=[],counts=new Map();
const server=http.createServer((req,res)=>{const chunks=[];req.on('data',b=>chunks.push(b));req.on('end',()=>{
 const body=Buffer.concat(chunks),n=(counts.get(req.url)||0)+1,endpoint=new URL(req.url,'http://localhost').pathname.split('/').pop();counts.set(req.url,n);
 records.push({path:req.url,index:n,bytes:body.length,sha256:crypto.createHash('sha256').update(body).digest('hex')});
 if(req.url==='/records'){res.writeHead(200,{'content-type':'application/json'});res.end(JSON.stringify(records));return;}
 if(endpoint==='unknown'||n===1){res.writeHead(507,{'content-type':'text/plain'});res.end(endpoint==='unknown'?'Insufficient Storage':'exceeded request buffer limit while retrying upstream');return;}
 res.writeHead(200,{'content-type':'text/event-stream'});
 for(const event of [
  {type:'response.output_item.added',output_index:0,item:{type:'message',id:'message',phase:'final_answer'}},
  {type:'response.output_text.delta',output_index:0,delta:'Socket recovered'},
  {type:'response.completed',response:{id:'fixture-response',status:'completed',usage:{input_tokens:100,output_tokens:10,total_tokens:110}}}
 ])res.write('data: '+JSON.stringify(event)+'\n\n');res.end();
 });});
server.listen(0,'127.0.0.1',()=>console.log(JSON.stringify({url:'http://127.0.0.1:'+server.address().port})));
process.on('SIGTERM',()=>server.close(()=>process.exit(0)));
