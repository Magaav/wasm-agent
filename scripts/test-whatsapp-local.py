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
    def test_installer_dry_run_and_hash_refusal_preserve_state(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            bundle = root/'bundle'; bundle.mkdir()
            files = {}
            for name in ('wa-whatsapp', 'whatsapp-stt-local.py', 'whatsapp-install.py', 'THIRD-PARTY-NOTICES.txt', 'LICENSE'):
                (bundle/name).write_bytes(b'synthetic fixture, not executable')
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
        class Info:
            language = 'pt'
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
                self.assertEqual(model.calls[-1]['beam_size'], 5)
                self.assertEqual(model.calls[-1]['language'], None if language=='auto' else language)
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
class Info:
 language='pt'
class WhisperModel:
 def __init__(self,*args,**kwargs):
  assert kwargs['local_files_only'] is True
  assert kwargs['compute_type']=='int8'
  with open(os.environ['WA_FIXTURE_LOAD_MARKER'],'a') as f:f.write('load\\n')
 def transcribe(self,path,**kwargs):
  assert kwargs['task']=='transcribe' and kwargs['beam_size']==5
  return iter([Segment()]),Info()
'''
            (root/'faster_whisper.py').write_text(stub)
            env={**os.environ,'PYTHONPATH':str(root),'WA_WHATSAPP_STT_MODELS':str(root),'WA_FIXTURE_LOAD_MARKER':str(marker)}
            requests=''.join(json.dumps({'input':str(audio),'language':lang})+'\n' for lang in ('en','pt'))
            result=subprocess.run([sys.executable,str(ROOT/'scripts/whatsapp-stt-local.py'),'--worker'],input=requests,text=True,capture_output=True,env=env,timeout=10)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertTrue(all(json.loads(line)['ok'] for line in result.stdout.splitlines()))
            self.assertEqual(len(result.stdout.splitlines()),2)
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
