// Independent real-route negatives layered on immutable exported HTTP/signed-peer runner.
const fs=require('node:fs'),path=require('node:path'),{spawnSync}=require('node:child_process'),assert=require('node:assert/strict');
const [root,binary,out]=process.argv.slice(2);fs.mkdirSync(out,{recursive:true});
let runner=fs.readFileSync(path.join(root,'scripts/test-serving-http.cjs'),'utf8');
runner=runner.replace("const root=path.resolve(__dirname,'..'),binary=",'const root='+JSON.stringify(root)+',binary=');
const marker="print('signed two-node serving: '..checks..' checks, 0 skips, 0 paid calls')";
assert(runner.includes(marker));
const extra=`
identity.account_profile='account-a'
local raw_http=host.http
local attack
host.http=function(method,url,headers,body)
 if url:find('/node/call',1,true) then
  local req=json.decode(body)
  if attack=='tamper-request' then req.args.model='changed-after-signing';body=json.encode(req) end
  local response=json.decode(raw_http(method,url,headers,body))
  local value=json.decode(response.body or '{}')
  if attack and attack:find('first-',1,true) and req.args.serving_identity_only and value.serving_identity then
   value.serving_identity[attack:sub(7)]='foreign'
  elseif attack=='second-binding' and req.args.serving_identity and value.serving then value.serving.binding=string.rep('b',64)
  elseif attack=='bare-error' and req.args.serving_identity then value={model_error='provider_monthly_quota'}
  elseif attack=='drift' and req.args.serving_identity then value.serving.account_profile='drift-account'
  end
  response.body=json.encode(value);return json.encode(response)
 end
 return raw_http(method,url,headers,body)
end
for _,variant in ipairs({'first-node_id','first-model','first-provider','second-binding','bare-error','drift','tamper-request'}) do
 attack=variant
 local eligible,reason=o.serving_eligible(destination,'fixture','opencode-go')
 check(eligible==true,'real signed route rejects '..variant..' as unknown: '..tostring(reason))
end
attack=nil
check(o.serving_eligible(destination,'fixture')==false,'real default-provider discovery still blocks bound account')
-- Receiver checks requested exact tuple, even with valid signature from caller.
local foreign=json.decode(json.encode(identity));foreign.node_id='foreign-node'
check(nodes.remote_call(destination,'status',{serving_identity=foreign}).serving.state=='unknown','signed foreign target tuple unknown')
foreign=json.decode(json.encode(identity));foreign.provider='foreign-provider'
check(nodes.remote_call(destination,'status',{serving_identity=foreign}).serving.state=='unknown','signed foreign provider tuple unknown')
host.http=raw_http
`;
runner=runner.replace(marker,extra+'\n'+marker);
const file=path.join(out,'runner.cjs');fs.writeFileSync(file,runner);
const result=spawnSync(process.execPath,[file,binary,path.join(out,'private')],{encoding:'utf8',timeout:180000,windowsHide:true});
fs.writeFileSync(path.join(out,'raw.log'),result.stdout+'\nSTDERR\n'+result.stderr);console.log(result.stdout);assert.equal(result.status,0,result.stderr);
