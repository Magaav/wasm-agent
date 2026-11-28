#!/usr/bin/env node
// The review lane's token: WHICH HOME may approve a landing that stopped for a person.
//
// THE PATH IS FIXED (Fable 27/11, decision 2): `<home>/.wasm-agent/lane/review.token`, a regular file, mode
// 0600 or stricter, 32 characters or more. No environment variable names it and the command line cannot
// point somewhere else, because an override IS a bypass - the whole value of the token is that only one
// lane's directory can hold it.
//
// `home` is a parameter, not `os.homedir()` read here, for one reason only: a row can then check the rules
// on a scratch home it owns. The command line passes the real one and nothing else can.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

/// The one path. `home` defaults to the real home and is never read from the environment by the caller.
export function reviewTokenPath(home = os.homedir()) {
  return path.join(home, '.wasm-agent', 'lane', 'review.token');
}

/// Checked, not trusted: kind, mode and length each have their own sentence, so a refusal says which rule
/// the token broke instead of "refused".
export function reviewLane({home = os.homedir(), tokenPath = null} = {}) {
  const file = tokenPath || reviewTokenPath(home);
  let stat;
  try { stat = fs.lstatSync(file); } catch { return {ok: false, file, why: `no review token at ${file} (a landing that needs review is approved by that lane, and its token is a file there)`}; }
  if (!stat.isFile()) return {ok: false, file, why: `${file} is not a regular file`};
  const mode = stat.mode & 0o777;
  if ((mode & 0o077) !== 0) return {ok: false, file, why: `${file} is mode ${mode.toString(8)} - 0600 or stricter`};
  let body = '';
  try { body = fs.readFileSync(file, 'utf8').trim(); } catch (error) { return {ok: false, file, why: `${file} cannot be read: ${error.message}`}; }
  if (body.length < 32) return {ok: false, file, why: `${file} is ${body.length} characters - 32 or more`};
  return {ok: true, file, by: `review lane (${file})`};
}
