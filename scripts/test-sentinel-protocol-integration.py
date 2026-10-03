"""Private CLI/Engine integration. No deploy child is dispatched: busy health fixture.
All artifacts retained. Environment allowlisted, bounded foreground CLI calls only.
"""
import argparse, http.server, json, os, pathlib, subprocess, threading, time
p=argparse.ArgumentParser();p.add_argument('--sentinel',required=True);p.add_argument('--evidence',required=True);a=p.parse_args()
root=pathlib.Path(a.evidence).resolve();root.mkdir(parents=True,exist_ok=False)
env={k:v for k,v in os.environ.items() if k.upper() in {'PATH','SYSTEMROOT','WINDIR','COMSPEC','TEMP','TMP','PATHEXT','SYSTEMDRIVE','LOCALAPPDATA'}}
class Busy(http.server.BaseHTTPRequestHandler):
 def do_GET(self):
  body=b'{"ok":true,"current":{"label":"busy"},"queue":1,"operation_overdue":false,"workers":[],"subagents":{"active":0,"queued":0,"running":0}}'
  self.send_response(200);self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
 def log_message(self,*args):pass
s=http.server.HTTPServer(('127.0.0.1',0),Busy);threading.Thread(target=s.serve_forever,daemon=True).start()
env.update(WASM_AGENT_HOME=str(root),WA_INSTALL_DIR=str(root/'install'),WASM_AGENT_PORT=str(s.server_port),WASM_AGENT_IN_TURN='1',WA_SENTINEL_SUPERVISOR='none')
seq=0
def run(*args):
 global seq
 seq+=1;r=subprocess.run([a.sentinel,*args],cwd=root,env=env,capture_output=True,timeout=15)
 (root/f'{seq}.stdout').write_bytes(r.stdout);(root/f'{seq}.stderr').write_bytes(r.stderr)
 assert r.returncode==0,(args,r.stdout,r.stderr)
 return r.stdout.decode()
try:
 repo=pathlib.Path(__file__).resolve().parent.parent
 for name in ['on-sentinel-return','sentinel-return-observe']:
  definition=json.loads((repo/'jobs'/f'{name}.json').read_text());definition['action']['script']=str(repo/'scripts/sentinel-return-observe.sh') if name.endswith('observe') else definition['action'].get('script')
  if name=='on-sentinel-return':definition['action'].pop('script',None);definition['action']['prepare']['script']=str(repo/'scripts/sentinel-return-prepare.sh')
  file=root/f'{name}.json';file.write_text(json.dumps(definition));run('job','put',str(file))
 jobs=json.loads(run('job','list'));assert 'onSentinelReturn' in json.dumps(jobs)
 assert '"enabled": true' not in json.dumps(jobs)
 run('request','deploy','--expected-sha','a'*40,'--session','parent','--prompt','verify','--reason','private busy')
 box=root/'.wasm-agent/sentinel';intent=next((box/'deploy-protocol').glob('*/intent.json'));start=time.monotonic()
 run('once');assert time.monotonic()-start<5
 ack=json.loads((intent.parent/'ack.json').read_text());state=json.loads((intent.parent/'state.json').read_text())
 assert ack['phase']=='accepted' and state['phase']=='held'
 assert not (intent.parent/'result.json').exists()
 before=(intent.parent/'ack.json').read_bytes();run('once');assert before==(intent.parent/'ack.json').read_bytes()
 assert list((box/'requests').glob('*.json')) and not list((box/'done').glob('*.json'))
 (root/'result.json').write_text(json.dumps({'ok':True,'busy_ack_seconds':time.monotonic()-start,'jobs_installed_disabled':True,'no_deploy_dispatched':True,'provider_calls':0,'skips':0},indent=2))
 print(json.dumps({'ok':True,'evidence':str(root)}))
finally:s.shutdown()
