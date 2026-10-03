"""Prepare source-exact isolated install packet. NEVER executes deploy; outside root owns execution.
No inherited WA marker is removed. Refuse reuse and remote/public source.
"""
import argparse,pathlib,subprocess,json,hashlib,socket,os,tempfile
p=argparse.ArgumentParser();p.add_argument('--repo',required=True);p.add_argument('--head',required=True);p.add_argument('--packet',required=True);a=p.parse_args()
repo=pathlib.Path(a.repo).resolve();packet=pathlib.Path(a.packet).resolve()
assert packet.is_relative_to(pathlib.Path(tempfile.gettempdir()).resolve()),'packet must stay in the explicitly private temp boundary'
assert os.environ.get('WASM_AGENT_IN_TURN')!='1','outside WA execution required; marker must never be removed'
packet.mkdir(parents=True,exist_ok=False)
def git(*args):return subprocess.check_output(['git','-C',str(repo),*args],text=True).strip()
assert git('rev-parse','HEAD')==a.head and not git('status','--porcelain'),'source must be committed exact clean tip'
source=packet/'source';subprocess.run(['git','clone','--no-hardlinks','--no-checkout',str(repo),str(source)],check=True)
subprocess.run(['git','-C',str(source),'checkout','-B','main',a.head],check=True)
# Private remote main must name exact candidate, never mutate producer refs or publish.
remote=packet/'origin.git';subprocess.run(['git','clone','--bare',str(source),str(remote)],check=True)
subprocess.run(['git','-C',str(source),'remote','set-url','origin',str(remote)],check=True);subprocess.run(['git','-C',str(source),'fetch','origin'],check=True)
ports=[]
for _ in range(4):
 with socket.socket() as s:s.bind(('127.0.0.1',0));ports.append(s.getsockname()[1])
home=packet/'home';install=packet/'install';home.mkdir();install.mkdir()
request='private-install-1'
intent={'id':request,'verb':'deploy','expected_sha':a.head,'session':'private-install-parent','owner':'private-fixture-owner','queued_at':None}
(packet/'intent-template.json').write_text(json.dumps(intent,indent=2))
environment={'WASM_AGENT_HOME':str(home),'WA_INSTALL_DIR':str(install),'WA_DEPLOY_ROOT':str(source),'WA_RUNTIME_WORKTREE':str(source),'WA_PORT':str(ports[0]),'WA_CLIENT_PORT':str(ports[1]),'WASM_AGENT_PORT':str(ports[0]),'WA_SENTINEL_SUPERVISOR':'none','WA_IDLE_MAX_SECONDS':'30','CARGO_BUILD_JOBS':'2','WA_DEPLOY_REQUIRE_RELEASE_PROOF':'0','WASM_AGENT_MANAGED':'0','WASM_AGENT_RENDEZVOUS':'','WASM_AGENT_RELAY':''}
script=source/'scripts/deploy.sh';verify=source/'scripts/verify-install.sh'
receipt={'schema':1,'head':a.head,'tree':git('rev-parse','HEAD^{tree}'),'source':str(source),'private_remote':str(remote),'home':str(home),'install':str(install),'environment':environment,'deploy_script_sha256':hashlib.sha256(script.read_bytes()).hexdigest(),'verify_script_sha256':hashlib.sha256(verify.read_bytes()).hexdigest(),'commands':[['C:/Program Files/Git/bin/bash.exe',str(script),'--request-id',request,'--expected-sha',a.head,'--require-main','--reason','outside-root-owned-private-install'],['C:/Program Files/Git/bin/bash.exe',str(verify),'--json']],'constraints':['outside root starts new private process environment; do not run inside WA turn','assign suspended root to verified kill-on-close/no-breakaway Job before resume','query exact private child membership/listener/watcher and Job drain; preserve failure','do not enable hooks, windows, services or tasks','set queued_at from actual request creation; do not invent owner/session existence','verify raw result/installed records plus actual artifact hashes; no synthetic normalization']}
(packet/'packet.json').write_text(json.dumps(receipt,indent=2));print(json.dumps({'packet':str(packet/'packet.json'),'head':a.head,'tree':receipt['tree']}))
