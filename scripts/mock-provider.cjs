// Local transport fixture for concurrency tests. No upstream requests or credentials.
const http=require('node:http');
const server=http.createServer((req,res)=>{
  if(req.method==='GET'){res.end('ready');return;}
  let body=''; req.on('data',chunk=>{body+=chunk;});
  req.on('end',()=>setTimeout(()=>{
    const usage={prompt_tokens:10,completion_tokens:1,total_tokens:11,prompt_tokens_details:{cached_tokens:0}};
    if(JSON.parse(body).stream){
      res.writeHead(200,{'content-type':'text/event-stream'});
      res.end('data: '+JSON.stringify({id:'mock-request',choices:[{delta:{content:'ok'},finish_reason:'stop'}],usage})+'\n\ndata: [DONE]\n\n');
      return;
    }
    res.writeHead(200,{'content-type':'application/json'});
    res.end(JSON.stringify({id:'mock-request',model:'deepseek-v4.1-flash',
      choices:[{message:{role:'assistant',content:'ok'},finish_reason:'stop'}],
      usage}));
  },12000));
});
server.listen(Number(process.argv[2]),'127.0.0.1');
