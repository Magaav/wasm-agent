#!/usr/bin/env python3
"""Operator-only Go import. No values/hashes are printed or stored in the journal.
Run --check first. Apply never deletes a legacy key. Reconcile retires file aliases only
following exact operation/generation + effective node routing readback. Never replay sends.
"""
import argparse
import getpass
import json
import os
import pathlib
import tempfile
import urllib.request
import urllib.error
import uuid

ALIASES = ('WASM_AGENT_LLM_API_KEY', 'OPENCODE_GO_API_KEY', 'OPENAI_API_KEY')
ROUTE = 'WASM_AGENT_OPENCODE_GO_VAULT_URL'

def parse(text):
    result = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith('#') or '=' not in line:
            continue
        key, value = line.split('=', 1)
        # Matches wa-host load_env_file: first occurrence, trim, strip quote edges.
        result.setdefault(key.strip(), value.strip().strip('\"\''))
    return result

def effective(text, environ):
    values = parse(text)
    for name in ALIASES:
        if name in environ:
            return name, environ[name], 'process environment'
        if name in values:
            return name, values[name], 'env file'
    return None, None, None

def stamp(path):
    value = path.stat()
    return [value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns, value.st_ctime_ns]

def atomic(path, text):
    fd, temp = tempfile.mkstemp(prefix='.wa-migration-', dir=path.parent)
    try:
        if os.name == 'posix': os.fchmod(fd, 0o600)
        with os.fdopen(fd, 'w', encoding='utf-8', newline='\n') as handle:
            handle.write(text); handle.flush(); os.fsync(handle.fileno())
        os.replace(temp, path)
    finally:
        if os.path.exists(temp): os.unlink(temp)

def valid_url(url):
    from urllib.parse import urlsplit
    p = urlsplit(url)
    if p.username or p.password or p.query or p.fragment or p.path not in ('', '/'):
        raise ValueError('URL must be an origin without credentials/path/query/fragment')
    if p.scheme != 'https' and not (p.scheme == 'http' and p.hostname in ('127.0.0.1', 'localhost')):
        raise ValueError('HTTPS or operator loopback origin required')
    return url.rstrip('/')

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args): return None

def request(url, method='GET', body=None, token=None, session=None):
    headers = {'Content-Type': 'application/json'}
    if token: headers['X-Vault-Token'] = token
    if session: headers['X-WA-Session'] = session
    req = urllib.request.Request(url, method=method, headers=headers,
        data=None if body is None else json.dumps(body).encode())
    with urllib.request.build_opener(NoRedirect).open(req, timeout=15) as response:
        return json.load(response)

def execute(args, environ=None, token=None, node_session=None, http=request):
    environ = os.environ if environ is None else environ
    source = pathlib.Path(args.env_file).resolve()
    text = source.read_text(encoding='utf-8')
    before = stamp(source)
    name, key, owner = effective(text, environ)
    vault = valid_url(args.vault_url)
    admin = valid_url(args.admin_url) if args.admin_url else None
    journal = pathlib.Path(args.journal).resolve() if args.journal else None
    metadata = {'provider':'opencode-go', 'source_path':str(source), 'variable':name,
        'present':bool(key), 'source':owner, 'vault_route':vault, 'entitlement':'unknown'}
    full_status = http(vault + '/status')
    status = full_status['providers']['opencode-go']
    metadata['vault_id'] = full_status.get('vault_id')
    metadata.update(vault_configured=status.get('configured'), vault_enabled=status.get('enabled'))
    if args.check:
        metadata['readiness'] = 'operator apply requires isolated durable vault, private admin enrollment, confirmed Go upstream and nonsecret journal; no mutation performed'
        return metadata
    if not journal or not admin or not args.confirm_go_source:
        raise ValueError('apply/reconcile requires --journal, --admin-url and --confirm-go-source')
    if not metadata['vault_id'] or http(admin + '/identity').get('vault_id') != metadata['vault_id']:
        raise ValueError('operator/proxy vault identity mismatch; no authorization or key sent')
    if token is None: token = getpass.getpass('Vault operator admin token (not stored): ')
    def save(value): atomic(journal, json.dumps(value, indent=2) + '\n')
    if args.apply:
        if journal.exists(): raise ValueError('journal exists: reconcile; never repeat an uncertain send')
        if not key: raise ValueError('effective Go credential absent/empty')
        base = environ.get('WASM_AGENT_LLM_BASE_URL', parse(text).get('WASM_AGENT_LLM_BASE_URL',
            environ.get('WASM_AGENT_OPENAI_BASE_URL', parse(text).get('WASM_AGENT_OPENAI_BASE_URL', 'https://opencode.ai/zen/go/v1'))))
        if base.rstrip('/') != 'https://opencode.ai/zen/go/v1': raise ValueError('effective upstream is not the supported Go route; explicit operator source correction required')
        if status.get('configured'): raise ValueError('vault already configured: no implicit overwrite')
        operation = str(uuid.uuid4())
        record = dict(metadata, operation=operation, phase='sending', source_stamp=before)
        save(record)  # durable before the only external credential write
        try:
            http(admin + '/api/opencode-go/key', 'POST', {'key':key,
                'expected_generation':status['generation'], 'expected_vault_id':metadata['vault_id'], 'operation':operation}, token)
        finally:
            key = None
        # Presence alone is insufficient; read the exact operation from the operator door.
    else:
        record = json.loads(journal.read_text(encoding='utf-8'))
        if record.get('vault_id') != metadata['vault_id'] or record['source_path'] != str(source) or record['vault_route'] != vault:
            raise ValueError('journal/source/route scope mismatch')
    entry = http(admin + '/api/status', token=token)['providers']['opencode-go']
    if entry.get('operation') != record['operation'] or not entry.get('configured'):
        raise ValueError('outcome unresolved/superseded; retain env; no write replay')
    generation = entry['generation']
    if record.get('generation') and record['generation'] != generation:
        raise ValueError('credential generation changed; retain env')
    record['generation'] = generation
    if record['phase'] == 'sending':
        if stamp(source) != record['source_stamp']: raise ValueError('source changed; vault commit reconciled but source held')
        # Route only Go. Preserve global + native subscription settings; no token copy.
        lines = [line for line in text.splitlines() if line.split('=',1)[0].strip() != ROUTE]
        lines.append(ROUTE + '=' + vault)
        atomic(source, '\n'.join(lines) + '\n')
        record.update(phase='awaiting_node_route', source_stamp=stamp(source))
        save(record)
    if args.apply:
        return dict(metadata, outcome='vault generation verified; route configured; legacy entries retained', next='coordinator applies service environment/restarts idle, then --reconcile --node-url ORIGIN')
    if not args.node_url: raise ValueError('retirement needs --node-url exact effective route readback')
    node = valid_url(args.node_url)
    observed = http(node + '/provider-management', session=node_session)
    route = next((r for r in observed.get('providers',[]) if r['id']=='opencode-go'), {})
    if route.get('source') != 'vault' or route.get('vault_url') != vault or route.get('vault_id') != record['vault_id'] or route.get('generation') != generation:
        raise ValueError('node effective route/generation unverified; retain env')
    if record['phase'] == 'retired': return dict(metadata, outcome='already retired; no mutation')
    if stamp(source) != record['source_stamp']: raise ValueError('source changed since route configuration; retain env')
    # Generic OPENAI_API_KEY may serve a different provider: never retire it implicitly.
    retired = [n for n in ALIASES[:2] if n in parse(text)]
    lines = [line for line in source.read_text(encoding='utf-8').splitlines() if line.split('=',1)[0].strip() not in retired]
    if stamp(source) != record['source_stamp']: raise ValueError('concurrent source edit; retain env')
    atomic(source, '\n'.join(lines) + '\n')
    record.update(phase='retired', retired_variables=retired); save(record)
    return dict(metadata, outcome='file Go aliases retired after exact node route/generation verification',
        retained_generic_alias='OPENAI_API_KEY' in parse(text), process_env_retirement='operator must remove any service/process aliases separately')

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    for flag in ('check','apply','reconcile'): mode.add_argument('--'+flag, action='store_true')
    for flag in ('env-file','vault-url'): parser.add_argument('--'+flag, required=True)
    for flag in ('admin-url','journal','node-url'): parser.add_argument('--'+flag)
    parser.add_argument('--confirm-go-source', action='store_true')
    args = parser.parse_args()
    try:
        node_session = getpass.getpass('Node operator UI session (empty only for explicitly local operator configuration): ') if args.reconcile and args.node_url else None
        print(json.dumps(execute(args, node_session=node_session), indent=2))
    except Exception:
        # Libraries/exceptions may quote request content; never print exception text.
        print(json.dumps({'ok':False,'outcome':'held/refused; legacy configuration retained; inspect nonsecret journal and reconcile, never replay apply'}))
        return 1
    return 0

if __name__ == '__main__': raise SystemExit(main())
