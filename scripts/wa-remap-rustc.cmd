@echo off
rem The native-Windows twin of `scripts/wa-remap-rustc`: a component build must not depend on WHERE
rem the tree is checked out, and the remap cannot travel in RUSTFLAGS (Cargo hashes that string into
rem `-C metadata`, so two checkouts would differ again). `RUSTC_WRAPPER` is resolved through PATH, so
rem the value Cargo sees is the bare name - identical in every checkout - and the paths are computed
rem per invocation here. See docs/COMPONENTS.md, "Reproducible builds", and the `sh` twin for the
rem full reasoning.
rem
rem Cargo calls a wrapper as `wrapper <rustc> <args...>`, so the first argument is the compiler and
rem not a source file. `%*` is not affected by `shift`, so the argument list is rebuilt by walking
rem `%1`, `%2`, ... and quoting each one (a toolchain path or an `-L` path can contain a space).
setlocal enableextensions
rem The checkout root, canonicalised: `%~dp0..` alone can keep the `..` in it (`C:\a\b\scripts\..`),
rem which would make the remap below match nothing and silently change no path at all (measured once).
rem `%CD%` after a `pushd` is the real path, with no trailing backslash. This has to happen BEFORE the
rem `shift`: `shift` moves `%0` too, and `%~dp0` would then be the compiler's directory.
pushd "%~dp0.."
set "ROOT=%CD%"
popd
if not exist "%ROOT%\rust\components" (
  echo wa-remap-rustc: not a wasm-agent checkout: "%ROOT%" 1>&2
  exit /b 2
)
set "RUSTC=%~1"
if not defined RUSTC exit /b 2
shift
if defined CARGO_HOME (set "CH=%CARGO_HOME%") else (set "CH=%USERPROFILE%\.cargo")
set "RMIX=%ROOT:\=/%"
set "CMIX=%CH:\=/%"
set REMAP="--remap-path-prefix=%ROOT%=/wasm-build" "--remap-path-prefix=%CH%=/cargo-home"
set REMAP=%REMAP% "--remap-path-prefix=%RMIX%=/wasm-build" "--remap-path-prefix=%CMIX%=/cargo-home"
:args
if "%~1"=="" goto run
set REMARGS=%REMARGS% "%~1"
shift
goto args
:run
"%RUSTC%" %REMAP% %REMARGS%
exit /b %ERRORLEVEL%
