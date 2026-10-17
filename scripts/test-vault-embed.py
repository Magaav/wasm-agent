#!/usr/bin/env python3
"""Private real-HTTP fixture and contract proof for vault-owned Go embedding. Synthetic only."""
import contextlib
import http.client
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import threading
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT=Path(__file__).resolve().parent.parent
TOKEN='fixture-embed-admin-authorization-000000000000'
KEY1='fixture-embed-secret-one-operator-only'
KEY2='fixture-embed-secret-two-operator-only'
checks=0

def check(value,label):
    global checks
    checks+=1
    if not value: raise AssertionError(label)

class Fixture:
    def __init__(self,parent='http://127.0.0.1:34567'):
        self.temp=tempfile.TemporaryDirectory(prefix='wa-vault-embed-')
        self.logs=io.StringIO();self.parent=parent;self.mode='normal';self.upstream=[];self.writes=0;self.save_attempts=0
        outer=self
        class Upstream(BaseHTTPRequestHandler):
            def log_message(self,*args): pass
            def do_POST(self):
                outer.upstream.append(self.headers.get('Authorization'))
                self.rfile.read(int(self.headers.get('Content-Length','0')))
                body=b'{"choices":[{"message":{"content":"synthetic"}}]}'
                self.send_response(200);self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
        self.up=ThreadingHTTPServer(('127.0.0.1',0),Upstream)
        threading.Thread(target=self.up.serve_forever,daemon=True).start()
        self.proxy_port=0;self.admin_port=0;self.start()
    def start(self):
        for name in list(os.environ):
            if name.startswith(('WA_','WASM_AGENT_','OPENAI_','OPENCODE_','PI_')): os.environ.pop(name,None)
        os.environ.update(WA_VAULT_ADMIN_TOKEN=TOKEN,WA_VAULT_DATA=self.temp.name,WA_VAULT_BIND='127.0.0.1',WA_VAULT_EMBED_PARENT_ORIGIN=self.parent,WA_VAULT_OPENCODE_BASE='http://127.0.0.1:'+str(self.up.server_port)+'/go/v1')
        spec=importlib.util.spec_from_file_location('private_embed_'+uuid.uuid4().hex,ROOT/'vault/wa_vault.py')
        module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);self.module=module
        module.log=lambda message:self.logs.write(message+'\n')
        module.update_store(lambda store:store.setdefault('_vault_id',str(uuid.uuid4())))
        outer=self
        class Admin(module.AdminHandler):
            def do_GET(self):
                if self.path=='/embed/go' and outer.mode=='redirect-frame':
                    outer.mode='normal';self.send_response(302);self.send_header('Location','/');self.send_header('Content-Length','0');self.end_headers();return
                super().do_GET()
            def do_POST(self):
                if self.path=='/api/embed/go/save':outer.save_attempts+=1
                if self.path=='/api/embed/go/save' and outer.mode=='drop-before':
                    self.read_body();self.close_connection=True;return
                super().do_POST()
            def send_json(self,status,value,extra=None):
                if self.path=='/api/embed/go/save' and status==200:
                    outer.writes+=1
                    if outer.mode=='drop-after':
                        outer.mode='normal';self.close_connection=True;return
                super().send_json(status,value,extra)
        self.proxy=module.serve(self.proxy_port,module.ProxyHandler,'proxy')
        self.admin=module.serve(self.admin_port,Admin,'admin')
        self.proxy_port=self.proxy.server_port;self.admin_port=self.admin.server_port
        for server in (self.proxy,self.admin):threading.Thread(target=server.serve_forever,daemon=True).start()
    def restart(self):
        for server in (self.proxy,self.admin):server.shutdown();server.server_close()
        self.start()
    def info(self):
        return {'proxy':'http://127.0.0.1:'+str(self.proxy_port),'admin':'http://127.0.0.1:'+str(self.admin_port),'vault_id':self.module.read_store()['_vault_id']}
    def stats(self):
        state=self.module.public_status(self.module.read_store())
        secrets=(TOKEN,KEY1,KEY2)
        journal=json.dumps(self.module.read_store().get('_go_operations',{}))
        return {'writes':self.writes,'save_attempts':self.save_attempts,'upstream_calls':len(self.upstream),'upstream_key_one':bool(self.upstream and self.upstream[-1]=='Bearer '+KEY1),'upstream_key_two':bool(self.upstream and self.upstream[-1]=='Bearer '+KEY2),'secrets_in_log_or_journal':any(s in self.logs.getvalue()+journal for s in secrets),'providers':state,'log_tail':self.logs.getvalue().splitlines()[-12:]}
    def close(self):
        for server in (self.proxy,self.admin,self.up):server.shutdown();server.server_close()
        self.temp.cleanup()

def request(port,path,body=None,headers=None):
    conn=http.client.HTTPConnection('127.0.0.1',port,timeout=10)
    conn.request('GET' if body is None else 'POST',path,body=None if body is None else body if isinstance(body,bytes) else json.dumps(body),headers=headers or {})
    response=conn.getresponse();raw=response.read();result=(response.status,raw,dict(response.headers));conn.close();return result

def proof(f):
    info=f.info();scope='a'*64;operation=str(uuid.uuid4());base={'scope':scope,'expected_vault_id':info['vault_id']}
    headers={'Content-Type':'application/json','X-Vault-Token':TOKEN,'X-Vault-Instance':info['vault_id'],'Origin':info['admin']}
    def call(action,body=None,h=None):
        status,raw,_=request(f.admin_port,'/api/embed/go/'+action,dict(base,**(body or {})),headers if h is None else h)
        check(not any(s.encode() in raw for s in (TOKEN,KEY1,KEY2)),'API response contains no credential')
        return status,json.loads(raw)
    status,raw,h=request(f.admin_port,'/embed/go')
    check(status==200 and 'frame-ancestors '+f.parent in h['Content-Security-Policy'],'only exact configured parent may frame embedded form')
    check('X-Frame-Options' not in h and "form-action 'none'" in h['Content-Security-Policy'],'embedded form has restrictive CSP without contradictory DENY')
    check(b'type="password"' in raw and b'Save to vault' in raw,'vault-owned password/save form is real served HTML')
    _,_,root_headers=request(f.admin_port,'/')
    check(root_headers.get('X-Frame-Options')=='DENY' and "frame-ancestors 'none'" in root_headers['Content-Security-Policy'],'ordinary full admin page remains unframeable')
    check(request(f.admin_port,'/api/embed/go/prepare',b'',{})[0]==401,'unauthorized preparation denied before body processing')
    check(request(f.admin_port,'/api/embed/go/prepare',b'',dict(headers,Origin='http://stale.invalid'))[0]==401,'foreign admin Origin denied before body processing')
    check(request(f.admin_port,'/api/embed/go/prepare',b'',dict(headers,**{'X-Vault-Instance':str(uuid.uuid4())}))[0]==401,'wrong vault instance denied before body processing')
    status,state=call('prepare',{'operation':operation,'expected_generation':'absent'})
    check(status==200 and state['operations'][0]['state']=='prepared','durable prewrite operation exists before key sent')
    check(KEY1 not in Path(f.module.STORE_PATH).read_text(),'prewrite fence contains no proposed credential')
    check(call('prepare',{'operation':str(uuid.uuid4()),'expected_generation':'absent'})[0]==409,'another operation cannot bypass held prepare')
    foreign=dict(base,scope='b'*64,operation=operation)
    code,_,_=request(f.admin_port,'/api/embed/go/save',dict(foreign,key=KEY1),headers)
    check(code==409,'foreign node/account scope cannot consume prepared operation')
    check(call('cancel',{'operation':operation})[1]['operations'][0]['state']=='cancelled','explicit cancellation fences prepare')
    check(call('save',{'operation':operation,'key':KEY1})[0]==409,'late save after cancellation denied')
    operation=str(uuid.uuid4());call('prepare',{'operation':operation,'expected_generation':'absent'})
    status,saved=call('save',{'operation':operation,'key':KEY1})
    generation=saved['entry']['generation']
    check(status==200 and saved['entry']['operation']==operation and saved['operations'][-1]['generation']==generation,'exact operation and generation prove commit')
    check(call('save',{'operation':operation,'key':KEY2})[0]==409,'successful save never replayed')
    check(call('cancel',{'operation':operation})[1]['operations'][-1]['state']=='committed','late cancel reports commit rather than false cancellation')
    check(call('prepare',{'operation':str(uuid.uuid4()),'expected_generation':'absent'})[0]==409,'stale generation save refused')
    stale=str(uuid.uuid4());call('prepare',{'operation':stale,'expected_generation':generation})
    f.module.set_opencode_key(KEY2,expected=generation,operation=str(uuid.uuid4()))
    check(call('save',{'operation':stale,'key':KEY1})[0]==409,'concurrent replacement wins CAS; stale prepared write cannot overwrite')
    check(call('state')[1]['operations'][-1]['state']=='refused','refused operation outcome retained')
    current=call('state')[1]['entry']['generation'];unknown=str(uuid.uuid4());call('prepare',{'operation':unknown,'expected_generation':current})
    f.mode='drop-after'
    try:call('save',{'operation':unknown,'key':KEY1});lost=False
    except http.client.RemoteDisconnected:lost=True
    check(lost,'ambiguous write response retained as unknown send')
    reconciled=call('state')[1]
    check(reconciled['operations'][-1]['operation']==unknown and reconciled['operations'][-1]['state']=='committed','status reconciles exact ambiguous operation without resend')
    count=f.writes;f.restart()
    _,raw,_=request(f.proxy_port,'/status');persisted=json.loads(raw)
    check(persisted['vault_id']==info['vault_id'] and persisted['providers']['opencode-go']['operation']==unknown,'restart retains durable identity/credential/operation')
    check(f.writes==count and call('state')[1]['operations'][-1]['state']=='committed','restart/readback never repeats save')
    code,raw,_=request(f.proxy_port,'/opencode-go/v1/chat/completions',{'model':'fixture'},{'Authorization':'Bearer wa-vault-brokered'})
    check(code==200 and f.stats()['upstream_key_one'],'fake upstream receives vault credential, not placeholder')
    check(KEY1.encode() not in raw and TOKEN.encode() not in raw,'proxy response does not return credentials')
    check(not f.module.configured(f.module.read_store(),'openai-sub'),'Go entry never creates/changes subscription credential')
    check(not f.stats()['secrets_in_log_or_journal'],'logs and operation journal contain no secret values')
    gen=f.module.public_status(f.module.read_store())['opencode-go']['generation']
    op_a,op_b=str(uuid.uuid4()),str(uuid.uuid4())
    call('prepare',{'operation':op_a,'expected_generation':gen})
    other=dict(base,scope='b'*64,operation=op_b,expected_generation=gen)
    check(request(f.admin_port,'/api/embed/go/prepare',other,headers)[0]==200,'independent operator scope prepares observed generation')
    barrier=threading.Barrier(2);results=[]
    def race(scope_value,op,key):
        barrier.wait();results.append(request(f.admin_port,'/api/embed/go/save',dict(base,scope=scope_value,operation=op,key=key),headers)[:2])
    workers=[threading.Thread(target=race,args=(scope,op_a,KEY1)),threading.Thread(target=race,args=('b'*64,op_b,KEY2))]
    for worker in workers:worker.start()
    for worker in workers:worker.join()
    check(sorted(code for code,_ in results)==[200,409],'real concurrent saves have one commit and one stale refusal')
    check(all(not any(secret.encode() in raw for secret in (TOKEN,KEY1,KEY2)) for _,raw in results),'concurrent responses contain no credential values')
    os.environ['WA_VAULT_EMBED_PARENT_ORIGIN']='*'
    check(request(f.admin_port,'/embed/go')[0]==503,'wildcard framing configuration fails closed')
    check(call('state')[0]==503,'invalid embedding policy cannot write through embedded API')
    os.environ['WA_VAULT_EMBED_PARENT_ORIGIN']=f.parent
    print(json.dumps({'checks':checks,'failed':0,'skipped':0,'paid_calls':0}))

def main():
    fixture=Fixture(sys.argv[2] if len(sys.argv)>2 and sys.argv[1]=='--serve' else 'http://127.0.0.1:34567')
    try:
        if len(sys.argv)>1 and sys.argv[1]=='--serve':
            print(json.dumps(fixture.info()),flush=True)
            for line in sys.stdin:
                command=json.loads(line);action=command.get('action')
                if action=='stop':break
                if action=='restart':fixture.restart();result=fixture.info()
                elif action=='mode':fixture.mode=command['mode'];result={'ok':True}
                else:result=fixture.stats()
                print(json.dumps(result),flush=True)
        else:proof(fixture)
    finally:fixture.close()
if __name__=='__main__':main()
