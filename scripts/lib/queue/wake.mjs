#!/usr/bin/env node
// HOW A VERDICT REACHES A SESSION THAT IS NOT LOOKING. One function, one carrier.
//
// DECISION 4 (Fable 27/11): keep `_orch/resume-when-idle.sh` for now, because its parked-session guard is
// the reason it works - the release gate parks workers, and a message delivered to a parked session is
// dropped. But write it as the ONE function the runner calls, so the carrier can be swapped for `tools.wake`
// later without touching the state machine.
//
// The wake is scheduled through systemd-run (v0's own mechanism): the unit is transient, it survives this
// process, and its output goes to the journal. `spawn` is injected so a row can assert the command without
// starting a unit.
import path from 'node:path';
import {spawn as spawnImpl} from 'node:child_process';

export function wakeUnitName(id) {
  return `orch-rework-q${id}`;
}

/// The exact command. Kept separate from running it so a reader (and a row) can see it whole.
export function wakeCommand({missionsDir, mission, file, id}) {
  const resume = path.join(missionsDir, '_orch', 'resume-when-idle.sh');
  const unit = wakeUnitName(id);
  return {
    unit,
    command: 'systemd-run',
    args: ['--user', `--unit=${unit}`, '--collect', `-p`, `WorkingDirectory=${missionsDir}`,
      'bash', '-c', `timeout 10800 bash ${resume} ${mission} ${file}`],
  };
}

/// Deliver: this is the ONE call the runner makes after writing a verdict that a worker has to act on.
export function wakeSession({missionsDir, mission, file, id, spawn = spawnImpl, dryRun = false}) {
  const spec = wakeCommand({missionsDir, mission, file, id});
  if (dryRun) return {...spec, started: false, why: 'dry run' };
  try {
    const child = spawn(spec.command, spec.args, {detached: true, stdio: 'ignore'});
    child.unref();
    return {...spec, started: true};
  } catch (error) {
    return {...spec, started: false, why: error.message };
  }
}
