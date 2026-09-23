// The WhatsApp source keeper's categorical refusals, hermetically.
//
// scripts/whatsapp-source-ensure.sh is what keeps the browser on 9222 alive without a model, so its two
// refusal paths are the ones that must never be silent: a port held by something that is not our browser
// (it must be left alone and named), and a missing logon task (it must name the installer). Both are
// exercised here on a scratch port and a task name that does not exist, so nothing touches the live source.
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const http = require("node:http");
const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");

const repo = path.resolve(__dirname, "..");
const ensure = path.join(repo, "scripts", "whatsapp-source-ensure.sh");
const root = fs.mkdtempSync(path.join(os.tmpdir(), "wa-source-"));
let checks = 0;
const servers = [];
function check(value, label) { assert.ok(value, label); checks += 1; }

function run(...args) {
  const result = spawnSync("bash", [ensure, ...args], { encoding: "utf8", timeout: 60000, windowsHide: true });
  const line = (result.stdout || "").trim().split(/\r?\n/).filter(Boolean).pop() || "";
  let parsed = null;
  try { parsed = JSON.parse(line); } catch { /* asserted below */ }
  return { status: result.status, parsed, stdout: result.stdout || "", stderr: result.stderr || "" };
}

async function freePort() {
  const server = http.createServer(() => {});
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const port = server.address().port;
  await new Promise((resolve) => server.close(resolve));
  return port;
}

async function main() {
  check(fs.existsSync(ensure), `the keeper exists: ${ensure}`);

  // ---- a port held by something that is not our browser is refused, and left alone ------------------
  // This is the worst case that looks healthy: a listener on 9222 answers nothing DevTools understands
  // (one held it for hours answering 404). The keeper must not take a port this pipeline does not own.
  const port = await freePort();
  const foreign = http.createServer((request, response) => { response.statusCode = 404; response.end("not devtools"); });
  await new Promise((resolve) => foreign.listen(port, "127.0.0.1", resolve));
  servers.push(foreign);
  const refused = run("--port", String(port), "--wait", "4");
  check(refused.status === 1, `a foreign listener is refused (exit ${refused.status})`);
  check(refused.parsed && refused.parsed.ok === false && refused.parsed.reason === "port_held_by_other",
    `the refusal is categorical: ${JSON.stringify(refused.parsed)}`);
  check(refused.stderr.includes("not the agent-profile Chrome"), "the refusal says why the port is not ours");
  check(foreign.listening === true, "the foreign listener was left alone, not killed");
  await new Promise((resolve) => foreign.close(resolve));

  // ---- a missing logon task is named, with the command that registers it ----------------------------
  const missing = run("--task", "wasm-agent-no-such-task", "--port", String(await freePort()), "--wait", "4");
  check(missing.status === 1, `a missing task is refused (exit ${missing.status})`);
  check(missing.parsed && missing.parsed.reason === "task_not_registered",
    `the refusal is categorical: ${JSON.stringify(missing.parsed)}`);
  check(missing.stderr.includes("install-whatsapp-chrome-task.ps1"), "the refusal names the installer to run");

  // ---- and the contract: one JSON object on stdout, human lines on stderr --------------------------
  check(missing.stdout.trim().split(/\r?\n/).length === 1, `stdout carries exactly one line: ${JSON.stringify(missing.stdout)}`);

  console.log(`source ensure ok (${checks} checks, 0 failed, 0 skipped; scratch ports, no browser, no model)`);
  console.log(`evidence: ${root}`);
}

(async () => {
  try {
    await main();
  } catch (error) {
    console.error(error.stack || String(error));
    console.error("evidence: " + root);
    process.exitCode = 1;
  } finally {
    for (const server of servers) { try { server.close(); } catch { /* already closed */ } }
  }
})();
