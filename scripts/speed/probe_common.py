"""The two things every timing probe here must do the same way (change/speed-board, 22/11).

1. ITS OWN SCRATCH HOME, and a REFUSAL when it cannot have one. A probe that measures the operator's own
   node reads (and writes) the state it is supposed to be a witness of, and a number taken against a
   warm real home is not the number Victor's cold start costs. Rule 2 of the mission.
2. ONE LINE PER SAMPLE, and nothing else on stdout: the harness takes the median (scripts/lib/
   speed-stats.lua), so a probe never decides the number itself and never averages.

The environment a probe hands the binary is built from nothing (env -i in spirit): PATH, the scratch
home, this tree's Lua root and the fixture's own variables. An inherited provider, rendezvous or relay
would send the measurement to the network the first time (measured 21/11, scripts/test-cli-queued.sh).
"""
import os
import shutil
import sys
import tempfile

# The variables a measurement may keep. Everything else in this process's environment is dropped.
KEEP = ("PATH", "SYSTEMROOT", "SYSTEMDRIVE", "WINDIR")


def refuse(reason):
    sys.stderr.write("unavailable: " + reason + "\n")
    raise SystemExit(2)


def scratch(prefix):
    """A directory that is NOT under the operator's real ~/.wasm-agent, or a refusal."""
    real = os.path.join(os.path.expanduser("~"), ".wasm-agent")
    for base in ("/tmp", "/var/tmp", tempfile.gettempdir()):
        if not os.path.isdir(base):
            continue
        if os.path.abspath(base).startswith(os.path.abspath(real)):
            continue
        path = tempfile.mkdtemp(prefix=prefix, dir=base)
        if os.path.abspath(path).startswith(os.path.abspath(real)):
            shutil.rmtree(path, ignore_errors=True)
            continue
        return path
    refuse("no scratch directory outside " + real)


def home_in(work):
    home = os.path.join(work, "home")
    os.makedirs(home, exist_ok=True)
    return home


def environment(work, home, root, extra=None):
    env = {name: os.environ[name] for name in KEEP if name in os.environ}
    env.update({
        "HOME": home,
        "WASM_AGENT_HOME": home,
        "WASM_AGENT_LUA_ROOT": root,
        "WASM_AGENT_MANAGED": "0",
        "WASM_AGENT_RENDEZVOUS": "",
        "WASM_AGENT_RELAY": "",
        "WASM_AGENT_CLI_OPENING": "off",
        "TERM": "xterm-256color",
        "TMPDIR": work,
    })
    if extra:
        env.update(extra)
    return env


def samples(values):
    for index, value in enumerate(values, start=1):
        sys.stdout.write("sample %d %.0f\n" % (index, value))
    sys.stdout.flush()
    if len(values) < 3:
        refuse("only %d sample(s) - three are the least a median can stand on" % len(values))
