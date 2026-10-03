import os,pathlib,subprocess,json,time
repo=pathlib.Path(__file__).resolve().parents[1];root=repo.parent/'intake-final-probes';root.mkdir(exist_ok=False);binary=repo/'rust/wa-sentinel/target/debug/wa-sentinel.exe'
env={k:v for k,v in os.environ.items() if k.upper() in {'PATH','SYSTEMROOT','WINDIR','COMSPEC','TEMP','TMP','PATHEXT','SYSTEMDRIVE','LOCALAPPDATA'}};env.update(WASM_AGENT_HOME=str(root),WA_INSTALL_DIR=str(root/'install'),WASM_AGENT_PORT='65430',WA_SENTINEL_DEPLOY=str(root/'absent.sh'),WA_SENTINEL_SUPERVISOR='none',WASM_AGENT_IN_TURN='1')
box=root/'.wasm-agent/sentinel';q=box/'requests';q.mkdir(parents=True)
base=dict(verb='deploy',id='reserved',expected_sha='a'*40,session='parent',owner='original-owner',queued_at=int(time.time()),prompt='verify',reason='private');f=q/'reserved.json'
def once():
 r=subprocess.run([str(binary),'once'],env=env,cwd=root,capture_output=True,timeout=20);assert r.returncode==0,r.stderr;return r
f.write_text(json.dumps(base));once();d=box/'deploy-protocol/reserved';intent=(d/'intent.json').read_bytes();ack=(d/'ack.json').read_bytes();results=[]
cases=[('removal',dict(base)),('null',{**base,'expected_sha':None}),('number',{**base,'expected_sha':42}),('false',{**base,'expected_sha':False}),('verb',{**base,'verb':'upgrade'}),('owner',{**base,'owner':'other'}),('parent',{**base,'session':'victim'})];del cases[0][1]['expected_sha']
for name,req in cases:
 f.write_text(json.dumps(req));r=once();r=once();problem=json.loads(next((box/'intake-problems').glob('*/latest.json')).read_text());assert problem['detail']=='immutable_intent_mismatch',problem
 assert f.exists() and (d/'intent.json').read_bytes()==intent and (d/'ack.json').read_bytes()==ack
 for folder in ['claimed','done','failed']:assert not (box/folder/'reserved.json').exists()
 results.append({'case':name,'detail':problem['detail'],'original_bytes_preserved':True,'pending':True})
# genuinely unreserved legacy enters ordinary dispatch, named absent private resolver (no effect).
(q/'legacy.json').write_text(json.dumps({'verb':'deploy','reason':'unreserved private'}));r=once();legacy=json.loads((box/'failed/legacy.json').read_text());assert 'absent.sh' in legacy['detail']
(root/'results.json').write_text(json.dumps({'held_cases':results,'unreserved_legacy':legacy},indent=2));print((root/'results.json').read_text())
