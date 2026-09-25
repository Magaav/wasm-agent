const { spawnSync } = require("node:child_process");

const PROGRAM = String.raw`
import json, sqlite3, sys

database_path, mode, statement, encoded_params = sys.argv[1:]
connection = sqlite3.connect(database_path)
connection.row_factory = sqlite3.Row
cursor = connection.execute(statement, json.loads(encoded_params))
if mode == "execute":
    connection.commit()
    result = {"changes": cursor.rowcount}
else:
    row = cursor.fetchone()
    result = dict(row) if row is not None else None
connection.close()
# Keep the subprocess protocol independent of the Windows ANSI code page. JSON.parse
# restores escaped Unicode, while raw Unicode output can fail before Node receives it.
print(json.dumps(result))
`;

let selectedPython;

function python() {
  if (selectedPython) return selectedPython;
  const candidates = [
    process.env.WA_TEST_SQLITE_PYTHON && { command: process.env.WA_TEST_SQLITE_PYTHON, args: [] },
    { command: "python3", args: [] },
    { command: "python", args: [] },
    process.platform === "win32" && { command: "py", args: ["-3"] },
  ].filter(Boolean);
  for (const candidate of candidates) {
    const probe = spawnSync(candidate.command, [...candidate.args, "-c", "import sqlite3"], {
      encoding: "utf8", windowsHide: true,
    });
    if (!probe.error && probe.status === 0) {
      selectedPython = candidate;
      return selectedPython;
    }
  }
  throw new Error("Python with sqlite3 is required for this test");
}

function invoke(mode, databasePath, statement, params) {
  const runtime = python();
  const result = spawnSync(runtime.command,
    [...runtime.args, "-c", PROGRAM, databasePath, mode, statement, JSON.stringify(params)], {
    encoding: "utf8",
    windowsHide: true,
  });
  if (result.error || result.status !== 0) {
    throw new Error(`sqlite fixture failed: ${result.error || result.stderr || `exit ${result.status}`}`);
  }
  return JSON.parse(result.stdout);
}

function queryOne(databasePath, statement, params = []) {
  return invoke("query_one", databasePath, statement, params) ?? undefined;
}

function execute(databasePath, statement, params = []) {
  return invoke("execute", databasePath, statement, params);
}

module.exports = { execute, queryOne };
