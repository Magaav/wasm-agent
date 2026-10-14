#!/usr/bin/env python3
"""Offline trace adapters. Private raw records stay private; reports contain no prompts."""
import glob
import json
import pathlib
import sqlite3
import subprocess
import sys

ADAPTER = pathlib.Path(__file__).with_name('agent-benchmark-observe.mjs')


def adapt(kind, raw):
    result = subprocess.run(['node', str(ADAPTER), kind, '-'], input=raw,
                            text=True, encoding='utf-8', capture_output=True, timeout=120)
    if result.returncode:
        raise ValueError('trace adapter refused: ' + result.stderr)
    return json.loads(result.stdout)


def pi_trace(root):
    files = glob.glob(str(root / 'pi' / 'session' / '*.jsonl'))
    if len(files) != 1:
        raise ValueError(f'expected one Pi session, found {len(files)}')
    return adapt('pi', pathlib.Path(files[0]).read_text(encoding='utf-8'))


def wasm_trace(root, label='wasm'):
    db = root / label / 'wa.db'
    connection = sqlite3.connect(f'file:{db.as_posix()}?mode=ro', uri=True)
    connection.row_factory = sqlite3.Row
    try:
        # All kinds/phases, not just successful final model ends: summaries, failures,
        # orphan/pending starts and tool/run boundaries are validated by the auditor.
        rows = [dict(row) for row in connection.execute(
            'SELECT id,session_id,run_id,span_id,seq,kind,phase,at,payload FROM harness_events ORDER BY seq')]
    finally:
        connection.close()
    return adapt('native', json.dumps({'events': rows, 'has_more': False}))


def hypothetical_cost(accounting, rates):
    fields = ('uncached_input', 'cache_read', 'cache_write', 'output')
    if not all(accounting.get(k) is not None and isinstance(rates.get(k), (int, float))
               and rates[k] >= 0 for k in fields):
        return None
    return sum(accounting[k] * rates[k] for k in fields) / 1_000_000


def main():
    if len(sys.argv) != 3:
        raise SystemExit('usage: agent-benchmark-report.py <trace-dir> <fixture.json>')
    root = pathlib.Path(sys.argv[1]).resolve()
    fixture = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding='utf-8'))
    run = json.loads((root / 'report.json').read_text(encoding='utf-8'))
    arms = {}
    for name, receipt in run.get('arms', {}).items():
        arm = pi_trace(root) if name == 'pi' else wasm_trace(root, name)
        passed = receipt.get('oracle', {}).get('pass')
        timed_out = receipt.get('timedOut')
        normal_exit = timed_out is False and receipt.get('exit') == 0
        arm.update({'oraclePass': passed, 'timedOut': timed_out,
                    'finish': 'normal-process-exit' if normal_exit else
                              'oracle-pass-at-timeout' if timed_out is True and passed is True else 'incomplete',
                    'deliverableFinished': receipt.get('handoffVerified'),
                    'elapsedMs': receipt.get('elapsedMs'), 'patchBytes': receipt.get('patchBytes'),
                    'hypotheticalReferenceCostUsd': hypothetical_cost(
                        arm['accounting'], fixture.get('referenceRatesUsdPerMillion') or {}),
                    'referenceCostIsActualBilling': False,
                    'pins': receipt.get('pins'),
                    'quality': {'scores': None, 'notes': [], 'evidence': [], 'subjective': True,
                                'rubric': {'correctness': 35, 'completeness': 25, 'safety_scope': 20,
                                           'verification': 15, 'clarity': 5}}})
        arms[name] = arm
    print(json.dumps({'fixture': run.get('fixture'), 'source': run.get('source'),
                      'model': run.get('model'), 'controls': run.get('controls'),
                      'cleanup': run.get('cleanup'), 'arms': arms}, indent=2))


if __name__ == '__main__':
    main()
