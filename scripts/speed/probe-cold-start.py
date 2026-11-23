#!/usr/bin/env python3
"""COLD START: process start -> the prompt is up in a real pty, with a key typed into it.

    python3 scripts/speed/probe-cold-start.py --bin <wa> --root <tree> [--samples 5]

WHY THIS IS A PTY AND NOT A PIPE. A pipe has no window size and no terminal modes, so the process takes a
different path (the header wraps differently, the reader is not a tty reader) and the number would not be
the one Victor waits for when he opens a window and runs it.

WHAT IS MEASURED, EXACTLY. Spawn -> the moment the prompt's own header is complete, i.e. the "memory:"
line the REPL prints as its last start line, has arrived on the pty. That is the instant the prompt is
usable. A key is typed at t=0, before the header exists, and the key must not kill the process (checked
right after the header: a key that reaches a not-yet-live reader can).

WHY NOT "THE PROMPT ACCEPTED THE KEY LATER THAN THAT". Measured on 8862b600 (23/11): the process never
leaves the pty's canonical+echo modes, so a typed key is delivered to the process on Enter and the tty
accepts bytes from t=0 - there is no later instant to observe, and the earlier version of this probe that
looked for the typed character in the output was measuring the KERNEL's echo (1-2 ms, before the process
had even printed anything). What moves with the code is the time until the prompt is up, which is what
this row reports.
"""
import argparse
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

HEADER_END = b"memory: "


def one(binary, root, work, home, timeout):
    master, slave = pty.openpty()
    env = common.environment(work, home, root, {
        # Nothing may dial out: the model is unreachable on purpose (no turn is ever sent).
        "WASM_AGENT_LLM_BASE_URL": "http://127.0.0.1:1",
        "WASM_AGENT_LLM_API_KEY": "fixture",
        "WASM_AGENT_LLM_MODEL": "fixture",
    })
    began = time.monotonic()
    child = subprocess.Popen([binary, "--db", os.path.join(work, "t.db"), "chat"],
        stdin=slave, stdout=slave, stderr=slave, cwd=work, env=env, close_fds=True, preexec_fn=os.setsid)
    os.close(slave)
    try:
        os.write(master, b"z")
        seen = b""
        deadline = began + timeout
        while time.monotonic() < deadline:
            ready, _, _ = select.select([master], [], [], 0.05)
            if not ready:
                continue
            try:
                chunk = os.read(master, 8192)
            except OSError:
                break
            if not chunk:
                break
            seen += chunk
            if HEADER_END in seen:
                elapsed = (time.monotonic() - began) * 1000.0
                if child.poll() is not None:
                    common.refuse("the process died after the header (exit %s)" % child.returncode)
                return elapsed
        common.refuse("the prompt header did not arrive within %.0fs" % timeout)
    finally:
        try:
            os.killpg(child.pid, signal.SIGKILL)
        except Exception:
            pass
        os.close(master)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bin", required=True)
    parser.add_argument("--root", required=True)
    parser.add_argument("--samples", type=int, default=5)
    parser.add_argument("--timeout", type=float, default=30.0)
    args = parser.parse_args()
    if not os.access(args.bin, os.X_OK):
        common.refuse("no runnable binary at " + args.bin)
    work = common.scratch("speed-cold-start-")
    try:
        home = common.home_in(work)
        values = []
        for _ in range(max(1, args.samples)):
            values.append(one(args.bin, args.root, work, home, args.timeout))
        common.samples(values)
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
