"""Actual private watcher intake. Windows Job owns watcher tree; raw evidence retained.
No effects: protocol held, legacy resolver explicitly absent, no jobs enabled.
"""
import argparse, ctypes, http.server, json, os, pathlib, subprocess, threading, time
from ctypes import wintypes
p=argparse.ArgumentParser();p.add_argument('--sentinel',required=True);p.add_argument('--evidence',required=True);a=p.parse_args()
root=pathlib.Path(a.evidence).resolve();root.mkdir(parents=True,exist_ok=False)
assert os.name=='nt','explicit Windows tree supervisor required'
k=ctypes.WinDLL('kernel32',use_last_error=True)
k.CreateJobObjectW.argtypes=[ctypes.c_void_p,wintypes.LPCWSTR];k.CreateJobObjectW.restype=wintypes.HANDLE
k.AssignProcessToJobObject.argtypes=[wintypes.HANDLE,wintypes.HANDLE];k.AssignProcessToJobObject.restype=wintypes.BOOL
k.TerminateJobObject.argtypes=[wintypes.HANDLE,wintypes.UINT];k.TerminateJobObject.restype=wintypes.BOOL
k.QueryInformationJobObject.argtypes=[wintypes.HANDLE,ctypes.c_int,ctypes.c_void_p,wintypes.DWORD,ctypes.c_void_p];k.QueryInformationJobObject.restype=wintypes.BOOL
k.CloseHandle.argtypes=[wintypes.HANDLE]
class Accounting(ctypes.Structure):
 _fields_=[('user',ctypes.c_longlong),('kernel',ctypes.c_longlong),('period_user',ctypes.c_longlong),('period_kernel',ctypes.c_longlong),('faults',wintypes.DWORD),('total',wintypes.DWORD),('active',wintypes.DWORD),('terminated',wintypes.DWORD)]
class Health(http.server.BaseHTTPRequestHandler):
 def do_GET(self):
  time.sleep(2.2)
  body=b'{"ok":true,"current":{"busy":true},"queue":1,"operation_overdue":false,"workers":[],"subagents":{"active":0,"queued":0,"running":0}}'
  try:self.send_response(200);self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
  except (BrokenPipeError,ConnectionResetError,ConnectionAbortedError):pass
 def log_message(self,*args):pass
s=http.server.ThreadingHTTPServer(('127.0.0.1',0),Health)
t=threading.Thread(target=s.serve_forever);t.start()
env={key:value for key,value in os.environ.items() if key.upper() in {'PATH','SYSTEMROOT','WINDIR','COMSPEC','TEMP','TMP','PATHEXT','SYSTEMDRIVE','LOCALAPPDATA'}}
env.update(WASM_AGENT_HOME=str(root),WA_INSTALL_DIR=str(root/'install'),WASM_AGENT_PORT=str(s.server_port),WA_SENTINEL_SUPERVISOR='none',WA_SENTINEL_DEPLOY=str(root/'absent-script.sh'),WASM_AGENT_IN_TURN='1')
box=root/'.wasm-agent/sentinel';(box/'requests').mkdir(parents=True);(root/'install').mkdir()
requests=[]
for n in range(4):
 req={'verb':'deploy','id':f'private-{n}','expected_sha':'a'*40,'session':'parent','owner':'unproved','queued_at':int(time.time())};requests.append(req)
 (box/'requests'/f'private-{n}.json').write_text(json.dumps(req))
(box/'requests/000-legacy.json').write_text('{"verb":"deploy","reason":"private slow predecessor"}')
# Two malformed files within one second must retain distinct raw evidence.
(box/'requests/bad-one.json').write_bytes(b'{broken one')
(box/'requests/bad-two.json').write_bytes(b'{broken two')
results=[]
try:
 for passno in range(2):
  stop=box/'stop'
  if stop.exists():stop.unlink()
  stdout=open(root/f'watch-{passno}.stdout','wb');stderr=open(root/f'watch-{passno}.stderr','wb')
  job=k.CreateJobObjectW(None,None);assert job,ctypes.get_last_error()
  child=subprocess.Popen([a.sentinel,'watch'],cwd=root,env=env,stdout=stdout,stderr=stderr)
  assert k.AssignProcessToJobObject(job,wintypes.HANDLE(child._handle)),ctypes.get_last_error()
  start=time.monotonic();durations=[]
  try:
   for req in requests:
    ack=box/'deploy-protocol'/req['id']/'ack.json'
    while not ack.exists() and time.monotonic()-start<5:time.sleep(.005)
    assert ack.exists(),f'ack absent at5sec {req["id"]}'
    durations.append(time.monotonic()-start)
   if passno==0:
    originals={req['id']:(box/'deploy-protocol'/req['id']/'intent.json').read_bytes() for req in requests}
    acks={req['id']:(box/'deploy-protocol'/req['id']/'ack.json').read_bytes() for req in requests}
   else:
    deadline=time.monotonic()+12
    while not list((box/'intake-problems').glob('*/latest.json')) and time.monotonic()<deadline:time.sleep(.02)
    problems=[json.loads(f.read_text()) for f in (box/'intake-problems').glob('*/latest.json')]
    assert any('immutable_intent_mismatch' in item['detail'] for item in problems),problems
    for req in requests:
     assert (box/'deploy-protocol'/req['id']/'intent.json').read_bytes()==originals[req['id']]
     assert (box/'deploy-protocol'/req['id']/'ack.json').read_bytes()==acks[req['id']]
   results.append({'pass':passno,'pid':child.pid,'ack_monotonic_seconds':durations})
  finally:
   stop.write_text('private graceful stop')
   try:code=child.wait(timeout=15)
   except subprocess.TimeoutExpired:
    assert k.TerminateJobObject(job,99),ctypes.get_last_error();code=child.wait(timeout=5)
    raise AssertionError('watcher needed forced cleanup; evidence retained')
   accounting=Accounting();assert k.QueryInformationJobObject(job,1,ctypes.byref(accounting),ctypes.sizeof(accounting),None),ctypes.get_last_error()
   assert accounting.active==0,f'owned tree not drained: {accounting.active}'
   assert code==0,code
   k.CloseHandle(job);stdout.close();stderr.close()
  if passno==0:
   changed=dict(requests[3]);changed['session']='victim';changed['expected_sha']='b'*40
   (box/'requests/private-3.json').write_text(json.dumps(changed))
 assert not list((box/'claimed').glob('*.json')),'no effect claims permitted'
 assert not list((box/'deploy-protocol').glob('*/result.json')),'no install result permitted'
 malformed=list((box/'intake-problems').glob('malformed-*.json'))
 assert len(malformed)>=2,'collision-safe malformed journal absent'
 raw=[json.loads(f.read_text()).get('raw_bytes') for f in malformed]
 assert list(b'{broken one') in raw and list(b'{broken two') in raw,raw
 (root/'result.json').write_text(json.dumps({'ok':True,'passes':results,'owned_tree_drained':True,'provider_calls':0,'skips':0},indent=2))
 print(json.dumps({'ok':True,'evidence':str(root),'passes':results}))
finally:s.shutdown();t.join();s.server_close()
