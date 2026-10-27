import importlib.util
import json
import os
from pathlib import Path
import tempfile
import subprocess
import sys
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent

def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

installer = load('installer', ROOT/'scripts/whatsapp-install.py')
stt = load('stt', ROOT/'scripts/whatsapp-stt-local.py')

class PrivateFixtureTests(unittest.TestCase):
    @mock.patch.object(installer.sys, 'platform', 'linux')
    @mock.patch.object(installer.platform, 'machine', return_value='x86_64')
    def test_installer_dry_run_and_hash_refusal_preserve_state(self, machine):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            bundle = root/'bundle'; bundle.mkdir()
            files = {}
            for name in ('wa-whatsapp', 'whatsapp-stt-local.py', 'whatsapp-install.py', 'THIRD-PARTY-NOTICES.txt', 'LICENSE'):
                (bundle/name).write_bytes(b'synthetic fixture, not executable')
                if name == 'wa-whatsapp':
                    h=bytearray(64);h[:7]=b'\x7fELF\x02\x01\x01';h[16:18]=(2).to_bytes(2,'little');h[18:20]=(62).to_bytes(2,'little');h[20:24]=(1).to_bytes(4,'little');h[52:54]=(64).to_bytes(2,'little');(bundle/name).write_bytes(h)
                files[name] = installer.digest(bundle/name)
            inputs={p:'0'*64 for p in ('connectors/whatsapp/go.mod','connectors/whatsapp/go.sum','scripts/whatsapp-build.py','scripts/build-whatsapp.sh')}
            for source,name in [('scripts/whatsapp-stt-local.py','whatsapp-stt-local.py'),('scripts/whatsapp-install.py','whatsapp-install.py'),('connectors/whatsapp/THIRD-PARTY-NOTICES.txt','THIRD-PARTY-NOTICES.txt'),('LICENSE','LICENSE')]: inputs[source]=files[name]
            manifest = {'schema':2, 'platform':'linux-amd64', 'tree':'a'*40, 'source':'b'*40, 'files':files,'source_files':inputs,'source_binding':'frozen-git-archive+pre-post-hashes','go_version':'go1.27.2','go_executable_sha256':'0'*64}
            path = bundle/'manifest.json'; path.write_text(json.dumps(manifest))
            state = root/'state';state.mkdir();(state/'unknown-send').write_text('preserve')
            result = installer.install(bundle, installer.digest(path), root/'prefix', state, root/'python', root/'models')
            self.assertTrue(result['dry_run']); self.assertFalse((root/'prefix').exists())
            self.assertEqual((state/'unknown-send').read_text(), 'preserve')
            with self.assertRaisesRegex(ValueError, 'absolute_install_paths'):
                installer.install(bundle, installer.digest(path), 'relative-prefix', state, root/'python', root/'models')
            # Synthetic ancestor refusal; no privileged OS symlink creation needed.
            redirected_parent = root/'prefix'/'releases'
            with mock.patch.object(Path, 'is_symlink', lambda p: p == redirected_parent):
                with self.assertRaisesRegex(ValueError, 'symlink_install_destination'):
                    installer.install(bundle, installer.digest(path), root/'prefix', state, root/'python', root/'models')
            self.assertFalse((root/'prefix').exists())
            (bundle/'wa-whatsapp').write_bytes(b'changed')
            with self.assertRaisesRegex(ValueError, 'artifact_hash'):
                installer.install(bundle, installer.digest(path), root/'prefix', state, root/'python', root/'models')
            with self.assertRaisesRegex(ValueError, 'manifest_hash'):
                installer.install(bundle, '0'*64, root/'prefix', state, root/'python', root/'models')

    def test_recognition_is_original_language_not_translation(self):
        class Segment:
            text = 'Olá, áudio original 👋'
            end = 2.5
        class Info:
            language = 'pt'
            duration = 3.0
        class Model:
            calls = []
            def transcribe(self, path, **kwargs):
                self.calls.append(kwargs)
                return iter([Segment()]), Info()
        with tempfile.TemporaryDirectory() as temp:
            path=Path(temp)/'audio';path.write_bytes(b'fixture')
            model=Model()
            for language in ('en','pt','auto'):
                result=stt.recognize(model, {'input':str(path),'language':language})
                self.assertEqual(result['transcript'], Segment.text)
                self.assertEqual(model.calls[-1]['task'], 'transcribe')
                self.assertEqual(model.calls[-1]['beam_size'], 1)  # greedy by default
                self.assertNotIn('temperature', model.calls[-1])
                self.assertEqual(model.calls[-1]['language'], None if language=='auto' else language)
            with mock.patch.dict(os.environ, {'WA_WHATSAPP_STT_BEAM': '5'}):
                stt.recognize(model, {'input':str(path),'language':'pt'})
                self.assertEqual(model.calls[-1]['beam_size'], 5)
                # Fallback tiers ignore the configured beam: greedy, no temperature
                # re-decode, then no timestamps.
                stt.recognize(model, {'input':str(path),'language':'pt','tier':1})
                self.assertEqual((model.calls[-1]['beam_size'], model.calls[-1]['temperature']), (1, 0.0))
                self.assertNotIn('without_timestamps', model.calls[-1])
                stt.recognize(model, {'input':str(path),'language':'pt','tier':2})
                self.assertTrue(model.calls[-1]['without_timestamps'])
            ticks=[]
            result=stt.recognize(model, {'input':str(path),'language':'pt'}, lambda at,duration: ticks.append((at,duration)))
            self.assertEqual(ticks, [(0.0,3.0),(2.5,3.0)])
            self.assertEqual(result['duration'], 3.0)
            with self.assertRaisesRegex(ValueError, 'translation_unsupported'):
                stt.recognize(model, {'input':str(path),'mode':'translate'})
            with self.assertRaisesRegex(ValueError, 'language_must'):
                stt.recognize(model, {'input':str(path),'language':'xx'})

    def test_actual_worker_protocol_reuses_one_offline_model(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp); marker=root/'loads'; audio=root/'audio'; audio.write_bytes(b'fixture')
            stub = '''import os
from pathlib import Path
class Segment:
 text='synthetic original-language audio'
 end=1.0
class Info:
 language='pt'
 duration=1.0
class WhisperModel:
 def __init__(self,*args,**kwargs):
  assert kwargs['local_files_only'] is True
  assert kwargs['compute_type']=='int8'
  assert kwargs['cpu_threads']==int(os.environ['WA_WHATSAPP_STT_THREADS'])
  with open(os.environ['WA_FIXTURE_LOAD_MARKER'],'a') as f:f.write('load\\n')
 def transcribe(self,path,**kwargs):
  assert kwargs['task']=='transcribe' and kwargs['beam_size']==1
  return iter([Segment()]),Info()
'''
            (root/'faster_whisper.py').write_text(stub)
            env={**os.environ,'PYTHONPATH':str(root),'WA_WHATSAPP_STT_MODELS':str(root),'WA_FIXTURE_LOAD_MARKER':str(marker),'WA_WHATSAPP_STT_THREADS':'2'}
            env.pop('WA_WHATSAPP_STT_BEAM', None)
            # No request at all: the worker still preloads its one model and says so.
            idle=subprocess.run([sys.executable,str(ROOT/'scripts/whatsapp-stt-local.py'),'--worker'],input='',text=True,capture_output=True,env=env,timeout=10)
            self.assertEqual([json.loads(line) for line in idle.stdout.splitlines()],[{'progress':True,'ready':True}])
            marker.unlink()
            requests=''.join(json.dumps({'input':str(audio),'language':lang})+'\n' for lang in ('en','pt'))
            result=subprocess.run([sys.executable,str(ROOT/'scripts/whatsapp-stt-local.py'),'--worker'],input=requests,text=True,capture_output=True,env=env,timeout=10)
            self.assertEqual(result.returncode,0,result.stderr)
            lines=[json.loads(line) for line in result.stdout.splitlines()]
            finals=[line for line in lines if not line.get('progress')]
            self.assertEqual(len(finals),2)
            self.assertTrue(all(line['ok'] for line in finals))
            # Progress lines carry timings only, never transcript text.
            self.assertTrue(all(set(line)<={'progress','ready','at','duration'} for line in lines if line.get('progress')))
            self.assertEqual(lines[0],{'progress':True,'ready':True})
            self.assertEqual(marker.read_text().splitlines(),['load'])

    def test_missing_cache_refuses_without_provider_or_download(self):
        previous=os.environ.pop('WA_WHATSAPP_STT_MODELS', None)
        try:
            with self.assertRaisesRegex(ValueError, 'MODELS_required'):
                stt.load_model()
        finally:
            if previous is not None: os.environ['WA_WHATSAPP_STT_MODELS']=previous

if __name__ == '__main__':
    unittest.main()
