#!/usr/bin/env node
// scripts/lib/proc-use.mjs's rule for processes /proc will not show, against a fixture /proc: another user's
// are skipped, this user's privileged ones (setuid, capabilities, non-dumpable) are skipped, an ordinary one
// of this user makes the answer unproven, a zombie is not counted, and a readable holder is named.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { procUse, procUseNote } from './lib/proc-use.mjs';

if (process.platform === 'win32') { console.log('proc use ok (0 checks, 1 skipped; /proc is the POSIX evidence)'); process.exit(0); }
const me = process.getuid();
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-proc-use-'));
let checks = 0;
const check = (value, label) => { assert.ok(value, label); checks += 1; };
try {
  const family = path.join(root, 'family'); fs.mkdirSync(family);
  const proc = path.join(root, 'proc');
  // A process: its status, and a cwd that is a link (readable) or a plain file (readlink refuses: unreadable).
  const pid = (n, { uids = [me, me, me, me], cap = '0000000000000000', state = 'S (sleeping)', cwd = null } = {}) => {
    const dir = path.join(proc, String(n)); fs.mkdirSync(path.join(dir, 'fd'), { recursive: true });
    fs.writeFileSync(path.join(dir, 'status'), `Name:\tx\nState:\t${state}\nUid:\t${uids.join('\t')}\nCapEff:\t${cap}\n`);
    if (cwd) fs.symlinkSync(cwd, path.join(dir, 'cwd')); else fs.writeFileSync(path.join(dir, 'cwd'), '');
  };
  const other = me + 1;
  pid(10, { uids: [other, other, other, other] });
  pid(11, { cap: '0000000800000000' });
  pid(12, { uids: [me, 0, 0, 0] });
  pid(13, { state: 'Z (zombie)' });
  pid(14, { cwd: '/' });
  let use = procUse(family, { procRoot: proc, uid: me });
  check(use.holder === null && use.error === undefined, 'nothing readable works in the family');
  check(use.skippedOtherUser === 1, `another user's unreadable process is skipped and counted: ${JSON.stringify(use)}`);
  check(use.skippedPrivileged === 2, `this user's capability-holding and setuid processes are skipped as privileged: ${JSON.stringify(use)}`);
  check(use.unreadableOwn === 0, 'a zombie is not counted as unreadable');
  check(/1 other-user/.test(procUseNote(use)) && /2 privileged/.test(procUseNote(use)), `the note names both counts: ${procUseNote(use)}`);

  pid(15);
  use = procUse(family, { procRoot: proc, uid: me });
  check(use.unreadableOwn === 1 && use.holder === null, `an ordinary unreadable process of this user leaves the answer unproven: ${JSON.stringify(use)}`);

  pid(16, { cwd: path.join(family) });
  use = procUse(family, { procRoot: proc, uid: me });
  check(use.holder && use.holder.pid === 16 && /works in it/.test(use.holder.why), `a readable process working inside is named: ${JSON.stringify(use)}`);

  check(procUse(path.join(root, 'missing'), { procRoot: proc, uid: me }).error, 'a family that cannot be resolved is an error, never clean');
  check(procUse(family, { procRoot: path.join(root, 'no-proc'), uid: me }).error, 'no /proc is an error, never clean');
} finally {
  fs.rmSync(root, { recursive: true, force: true });
}
console.log(`proc use ok (${checks} checks, 0 skipped; fixture /proc)`);
