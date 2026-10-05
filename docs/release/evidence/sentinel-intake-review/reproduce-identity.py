import os,pathlib,subprocess,json,time
repo=pathlib.Path(__file__).resolve().parents[1];root=repo.parent/'intake-review-probes';root.mkdir(exist_ok=False);binary=repo/'rust/wa-sentinel/target/debug/wa-sentinel.exe'
env={k:v for k,v in os.environ.items() if k.upper() in {'PATH','SYSTEMROOT','WINDIR','COMSPEC','TEMP','TMP','PATHEXT','SYSTEMDRIVE','LOCALAPPDATA'}};env.update(WASM_AGENT_HOME=str(root),WA_INSTALL_DIR=str(root/'install'),WASM_AGENT_PORT='65430',WA_SENTINEL_DEPLOY=str(root/'absent.sh'),WA_SENTINEL_SUPERVISOR='none',WASM_AGENT_IN_TURN='1')
box=root/'.wasm-agent/sentinel';q=box/'requests';q.mkdir(parents=True)
base=dict(verb='deploy',id='reserved',expected_sha='a'*40,session='parent',owner='original-owner',queued_at=int(time.time()),prompt='verify',reason='private')
f=q/'reserved.json'
def once():
 r=subprocess.run([str(binary),'once'],env=env,cwd=root,capture_output=True,timeout=20);assert r.returncode==0,r.stderr;return r
f.write_text(json.dumps(base));once();d=box/'deploy-protocol/reserved';intent=(d/'intent.json').read_bytes();ack=(d/'ack.json').read_bytes();results=[]
for key,value in [('session','victim'),('owner','changed-owner'),('expected_sha','b'*40),('prompt','changed'),('reason','changed'),('queued_at',base['queued_at']-1),('verb','run')]:
 req={**base,key:value};f.write_text(json.dumps(req));once();problems=list((box/'intake-problems').glob('*/latest.json'));results.append({'field':key,'details':[json.loads(p.read_text())['detail'] for p in problems]});assert (d/'intent.json').read_bytes()==intent and (d/'ack.json').read_bytes()==ack
# Field removal should not make a reserved protocol identity a legacy action.
req=dict(base);del req['expected_sha'];f.write_text(json.dumps(req));r=once();results.append({'field':'removed_expected_sha','pending':f.exists(),'failed_record':json.loads((box/'failed/reserved.json').read_text()) if (box/'failed/reserved.json').exists() else None,'stdout':r.stdout.decode()})
(root/'results.json').write_text(json.dumps(results,indent=2));print(json.dumps(results,indent=2))
