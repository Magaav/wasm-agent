"""Private installed-sentinel proof; never deploys or touches the live request box.
The canonical script MUST retain the in-turn refusal. No marker is removed.
"""
import argparse
import hashlib
import http.server
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time

parser = argparse.ArgumentParser()
parser.add_argument('--sentinel', required=True)
parser.add_argument('--repo', required=True)
parser.add_argument('--evidence', required=True)
args = parser.parse_args()
repo = Path(args.repo).resolve()
script = repo / 'scripts/deploy.sh'
assert 'cannot deploy from a running turn' in script.read_text(), 'safety refusal absent'

class Health(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = json.dumps({'ok': True, 'current': None, 'queue': 0,
                           'operation_overdue': False, 'workers': [],
                           'subagents': {'active': 0, 'queued': 0, 'running': 0}}).encode()
        self.send_response(200)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *unused):
        pass

server = http.server.HTTPServer(('127.0.0.1', 0), Health)
threading.Thread(target=server.serve_forever, daemon=True).start()
results = []
try:
    with tempfile.TemporaryDirectory(prefix='wa-canonical-bootstrap-') as temp:
        root = Path(temp)
        for label in ('canonical', 'stale-selection'):
            home = root / label
            install = home / 'install'
            install.mkdir(parents=True)
            box = home / '.wasm-agent/sentinel'
            (box / 'requests').mkdir(parents=True)
            stale = home / 'stale.sh'
            stale.write_text("#!/bin/sh\necho STALE_SCRIPT_SELECTED\nexit 7\n")
            selected = script if label == 'canonical' else stale
            (box / 'requests/proof.json').write_text(json.dumps({
                'verb': 'deploy', 'reason': 'private canonical selection fixture'}))
            env = os.environ.copy()
            env.update(WASM_AGENT_HOME=str(home), WA_INSTALL_DIR=str(install),
                       WASM_AGENT_PORT=str(server.server_port), WA_PORT=str(server.server_port),
                       WA_SENTINEL_SUPERVISOR='none', WA_SENTINEL_DEPLOY=str(selected),
                       WA_DEPLOY_ROOT=str(repo), WASM_AGENT_IN_TURN='1')
            run = subprocess.run([args.sentinel, 'once'], env=env, cwd=home,
                                 capture_output=True, text=True, timeout=30)
            assert run.returncode == 0, (run.stdout, run.stderr)
            capture = box / 'deploy.out'
            text = ''
            expected = 'cannot deploy from a running turn' if label == 'canonical' else 'STALE_SCRIPT_SELECTED'
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                text = capture.read_text(errors='replace') if capture.exists() else ''
                if expected in text:
                    break
                time.sleep(.02)
            assert expected in text, text
            receipt = json.loads((box / 'done/proof.json').read_text())
            assert receipt['ok'] is True and 'detached' in receipt['detail'], receipt
            outcome = install / 'deploy-result.json'
            result = json.loads(outcome.read_text()) if outcome.exists() else None
            if label == 'canonical':
                assert result and result['ok'] is False and expected in result['detail'], result
            assert not (install / 'wa.exe').exists(), 'fixture installed a node unexpectedly'
            results.append({'case': label, 'receipt': receipt, 'capture': text,
                            'outcome': result, 'selected_script': str(selected)})
finally:
    server.shutdown()
proof = {'ok': True, 'sentinel': str(Path(args.sentinel).resolve()),
         'sentinel_sha256': hashlib.sha256(Path(args.sentinel).read_bytes()).hexdigest(),
         'canonical_sha256': hashlib.sha256(script.read_bytes()).hexdigest(),
         'cases': results, 'live_effects': False,
         'scope': 'installed executable in new process with private environment, not running watcher'}
Path(args.evidence).write_bytes((json.dumps(proof, indent=2) + '\n').encode('utf-8'))
print(json.dumps({'ok': True, 'cases': len(results), 'evidence': args.evidence}))
