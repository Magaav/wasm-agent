@echo off
rem Launch the wasm-agent CLI with its Lua core read from THIS checkout, so edits
rem to lua/ take effect immediately with the installed binary - no rebuild, and
rem therefore no Rust toolchain needed. This is what makes self-evolution work on
rem a Windows node.
rem
rem It also gives the dev node its OWN home. Before this, every dev run wrote the
rem operator's ledger (<home>/.wasm-agent/memory.db): one ledger came to hold 39
rem different binaries and four different lua roots, the on-disk and embedded copies
rem wrote two naming generations into the same tables, and switching between them
rem changed the request prefix, so the provider re-billed a whole ~400k-token prompt.
rem A dev node is a candidate node; a candidate does not write the production ledger.
rem
rem Note for whoever edits this: the steps are separate lines on purpose. Inside a
rem parenthesised block cmd.exe expands %VARS% when it parses the block, so a
rem variable set in the same block reads as empty - the first version of this
rem silently created nothing and copied nothing.
rem
rem Recovery: if the on-disk Lua breaks, run plain `wa chat` (embedded Lua) or
rem `git checkout -- lua/`.
setlocal
set "WASM_AGENT_LUA_ROOT=%~dp0.."
if defined WASM_AGENT_HOME goto run
set "WASM_AGENT_HOME=%~dp0..\.wasm-agent-dev"
if not exist "%WASM_AGENT_HOME%\.wasm-agent" mkdir "%WASM_AGENT_HOME%\.wasm-agent" >nul 2>&1
rem The env file lives at <home>/.wasm-agent/env, so the dev home needs its own copy
rem to reach a provider. Copied once, never printed, and gitignored with the home.
if not exist "%WASM_AGENT_HOME%\.wasm-agent\env" if exist "%USERPROFILE%\.wasm-agent\env" copy /y "%USERPROFILE%\.wasm-agent\env" "%WASM_AGENT_HOME%\.wasm-agent\env" >nul 2>&1
:run
wa chat %*
