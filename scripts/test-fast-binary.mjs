#!/usr/bin/env node
// Which binary the fast path runs, and whether it says so (11/11).
//
// Measured: `scripts/fast.sh` looked for `wa` on PATH first, and on this node `~/.local/bin/wa` is a
// symlink into the canonical checkout's target dir - so three sessions ran rows against another
// commit's node (whatsapp.log, cli.log, codemode.log), one of them fully green, on a tree whose edits
// were never loaded. The rule this checks is in `scripts/lib/fast-binary.sh`:
//
//   1. the tree's own binary wins over anything on PATH, and the FIRST line of a run names it with its
//      build commit, this tree's commit and a verdict;
//   2. a binary that is not this tree's is refused by name (`stale_binary`, with the command that builds
//      the right one) unless a human named it (`WA_BIN`) or allowed it (`WA_FAST_ALLOW_STALE_BINARY=1`);
//   3. `bash scripts/fast.sh --binary` in this repository really does print that line first, with a
//      verdict - the end-to-end half, so the resolver cannot pass here while the script ignores it.
//
// Run: node scripts/test-fast-binary.mjs
import { execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, writeFileSync, chmodSync, rmSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const LIB = join(ROOT, "scripts", "lib", "fast-binary.sh");
let checks = 0;
const failures = [];

function check(condition, what) {
  checks += 1;
  if (!condition) failures.push(what);
  return condition;
}
function run(command, args, options = {}) {
  try {
    const stdout = execFileSync(command, args, {
      encoding: "utf8", stdio: ["ignore", "pipe", "pipe"], ...options,
    });
    return { code: 0, stdout, stderr: "" };
  } catch (error) {
    return { code: error.status ?? 1, stdout: error.stdout ?? "", stderr: error.stderr ?? "" };
  }
}

// A stub node that answers the identity probe like the real binary does: `host.runtime_info()` is one
// JSON object on stdout, then `quickjs=1` when the code-mode assets are embedded.
function stubBinary(path, { commit, sha, codemode = "1" }) {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, `#!/bin/sh
printf '{"version":"0.1.0","binary_sha256":"${sha}${"0".repeat(64)}","build_source_commit":"${commit}","build_source_tree":"","build_wave_generation":"","process_id":1,"boot_id":"b","os":"linux","arch":"x86_64"}\\n'
echo "quickjs=${codemode}"
`);
  chmodSync(path, 0o755);
}

// A fixture checkout: a real git repository (the resolver asks it for HEAD) with a stub tree binary.
const scratchRoots = [];
function fixture({ treeCommit = "a".repeat(40), staleTreeBinary = null, treeBinary = true } = {}) {
  const dir = mkdtempSync(join(tmpdir(), "wa-fast-binary-"));
  scratchRoots.push(dir);
  const repo = join(dir, "repo");
  mkdirSync(join(repo, "scripts", "lib"), { recursive: true });
  writeFileSync(join(repo, "scripts", "lib", "fast-binary.sh"), readFileSync(LIB));
  writeFileSync(join(repo, "lua.txt"), "x\n");
  mkdirSync(join(repo, "lua", "core"), { recursive: true });
  writeFileSync(join(repo, "lua", "core", "agent.lua"), "-- fixture\n");
  run("git", ["init", "-q", repo]);
  run("git", ["-C", repo, "config", "user.email", "fixture@example.invalid"]);
  run("git", ["-C", repo, "config", "user.name", "fixture"]);
  run("git", ["-C", repo, "add", "-A"]);
  run("git", ["-C", repo, "commit", "-qm", "fixture"]);
  const head = run("git", ["-C", repo, "rev-parse", "HEAD"]).stdout.trim();
  // The tree currently under test is `head`; `treeCommit` is what a binary claims to be built from.
  if (treeBinary) {
    stubBinary(join(repo, "rust", "target", "release", "wa"), { commit: staleTreeBinary ?? treeCommit, sha: "b" });
  }
  // An installed node on PATH, built from another commit - exactly the node's ~/.local/bin/wa shape.
  stubBinary(join(dir, "installed", "wa"), { commit: "c".repeat(40), sha: "c" });
  return { dir, repo, head };
}

// The resolver, driven the way fast.sh drives it.
function plan(repo, extraEnv = {}) {
  const script = `set -u
ROOT=${JSON.stringify(repo)}
. "$ROOT/scripts/lib/fast-binary.sh"
fast_binary_plan
fast_binary_banner
printf 'ACTION=%s\\nSOURCE=%s\\nVERDICT=%s\\nWHY=%s\\nBIN=%s\\n' "$FAST_BIN_ACTION" "$FAST_BIN_SOURCE" "$FAST_BIN_VERDICT" "$FAST_BIN_WHY" "$FAST_BIN"
if [ "$FAST_BIN_ACTION" = refuse ]; then fast_binary_refuse; fi
`;
  const result = run("bash", ["-c", script], {
    env: {
      ...process.env,
      PATH: extraEnv.PATH ?? process.env.PATH,
      WA_FAST_SKIP_BUILD: "1",
      ...extraEnv,
    },
  });
  const field = (name) => (result.stdout.match(new RegExp(`^${name}=(.*)$`, "m")) ?? [])[1] ?? "";
  return {
    code: result.code, stdout: result.stdout, stderr: result.stderr,
    action: field("ACTION"), source: field("SOURCE"), verdict: field("VERDICT"),
    why: field("WHY"), bin: field("BIN"),
    banner: result.stdout.split("\n")[0] ?? "",
  };
}

try {
  // 1. The tree's binary wins, and the first line names it and the verdict.
  {
    const { dir, repo, head } = fixture({ treeBinary: false });
    // The stub claims the tree's own commit, so the verdict must be `fresh`.
    stubBinary(join(repo, "rust", "target", "release", "wa"), { commit: head, sha: "b" });
    const result = plan(repo, { PATH: `${join(dir, "installed")}:${process.env.PATH}` });
    check(result.action === "use", `a fresh tree binary is used, got action=${result.action} (${result.why})`);
    check(result.source === "tree", `the tree's binary is preferred over the PATH one, got source=${result.source}`);
    check(result.verdict === "fresh", `a binary built from this commit is fresh, got ${result.verdict}`);
    check(result.bin === join(repo, "rust", "target", "release", "wa"),
      `the chosen binary is the tree's, got ${result.bin}`);
    check(/^fast: binary .*\(build [0-9a-f]{12}, tree [0-9a-f]{12}, fresh: /.test(result.banner),
      `the first line names the binary, its build, the tree and the verdict: ${result.banner}`);
    check(result.banner.includes(join(repo, "rust", "target", "release", "wa")),
      "the first line names the path that will run");
  }

  // 2. A tree binary from another commit is stale: refused by name, with the command that fixes it.
  {
    const { repo } = fixture({ staleTreeBinary: "d".repeat(40) });
    const result = plan(repo);
    check(result.verdict === "stale", `a binary from another commit is stale, got ${result.verdict}`);
    check(result.action === "refuse", `with the build forbidden it refuses, got action=${result.action}`);
    check(result.code === 2, `the refusal exits 2 (a tree verdict, not the machine), got ${result.code}`);
    check(result.stderr.includes("stale_binary"), `the refusal is named stale_binary: ${result.stderr.slice(0, 200)}`);
    check(result.stderr.includes("cargo build --release"), "the refusal prints the command that builds the right binary");
    check(result.stderr.includes("WA_BIN="), "the refusal names WA_BIN as the way to choose a binary on purpose");
  }

  // 3. No tree binary at all: the installed one is not silently used; it is refused, not chosen.
  {
    const { dir, repo } = fixture({ treeBinary: false });
    const result = plan(repo, { PATH: `${join(dir, "installed")}:${process.env.PATH}` });
    check(result.source === "installed", `the installed binary is found, got source=${result.source}`);
    check(result.verdict === "stale", `an installed binary from another commit is stale, got ${result.verdict}`);
    check(result.action === "refuse", `it is refused rather than run silently, got action=${result.action}`);
    check(result.bin.includes("installed"), `the refusal names the binary it refused: ${result.bin}`);
  }

  // 4. An explicit WA_BIN is authoritative - a human chose it - and is still described honestly.
  {
    const { dir, repo } = fixture({ treeBinary: false });
    const chosen = join(dir, "installed", "wa");
    const result = plan(repo, { WA_BIN: chosen, PATH: `${join(dir, "installed")}:${process.env.PATH}` });
    check(result.action === "use", `WA_BIN is used, got action=${result.action}`);
    check(result.source === "explicit", `the source says it was named, got ${result.source}`);
    check(result.banner.includes("named by WA_BIN"), `the first line says a human named it: ${result.banner}`);
  }

  // 5. An explicit override for a machine that cannot build: used, and said out loud as stale.
  {
    const { repo } = fixture({ staleTreeBinary: "e".repeat(40) });
    const result = plan(repo, { WA_FAST_SKIP_BUILD: "", WA_FAST_ALLOW_STALE_BINARY: "1" });
    check(result.action === "use", `the documented override uses it, got action=${result.action}`);
    check(result.banner.includes("stale") && result.banner.includes("WA_FAST_ALLOW_STALE_BINARY=1"),
      `the override is printed, not silent: ${result.banner}`);
  }

  // 6. End to end: the real script's first line is the resolution, and it carries a verdict.
  {
    const result = run("bash", [join(ROOT, "scripts", "fast.sh"), "--binary"]);
    const first = result.stdout.split("\n")[0] ?? "";
    check(result.code === 0, `fast.sh --binary exits 0, got ${result.code}`);
    check(/^fast: binary \S+ \(build .*, tree [^,]+, (fresh|stale|unknown|explicit)[:,]/.test(first),
      `fast.sh's first line is the resolution: ${first}`);
    check(/\b(tree|build|named by WA_BIN)\b/.test(first), `the line says which commit and why: ${first}`);
  }
} finally {
  for (const dir of scratchRoots) rmSync(dir, { recursive: true, force: true });
}

if (failures.length > 0) {
  console.error(`fast binary: ${failures.length} of ${checks} checks failed`);
  for (const failure of failures) console.error(`  - ${failure}`);
  process.exit(1);
}
console.log(`fast binary: ${checks} checks`);
