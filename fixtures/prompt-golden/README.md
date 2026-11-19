# Prompt goldens - recorded on a27490af

These files are the bytes a27490af (a27490af0af08ac9789bd0ae2c59d0ac0a8e4392) really built: the FULL
system prompt agent:build_context() returns and the tool list it declares, for every explicit
WASM_AGENT_RAW_CODE mode in both envelopes, plus one child.

Recorded with (run FROM the base worktree's own root - the prompt depends on the process cwd):

    git worktree add <tmp> a27490af
    cp <branch>/scripts/generate-prompt-goldens.lua <tmp>/scripts/
    cp <branch>/scripts/lib/prompt-golden.lua <branch>/scripts/lib/prompt-golden-cases.lua <tmp>/scripts/lib/
    cd <tmp>
    WASM_AGENT_LUA_ROOT=<tmp> GATE_ROOT=<scratch> WASM_AGENT_HOME=<scratch> HOME=<scratch> \
      WA_GOLDEN_OUT=<tmp>/fixtures-run WA_SCRIPT=<tmp>/scripts/generate-prompt-goldens.lua \
      wa --db <scratch>/db.sqlite
    cp <tmp>/fixtures-run/*.json <branch>/fixtures/prompt-golden/

Nothing is normalised except host facts (this run's home, the tree path, the working directory and the
session workdir attribute). The "conform: no profile for ..." notice a27490af appends to the prompt
(a27490af:lua/core/agent.lua:1190) is shown once per process, so it is recorded in exactly one golden -
progressive-only.json, the first case a recording process builds. This branch moved that line to the
operator log (568ed30c), so its prompts carry none; scripts/test-prompt-golden.lua compares the bytes
exactly and names that single difference.

The arm-B rows do not skip: scripts/test-prompt-golden.lua also asserts a default node (no switch) is
arm B - prog​ressive and full envelope, master and child - and its build() gives the scratch provider a
tool_call row through the same seam the node reads.

Checked by scripts/test-prompt-golden.lua (wired in scripts/test.sh, "prompt golden ok").
