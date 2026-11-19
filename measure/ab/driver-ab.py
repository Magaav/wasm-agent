#!/usr/bin/env python3
"""The 90-run A/B driver (next-round.md 19/11 ~17:30).

6 arms x 5 tasks x 3 runs, interleaved (A,B,C,D,E2,E3,A,...), at most 3 at once, one fresh scratch
home and session per run. Every recorded field comes from the node itself - the run journal and the
provider usage rows - never from the model's own words. A row that cannot be read is reported, not
fabricated.

The tasks, their fixtures and their success criteria are the ones already written and committed for
this mission (measure/ab/). Nothing here decides a verdict; it only records what happened.
"""
import json, os, re, shutil, subprocess, sys, tempfile, time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

WT = Path('/home/victor/Work/missions/codeact-agnostic/wt')
BIN = Path('/home/victor/wasm-agent/target/m-codeact-agnostic/release/wa')
AB = Path('/home/victor/Work/missions/ab-actions')
MISSION = Path('/home/victor/Work/missions/codeact-agnostic')
OUT = MISSION / 'ab' / 'runs.jsonl'
SCRATCH = Path('/home/victor/ab-scratch')

ARMS = [
    ('A',  'only',     {}),
    ('B',  'native',   {}),
    ('C',  'codemode', {}),
    ('D',  'bash',     {}),
    ('E2', 'e2',       {}),
    ('E3', 'e3',       {}),
]

TASKS = ['t1', 't2', 't3', 't4', 't5']
RUNS = [1, 2, 3]

# The task texts are the mission's own, unchanged. The two tasks whose data is personal carry it as
# the mission's read-only SNAPSHOT (rule 13: never the live fleet) - and a snapshot is only usable if
# the task names where it is, so the one added line below says exactly that and nothing more. It is
# recorded as a deviation in the report: the sentences "the fleet exposes a mail connector" are kept
# verbatim, and the file in the directory is the connection that stands in for it.
SNAPSHOT_NOTE = {
    't1': ('\n\nThe mailbox data for this task is in this directory as mail-snapshot.json '
           '(a read-only copy of what the connector returned). Read it from there; do not send anything.'),
    't2': ('\n\nThe chat data for this task is in this directory as whatsapp-snapshot.json '
           '(a read-only copy of what the connector returned). Read it from there; do not send anything.'),
}


def task_text(task):
    text = (AB / 'wt' / 'measure' / 'ab' / 'tasks' / (task + '.txt')).read_text()
    note = SNAPSHOT_NOTE.get(task)
    return text + note if note else text


def fixtures_for(task):
    """The files a task needs in its working directory (read-only copies)."""
    src = AB / 'wt' / 'measure' / 'ab' / 'fixtures'
    out = []
    if task == 't4':
        out.append(src / 'orders.csv')
    if task == 't5':
        out.append(src / 't5' / 'app.js')
    if task == 't1':
        # Rule (13): the read-only mail data comes from the mission's own snapshot, never a live
        # connector. It is placed in the task directory so the task is answerable offline and the
        # same bytes reach every arm.
        out.append(AB / 'data' / 'mail-snapshot.json')
    if task == 't2':
        out.append(AB / 'data' / 'whatsapp-snapshot.json')
    return out

def criterion(task, cwd, answer, journal):
    """The success criterion, mechanical and decided before the run (criteria doc, 2026-11-18).
    Returns (success, note). Never guesses: an unreadable answer is a failure with its cause."""
    ans = answer or ''
    if task == 't1':
        sender = re.findall(r'^SENDER=(\S+@\S+)\s*$', ans, re.M)
        subject = re.findall(r'^SUBJECT=(.+)$', ans, re.M)
        ok = bool(sender) and bool(subject)
        return ok, 'SENDER/SUBJECT lines present' if ok else 'missing SENDER= or SUBJECT='
    if task == 't2':
        last = re.findall(r'^LAST=([^|]+)\|(.+)$', ans, re.M)
        ok = bool(last) and len(last[0][1].strip()) >= 10
        return ok, 'LAST line present' if ok else 'missing or short LAST='
    if task == 't3':
        repos = set(re.findall(r'https://github\.com/[\w.-]+/[\w.-]+', ans))
        ranked = len(re.findall(r'^\s*[123][.)]\s', ans, re.M)) >= 3
        ok = len(repos) >= 3 and ranked
        return ok, f'{len(repos)} distinct repos, ranked={ranked}'
    if task == 't4':
        expected = json.loads((AB / 'wt' / 'measure' / 'ab' / 'fixtures' / 'expected.json').read_text())
        total = re.findall(r'^TOTAL=([\d.]+)\s*$', ans, re.M)
        top5 = re.findall(r'^TOP5=(.+)$', ans, re.M)
        if not total or not top5:
            return False, 'missing TOTAL= or TOP5='
        try:
            ok_total = abs(float(total[0]) - float(expected['total'])) <= 0.01
        except ValueError:
            return False, 'TOTAL is not a number'
        # The criterion is about the VALUES, not the markup around them: the model may write
        # `name:123.45`, `name=123.45)` or `| name | 123.45 |`. A number is read wherever it sits
        # beside the product name, and a pair that cannot be read is a failure with its cause -
        # never a crash that loses the row (measured: one unreadable pair killed the whole smoke).
        pairs = {}
        for item in top5[0].split('|'):
            numbers = re.findall(r'-?\d+(?:\.\d+)?', item)
            if not numbers:
                continue
            # The name is what is LEFT once the trailing number is removed. Splitting on a
            # separator would cut a hyphenated product name in half (balanca-digital became
            # balanca), and that is a real product id in this fixture.
            trimmed = item.strip().rstrip(' )].,;')
            name = re.sub(r'\s*-?\s*' + re.escape(numbers[-1]) + r'\s*$', '', trimmed).strip()
            name = name.strip(' `*_()[]|=:-,')  # type: ignore[assignment]
            if name:
                pairs[name] = numbers[-1]
        want = [(n, v) for n, v in expected['top5'][:5]]
        try:
            ok_top = all(k in pairs and abs(float(pairs[k]) - float(v)) <= 0.01 for k, v in want)
        except (TypeError, ValueError):
            return False, 'TOP5 pair could not be read as a number'

        return ok_total and ok_top, f'total_ok={ok_total} top5_ok={ok_top}'
    if task == 't5':
        expected = (AB / 'wt' / 'measure' / 'ab' / 'fixtures' / 't5' / 'app.expected.js').read_text()
        actual_path = cwd / 'app.js'
        if not actual_path.exists():
            return False, 'app.js is gone'
        same = actual_path.read_text() == expected
        return same, 'byte-identical to expected' if same else 'differs from app.expected.js'
    return False, 'no criterion for this task'

def read_rows(home):
    """Rounds, tool calls, tokens and the run's own facts, from the node's journal.

    The node records a turn in `messages` (role, content, tool_calls) and a model call in
    `harness_events` (kind=model_call, phase=end, whose payload carries the provider usage). Nothing
    here reads the model's own words for a number: the numbers are the node's.
    """
    db = home / '.wasm-agent' / 'memory.db'
    facts = {'rounds': 0, 'tool_calls': 0, 'in_tokens': 0, 'out_tokens': 0, 'cache_read': 0,
             'silent_death': 0, 'continues': 0, 'failed_calls': 0, 'escaping_errors': 0,
             'premature_ending': 0, 'answer': '', 'session': '', 'tool_names': []}
    if not db.exists():
        return facts
    import sqlite3
    try:
        con = sqlite3.connect(f'file:{db}?mode=ro', uri=True)
        con.row_factory = sqlite3.Row
        tables = {r[0] for r in con.execute("select name from sqlite_master where type='table'")}
        if 'messages' in tables:
            for row in con.execute('select session_id, role, content, tool_calls, phase, seq from messages order by seq'):
                facts['session'] = row['session_id'] or facts['session']
                if row['role'] == 'assistant':
                    calls = []
                    try:
                        calls = json.loads(row['tool_calls'] or '[]')
                    except Exception:
                        calls = []
                    for call in calls:
                        fn = (call or {}).get('function') or {}
                        facts['tool_calls'] += 1
                        facts['tool_names'].append(fn.get('name') or '')
                    # The turn's answer, per transport (ab-fix.md): a text arm ends in its own
                    # finish shape, and the tags are stripped before the criterion reads it.
                    content = row['content'] or ''
                    if not calls and content.strip():
                        facts['answer'] = content
                        facts['answer_seq'] = row['seq']
                if row['role'] == 'tool':
                    facts['executed'] = facts.get('executed', 0) + 1
                    text = row['content'] or ''
                    if text.lstrip().startswith('{') or '"error"' in text[:200]:
                        facts['failed_calls'] += 1
        if 'harness_events' in tables:
            for row in con.execute("select payload from harness_events where kind='model_call' and phase='end'"):
                facts['rounds'] += 1
                try:
                    data = json.loads(row['payload'] or '{}')
                except Exception:
                    data = {}
                # The node's normalized usage: input/output/cacheRead, already merged from the
                # provider's own spelling, so this reads one shape and not three.
                usage = data.get('normalized') or {}
                facts['in_tokens'] += int(usage.get('input') or 0)
                facts['out_tokens'] += int(usage.get('output') or 0)
                facts['cache_read'] += int(usage.get('cacheRead') or 0)
            for row in con.execute("select payload from harness_events where kind='step' and phase='refused'"):
                facts['continues'] += 1
        con.close()
    except Exception as exc:
        facts['journal_error'] = str(exc)[:200]
    return facts

def run_one(arm, value, task, run):
    work = SCRATCH / f'{arm}-{task}-r{run}'
    if work.exists():
        shutil.rmtree(work)
    cwd = work / 'cwd'
    home = work / 'home'
    cwd.mkdir(parents=True, exist_ok=True)
    home.mkdir(parents=True, exist_ok=True)
    for path in fixtures_for(task):
        shutil.copy(path, cwd / path.name)
    env = {k: v for k, v in os.environ.items() if not k.startswith(('WASM_AGENT_', 'WA_'))}
    env.update({
        'WASM_AGENT_HOME': str(home),
        'WASM_AGENT_LUA_ROOT': str(WT),
        'WASM_AGENT_RAW_CODE': value,
        'WASM_AGENT_VAULT_URL': 'http://127.0.0.1:8810',
        'GATE_ROOT': str(SCRATCH),
        # The arms that run a script need code mode and its pinned assets; the fence, run and tag
        # arms all execute through the sandbox, and arm C is code mode itself.
        'WASM_AGENT_CODEMODE': 'native',
        'WASM_AGENT_CODEMODE_ASSETS': '/home/victor/Work/missions/codeact-fix/codemode-assets',
        'HOME': str(home),
    })
    started = time.time()
    proc = subprocess.run(
        [str(BIN), 'chat', '--once', task_text(task)],
        cwd=str(cwd), env=env, capture_output=True, text=True, timeout=1800,
    )
    wall = round(time.time() - started, 1)
    facts = read_rows(home)
    answer = facts.get('answer', '')
    # A text arm's answer is its finish SHAPE, and its tags are stripped before grading
    # (ab-fix.md): the criterion reads what the model said, not the markup it said it in.
    # A native arm finishes when its last assistant message carried no tool call - that IS its final
    # answer shape. The text arms finish in their own tags, judged below.
    final_shape = bool(answer.strip())
    if value in ('e2', 'e3'):
        finish = re.search(r'<final_message>(.*?)</final_message>', answer, re.S) if value == 'e3' else None
        if finish:
            final_shape = True
            answer = finish.group(1)
        else:
            # E2 finishes with a <message> that carries no <codeact>; E3 only with <final_message>.
            blocks = re.findall(r'<codeact>(.*?)</codeact>', answer, re.S)
            msgs = re.findall(r'<message>(.*?)</message>', answer, re.S)
            if value == 'e2' and msgs and not blocks:
                final_shape = True
                answer = msgs[-1]
            elif msgs and blocks:
                # The progress text; the finish is still missing, so the shape is not final.
                answer = msgs[-1]
    answer = re.sub(r'<turn>.*?</turn>', '', answer, flags=re.S).strip()
    # A criterion that cannot read an answer is a failure with its cause, never an exception: a
    # crash loses the row and the evidence with it.
    try:
        ok, note = criterion(task, cwd, answer, facts)
    except Exception as exc:
        ok, note = False, 'criterion error: ' + str(exc)[:160]
    executed = facts.get('executed', 0)
    # A silent death is the run ENDING (rc 0) without a final answer shape while the task is not
    # done - not "zero native tool calls", which called every text arm a death (ab-fix.md).
    silent = bool(proc.returncode == 0 and not ok and not final_shape)
    premature = bool(not ok and answer.strip())
    row = {
        'arm': arm, 'task': task, 'run': run,
        'success': 1 if ok else 0, 'grade': note,
        'silent_death': int(silent),
        'premature_ending': int(premature),
        'continues': facts['continues'],
        'rounds': facts['rounds'], 'tool_calls': facts['tool_calls'],
        'executed_steps': executed, 'final_shape': int(final_shape),
        'answer_chars': len(answer),
        'input_tokens': facts['in_tokens'], 'output_tokens': facts['out_tokens'],
        # A cache READ is a share of the prompt the provider served from cache, so it is measured
        # against input+cache_read: dividing by input alone made a fully cached prompt report 369%.
        'cache_pct': (round(100.0 * facts['cache_read'] / (facts['in_tokens'] + facts['cache_read']), 1)
                      if (facts['in_tokens'] + facts['cache_read']) else 0.0),
        'cache_read_tokens': facts['cache_read'],
        'wall_s': wall, 'escaping_errors': facts['escaping_errors'],
        'failed_calls': facts['failed_calls'],
        'rc': proc.returncode,
        'session': facts.get('session', ''),
    }
    if facts.get('journal_error'):
        row['journal_error'] = facts['journal_error']
    return row

def main():
    SCRATCH.mkdir(parents=True, exist_ok=True)
    OUT.parent.mkdir(parents=True, exist_ok=True)
    done = set()
    if OUT.exists():
        for line in OUT.read_text().splitlines():
            try:
                r = json.loads(line)
                done.add((r['arm'], r['task'], r['run']))
            except Exception:
                pass
    plan = []
    for run in RUNS:
        for task in TASKS:
            for arm, value, _ in ARMS:
                if (arm, task, run) not in done:
                    plan.append((arm, value, task, run))
    print(f'{len(plan)} runs to do, {len(done)} already recorded', flush=True)
    written = 0
    with ThreadPoolExecutor(max_workers=3) as pool:
        futures = {pool.submit(run_one, a, v, t, r): (a, t, r) for a, v, t, r in plan}
        for future in futures:
            arm, task, run = futures[future]
            try:
                row = future.result()
            except Exception as exc:
                row = {'arm': arm, 'task': task, 'run': run, 'error': str(exc)[:300]}
            with OUT.open('a') as fh:
                fh.write(json.dumps(row, sort_keys=True) + '\n')
            written += 1
            print(f"{written}/{len(plan)} {row.get('arm')} {row.get('task')} r{row.get('run')} "
                  f"success={row.get('success')} rounds={row.get('rounds')} "
                  f"calls={row.get('tool_calls')} {row.get('grade', row.get('error',''))}", flush=True)
    print('done', flush=True)

if __name__ == '__main__':
    main()
