"""Actual vault handler with synthetic credentials and a fixed local fake provider only.
Never points at an installed vault/store or exposes the admin listener.
"""
import importlib.util
import json
import os
import sys
import time
import urllib.parse

source, data, upstream = sys.argv[1:]
u = urllib.parse.urlsplit(upstream)
assert u.scheme == "http" and u.hostname == "127.0.0.1" and u.path == "" and not u.query
assert os.path.isabs(data) and not os.path.exists(data)
os.mkdir(data)
os.environ.update(WA_VAULT_DATA=data, WA_VAULT_CHATGPT_BASE=upstream,
                  WA_VAULT_BIND="127.0.0.1", WA_VAULT_UPSTREAM_TIMEOUT="3")
spec = importlib.util.spec_from_file_location("benchmark_actual_vault", source)
vault = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vault)
vault.update_store(lambda store: store.update({"openai-sub": {
    "access": "BENCHMARK_SYNTHETIC_ACCESS_ONLY", "refresh": "BENCHMARK_SYNTHETIC_REFRESH_ONLY",
    "account_id": "benchmark-synthetic-account", "expires": int(time.time() * 1000) + 3600000,
    "enabled": True}}))
server = vault.serve(0, vault.ProxyHandler, "benchmark-proxy", "127.0.0.1")
print(json.dumps({"port": server.server_port, "synthetic_only": True}), flush=True)
server.serve_forever()
