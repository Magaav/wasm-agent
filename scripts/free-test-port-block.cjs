// Select an unused loopback port block for a fixture's base+offset convention.
// This is selection, not a lease: the fixture must still verify its own processes started.
const net=require('node:net'),{randomInt}=require('node:crypto');
const count=Number(process.argv[2]||64);
(async()=>{
 if(!Number.isInteger(count)||count<1||count>128)throw Error('port block must be 1..128');
 for(let attempt=0;attempt<100;attempt++){
  const base=randomInt(15000,60000-count),servers=[];let available=true;
  try{
   for(let offset=0;offset<count;offset++){
    const server=net.createServer();servers.push(server);
    await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(base+offset,'127.0.0.1',resolve);});
   }
  }catch{available=false;}
  finally{await Promise.all(servers.filter(s=>s.listening).map(s=>new Promise(resolve=>s.close(resolve))));}
  if(available){console.log(base);return;}
 }
 throw Error('no unused test port block found');
})().catch(error=>{console.error(error.message);process.exitCode=1;});
