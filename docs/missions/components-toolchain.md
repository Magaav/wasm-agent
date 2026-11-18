# Mission change/components-toolchain — wasi-sdk on avell, rebuild the mesh component for harness-land

harness-land (branch change/harness-land, head 3ce1a95f) is red on exactly one gate: `component-pins:
mesh source changed and its pin did not - rust/wa-mesh-core/src/cache.rs, roster.rs`. rust/components/mesh
path-depends on wa-mesh-core; rebuilding it needs wasi-sdk, absent on avell (WASI_SDK unset; the old desktop
had it and was wiped).
1. Provision wasi-sdk on avell at the exact version the repo pins (find it in scripts/build-components.sh /
   docs/COMPONENTS.md / CI files; verify the download's sha256 against a pin in the repo if one exists, else
   record the measured sha256 in REPORT.md). Install under ~/wasm-agent/toolchain/wasi-sdk-<ver>; never sudo.
   Document the provisioning in docs/COMPONENTS.md so the next node does it the same way.
2. On this branch (based on change/harness-land): `scripts/build-components.sh mesh`, then update the mesh
   pin in components.lock exactly as the repo's procedure does (publish-components.sh only in its local/dry
   mode - NO gh release, NO push). Show the component-pins gate green and the other 10 pins unchanged.
3. Re-run the component rows that fast.sh skipped for want of wasi-sdk; classify any red against the base.
Commit locally; never push, never publish a release.
