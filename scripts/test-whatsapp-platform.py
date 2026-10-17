"""Private synthetic bundles and mocked host identity only; no real service installation."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

ROOT=Path(__file__).resolve().parent.parent
spec=importlib.util.spec_from_file_location('installer',ROOT/'scripts/whatsapp-install.py')
i=importlib.util.module_from_spec(spec);spec.loader.exec_module(i)

class ArchitectureAdmissionTests(unittest.TestCase):
    def fixture(self,root,arch='arm64',schema=3):
        b=root/'bundle';b.mkdir()
        h=bytearray(64);h[:7]=b'\x7fELF\x02\x01\x01';h[16:18]=(2).to_bytes(2,'little');h[18:20]=(183 if arch=='arm64' else 62).to_bytes(2,'little');h[20:24]=(1).to_bytes(4,'little');h[52:54]=(64).to_bytes(2,'little')
        for n in ['wa-whatsapp','whatsapp-stt-local.py','whatsapp-install.py','THIRD-PARTY-NOTICES.txt','LICENSE']:(b/n).write_bytes(h if n=='wa-whatsapp' else b'synthetic private member')
        files={p.name:i.digest(p) for p in b.iterdir()}
        inputs={n:'0'*64 for n in ['connectors/whatsapp/go.mod','connectors/whatsapp/go.sum','scripts/whatsapp-build.py','scripts/build-whatsapp.sh']}
        for src,n in [('scripts/whatsapp-stt-local.py','whatsapp-stt-local.py'),('scripts/whatsapp-install.py','whatsapp-install.py'),('connectors/whatsapp/THIRD-PARTY-NOTICES.txt','THIRD-PARTY-NOTICES.txt'),('LICENSE','LICENSE')]:inputs[src]=files[n]
        m={'schema':schema,'platform':'linux-'+arch,'source':'b'*40,'tree':'a'*40,'source_files':inputs,'source_binding':'frozen-git-archive+pre-post-hashes','go_version':'go1.27.2','go_executable_sha256':'0'*64,'files':files}
        if schema==3:m['target']=i.binary_target(b/'wa-whatsapp')
        (b/'manifest.json').write_text(json.dumps(m));return b,m
    def save(self,b,m):
        (b/'manifest.json').write_text(json.dumps(m));return i.digest(b/'manifest.json')
    def install(self,b,root,apply=False):
        return i.install(b,i.digest(b/'manifest.json'),root/'prefix',root/'state',root/'python',root/'models',apply)
    def test_matching_arm64_and_amd64_dry_runs_and_legacy_schema2(self):
        for arch,host,schema in [('arm64','aarch64',3),('amd64','x86_64',3),('amd64','x86_64',2)]:
            with self.subTest(arch=arch,schema=schema),tempfile.TemporaryDirectory() as d:
                r=Path(d);b,m=self.fixture(r,arch,schema)
                with mock.patch.object(i.sys,'platform','linux'),mock.patch.object(i.platform,'machine',return_value=host):out=self.install(b,r)
                self.assertTrue(out['host_admitted']);self.assertTrue(out['dry_run']);self.assertEqual(out['target']['goarch'],arch)
                self.assertFalse((r/'prefix').exists());self.assertFalse((r/'state').exists())
    def test_wrong_cpu_os_and_unsupported_host_refuse_before_any_copy_or_mkdir(self):
        for osname,host in [('linux','x86_64'),('win32','aarch64'),('darwin','arm64'),('linux','riscv64')]:
            for apply in [False,True]:
                with self.subTest(os=osname,host=host,apply=apply),tempfile.TemporaryDirectory() as d:
                    r=Path(d);b,m=self.fixture(r)
                    with mock.patch.object(i.sys,'platform',osname),mock.patch.object(i.platform,'machine',return_value=host),mock.patch.object(i.shutil,'copyfile') as copy:
                        with self.assertRaisesRegex(ValueError,'host_target_mismatch'):self.install(b,r,apply)
                        copy.assert_not_called()
                    self.assertFalse((r/'prefix').exists());self.assertFalse((r/'state').exists())
    def test_relabelled_amd64_manifest_cannot_admit_arm64_even_with_new_digest(self):
        with tempfile.TemporaryDirectory() as d:
            r=Path(d);b,m=self.fixture(r,'amd64');m['platform']='linux-arm64';m['target']={'goos':'linux','goarch':'arm64','elf_machine':183};self.save(b,m)
            with mock.patch.object(i.sys,'platform','linux'),mock.patch.object(i.platform,'machine',return_value='aarch64'):
                for apply in [False,True]:
                    with self.assertRaisesRegex(ValueError,'manifest_binary_architecture_mismatch'):self.install(b,r,apply)
            self.assertFalse((r/'prefix').exists())
    def test_target_disagreement_and_unsupported_schema_refuse(self):
        for change,error in [('target','manifest_target_mismatch'),('schema','source_binding_v2_or_v3_required')]:
            with tempfile.TemporaryDirectory() as d:
                r=Path(d);b,m=self.fixture(r)
                if change=='target':m['target']['elf_machine']=62
                else:m['schema']=2
                self.save(b,m)
                with self.assertRaisesRegex(ValueError,error):self.install(b,r)
    def test_malformed_and_unsupported_elf_refuse_without_execution(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/'binary'
            for h in [b'MZ'+bytes(62),b'\x7fELF'+bytes(60),b'\x7fELF\x01\x01\x01'+bytes(57)]:
                p.write_bytes(h)
                with self.assertRaisesRegex(ValueError,'supported_elf64'):i.binary_target(p)
            b,m=self.fixture(Path(d));h=bytearray((b/'wa-whatsapp').read_bytes());h[18:20]=(243).to_bytes(2,'little');p.write_bytes(h)
            with self.assertRaisesRegex(ValueError,'unsupported_binary_architecture'):i.binary_target(p)
    def test_private_mocked_linux_apply_preserves_state_and_refuses_overwrite(self):
        with tempfile.TemporaryDirectory() as d:
            r=Path(d);b,m=self.fixture(r);state=r/'state';state.mkdir();(state/'unknown').write_text('held')
            with mock.patch.object(i.sys,'platform','linux'),mock.patch.object(i.platform,'machine',return_value='aarch64'):
                out=self.install(b,r,True);release=Path(out['release'])
                self.assertFalse(out['service_registered']);self.assertTrue((release/'wa-whatsapp.service').is_file());self.assertEqual((state/'unknown').read_text(),'held')
                with self.assertRaisesRegex(ValueError,'existing_release_preserved'):self.install(b,r,True)

if __name__=='__main__':unittest.main()
