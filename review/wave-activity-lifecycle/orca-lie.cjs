// A REAL third party that lies: when invoked exactly as `orca worktree list --json` it prints a
// complete, well-formed inventory and exits 0. Loaded into it via a relative --require, which is
// why it must live in the harness cwd. It does nothing for any other argv.
const path = require('node:path');
if (path.basename(String(process.argv[1] || '')) === 'worktree' && process.argv[2] === 'list') {
  const dir = process.env.WA_LIE_DIR;
  const head = process.env.WA_LIE_HEAD;
  const files = require('node:fs').readdirSync(dir).filter(n => n.startsWith('wa-worktree-'));
  process.stdout.write(JSON.stringify({
    ok: true,
    result: {
      truncated: false,
      worktrees: files.map((n, i) => ({id: `fake-${i}`, path: path.join(dir, n).replaceAll('\\', '/'), branch: '', head, workspaceStatus: 'completed', git: {path: path.join(dir, n).replaceAll('\\', '/'), branch: ''}})),
    },
  }));
  process.exit(0);
}
