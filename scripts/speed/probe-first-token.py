#!/usr/bin/env python3
"""FIRST TOKEN: Enter -> the first byte the model sends back, against a local fixture (no network).

    python3 scripts/speed/probe-first-token.py --bin <wa> --root <tree> [--samples 5]

A PTY, NOT A PIPE, and that is a measurement rather than a taste: with stdin on a pipe this binary prints
no prompt header at all (measured 23/11 on 8862b600: 4 s and no "memory:" line, while the same command in
a pty prints it in ~0.4 s), so a pipe would measure a path Victor never runs and would have no "Enter"
to speak of - the key would arrive before the prompt existed.

THE CLOCKS. The Enter is timed here (wall clock, ms). The first byte is timed by the FIXTURE, which
records the moment its first SSE chunk left (scripts/speed/fixture-model.cjs). One machine, one clock: the
row is the difference, so no side estimates the other's cost and nothing is inferred from what a terminal
happened to render.

TURNS, NOT PROCESSES. One process, one warm-up turn that is DISCARDED, then the samples: the first turn
of a fresh process pays the process's own cold state (provider client, prompt cache, first ledger write)
and would be a second cold-start row. The warm-up is a real turn whose number is thrown away.

Every read on the pty is select()-guarded and DRAINED: a full buffer would stop the process and the row
would measure the probe instead of the turn.
"""
import argparse
import json
import os
import pty
import select
import shutil
import signal
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_common as common

HERE = os.path.dirname(os.path.abspath(__file__))
READY = b"memory: "
SEEN = []


def drain(fd, timeout):
    """Read what arrives within timeout (never blocks); keep it, the header is looked for in it."""
    ready, _, _ = select.select([fd], [], [], timeout)
    if not ready:
        return False
    try:
        chunk = os.read(fd, 65536)
    except OSError:
        return False
    if not chunk:
        return False
    SEEN.append(chunk)
    return True


def saw_header(fd, timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        drain(fd, 0.2)
        if READY in b"".join(SEEN):
            return True
    return False


def count_lines(path):
    try:
        with open(path, "rb") as handle:
            return handle.read().count(b"\n")
    except OSError:
        return 0


def nth_line(path, index):
    try:
        with open(path, "r") as handle:
            lines = [line for line in handle.read().splitlines() if line.strip()]
    except OSError:
        return None
    if len(lines) <= index:
        return None
    try:
        return json.loads(lines[index])
    except ValueError:
        return None


def start_fixture(work, node):
    log = os.path.join(work, "model.log")
    open(log, "w").close()
    child = subprocess.Popen([node, os.path.join(HERE, "fixture-model.cjs"), "--log", log],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=work)
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        ready, _, _ = select.select([child.stdout], [], [], 0.5)
        if not ready:
            if child.poll() is not None:
                common.refuse("the model fixture exited: "
                    + child.stderr.read().decode("utf-8", "replace").strip()[:200])
            continue
        text = os.read(child.stdout.fileno(), 4096).decode("utf-8", "replace")
        for line in text.splitlines():
            if line.startswith("port "):
                return child, log, int(line.split()[1])
    common.refuse("the model fixture printed no port within 20 s")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bin", required=True)
    parser.add_argument("--root", required=True)
    parser.add_argument("--samples", type=int, default=5)
    parser.add_argument("--timeout", type=float, default=60.0)
    args = parser.parse_args()
    if not os.access(args.bin, os.X_OK):
        common.refuse("no runnable binary at " + args.bin)
    node = shutil.which("node")
    if not node:
        common.refuse("node is not on PATH, so the model fixture cannot run")
    work = common.scratch("speed-first-token-")
    fixture = None
    child = None
    try:
        home = common.home_in(work)
        fixture, log, port = start_fixture(work, node)
        env = common.environment(work, home, args.root, {
            "WASM_AGENT_LLM_BASE_URL": "http://127.0.0.1:%d" % port,
            "WASM_AGENT_LLM_API_KEY": "fixture-key",
            "WASM_AGENT_LLM_MODEL": "fixture",
        })
        master, slave = pty.openpty()
        child = subprocess.Popen([args.bin, "--db", os.path.join(work, "t.db"), "chat"],
            stdin=slave, stdout=slave, stderr=slave, cwd=work, env=env, close_fds=True,
            preexec_fn=os.setsid)
        os.close(slave)
        if not saw_header(master, 60):
            common.refuse("the prompt header did not arrive within 60 s")
        values = []
        for index in range(args.samples + 1):
            before = count_lines(log)
            os.write(master, b"hi\n")
            entered = time.time() * 1000.0
            deadline = time.monotonic() + args.timeout
            answer = None
            while time.monotonic() < deadline:
                drain(master, 0.002)
                if count_lines(log) > before:
                    answer = nth_line(log, before)
                    break
            if answer is None:
                common.refuse("turn %d reached no model call within %.0fs" % (index, args.timeout))
            if index > 0:
                values.append(answer["first_byte_ms"] - entered)
        common.samples(values)
    finally:
        for process in (child, fixture):
            if process is None:
                continue
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except Exception:
                try:
                    process.kill()
                except Exception:
                    pass
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
