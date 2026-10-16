"""Private Git/fake-compiler causality checks; never installs services or real STT."""
import importlib.util
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT=Path(__file__).resolve().parent.parent
spec=importlib.util.spec_from_file_location('builder',ROOT/'scripts/whatsapp-build.py')
builder=importlib.util.module_from_spec(spec);spec.loader.exec_module(builder)

class FrozenBuildTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.go=os.environ.get('WA_TEST_GO')
        if not cls.go: raise unittest.SkipTest('WA_TEST_GO absolute private SDK required')
        cls.temp=tempfile.TemporaryDirectory();cls.base=Path(cls.temp.name)
        code=cls.base/'fake.go';code.write_text('''package main
import("fmt";"os";"path/filepath")
func main(){a:=os.Args[1:];if len(a)>0&&a[0]=="version"{fmt.Println("go version go1.27.2 fixture/amd64");return};if len(a)>0&&a[0]=="mod"{return};var out string;for i,v:=range a{if v=="-o"{out=a[i+1]}};if out==""{os.Exit(2)};os.WriteFile(out,[]byte("synthetic cross-build artifact, not executable"),0600);if marker:=os.Getenv("WA_FIXTURE_GO_CALLED");marker!=""{os.WriteFile(marker,[]byte("called"),0600)};switch os.Getenv("WA_FIXTURE_DRIFT"){case "origin":os.WriteFile(filepath.Join(os.Getenv("WA_FIXTURE_ROOT"),"scripts","whatsapp-stt-local.py"),[]byte("changed origin fixture"),0600);case "frozen":os.WriteFile("main.go",[]byte("changed frozen fixture"),0600)}}
''',encoding='utf-8')
        cls.wrapper=cls.base/('fixture-go.exe' if sys.platform=='win32' else 'fixture-go')
        env={**os.environ,'GOTOOLCHAIN':'local','GOOS':'windows' if sys.platform=='win32' else 'linux','GOARCH':'amd64'}
        subprocess.run([cls.go,'build','-o',str(cls.wrapper),str(code)],check=True,env=env,capture_output=True)
        cls.wrapper_sha=builder.digest(cls.wrapper)
    @classmethod
    def tearDownClass(cls):
        if hasattr(cls,'temp'): cls.temp.cleanup()
    def fixture(self,old=False):
        temp=tempfile.TemporaryDirectory();self.addCleanup(temp.cleanup);root=Path(temp.name)
        (root/'connectors/whatsapp').mkdir(parents=True);(root/'scripts').mkdir()
        (root/'.gitignore').write_text('target/\n')
        (root/'connectors/whatsapp/go.mod').write_text('module private.invalid/fixture\n\ngo 1.27.2\n')
        (root/'connectors/whatsapp/go.sum').write_text('')
        (root/'connectors/whatsapp/main.go').write_text('package main\nfunc main(){}\n')
        (root/'connectors/whatsapp/THIRD-PARTY-NOTICES.txt').write_text('private license fixture\n')
        shutil.copyfile(ROOT/'LICENSE',root/'LICENSE')
        for name in ('whatsapp-build.py','whatsapp-stt-local.py','whatsapp-install.py','build-whatsapp.sh'):
            shutil.copyfile(ROOT/'scripts'/name,root/'scripts'/name)
        if old:
            (root/'scripts/build-whatsapp.sh').write_bytes(subprocess.check_output(['git','show','fdc79bfc8bd78ab5e04ab3e925bb92a7dd8fffa5:scripts/build-whatsapp.sh'],cwd=ROOT))
        for args in (['init','-q'],['add','.'],['-c','user.name=Private Fixture','-c','user.email=fixture@example.invalid','commit','-qm','private fixture']):
            subprocess.run(['git',*args],cwd=root,check=True,capture_output=True)
        return root
    def invoke(self,root,drift=''):
        from unittest.mock import patch
        with patch.dict(os.environ,{'WA_FIXTURE_DRIFT':drift,'WA_FIXTURE_ROOT':str(root)}):
            return builder.build(root,str(self.wrapper),self.wrapper_sha,sys.executable)
    def test_frozen_manifest_members_and_source_binding(self):
        root=self.fixture();result=self.invoke(root);manifest=json.loads((Path(result['bundle'])/'manifest.json').read_text())
        self.assertEqual(manifest['schema'],2);self.assertEqual(manifest['source_binding'],'frozen-git-archive+pre-post-hashes')
        self.assertIn('connectors/whatsapp/go.sum',manifest['source_files'])
        self.assertEqual(manifest['source_files']['scripts/whatsapp-stt-local.py'],manifest['files']['whatsapp-stt-local.py'])
        self.assertEqual(subprocess.check_output(['git','status','--porcelain'],cwd=root).strip(),b'')
    def test_missing_interpreter_and_untrusted_sdk_refuse_before_compile(self):
        root=self.fixture();marker=self.base/'not-called';marker.unlink(missing_ok=True)
        from unittest.mock import patch
        with patch.dict(os.environ,{'WA_FIXTURE_GO_CALLED':str(marker)}):
            with self.assertRaisesRegex(ValueError,'absolute_python3_required'):
                builder.build(root,str(self.wrapper),self.wrapper_sha,str(root/'missing-python3'))
            with self.assertRaisesRegex(ValueError,'hash_required'):
                builder.build(root,str(self.wrapper),'0'*64,sys.executable)
        self.assertFalse(marker.exists())
    def test_origin_and_frozen_drift_never_emit_success_manifest(self):
        for drift in ('origin','frozen'):
            root=self.fixture()
            with self.assertRaisesRegex(ValueError,'source|committed'):
                self.invoke(root,drift)
            self.assertFalse(any((root/'target').glob('whatsapp-linux-*/manifest.json')))
    def test_old_builder_causally_emits_mixed_source_bundle(self):
        root=self.fixture(old=True)
        env={**os.environ,'GO':self.wrapper.as_posix(),'GO_SHA256':self.wrapper_sha,'WA_FIXTURE_ROOT':str(root),'WA_FIXTURE_DRIFT':'origin'}
        self.assertEqual(subprocess.check_output(['git','status','--porcelain'],cwd=root).strip(),b'')
        bash=os.environ.get('WA_TEST_BASH')
        if not bash or not Path(bash).is_absolute(): self.skipTest('explicit admitted local WA_TEST_BASH required; no runtime discovery')
        script=(root/'scripts/build-whatsapp.sh').as_posix()
        if sys.platform=='win32':
            converter=Path(bash).with_name('cygpath.exe')
            script=subprocess.check_output([str(converter),'-u',script],text=True).strip()
        run=subprocess.run([bash,'--noprofile','--norc',script],cwd=root,env=env,capture_output=True,text=True,timeout=30)
        self.assertEqual(run.returncode,0,run.stderr)
        manifests=list((root/'target').glob('whatsapp-linux-*/manifest.json'));self.assertEqual(len(manifests),1)
        manifest=json.loads(manifests[0].read_text());self.assertEqual(manifest['schema'],1)
        self.assertEqual((manifests[0].parent/'whatsapp-stt-local.py').read_text(),'changed origin fixture')
        self.assertTrue(subprocess.check_output(['git','status','--porcelain'],cwd=root).strip())

if __name__=='__main__': unittest.main()
