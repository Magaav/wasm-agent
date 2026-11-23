// WHICH FILE DID CARGO WRITE? Its own artifact messages say so.
//
// WHY THIS EXISTS (Fable, 23/11). `scripts/release-linux.sh` built `wa-sentinel` and then staged it from a
// GUESSED directory (`rust/wa-sentinel/target/<triple>/release/wa-sentinel`, with a second guess when that was
// empty). A guess is wrong the moment CARGO_TARGET_DIR is set in the caller's environment - and the same class of
// guess staged `wa` from `rust/target/<triple>/release/wa` while the onebuild build wrote it into the node's ONE
// build root, which is the defect that stopped release F's channel step (release-20261123T082627Z-3fc25b76).
//
// `cargo build --message-format=json` prints one JSON object per line on stdout, and the object with
// `"reason":"compiler-artifact"` for a bin target carries `"executable"`: the absolute path of the file cargo
// produced. That is the build's own answer to the question, so a caller reads it instead of guessing.
//
//   node scripts/lib/cargo-executable.mjs <artifacts.json> [bin-name]
//
// stdout: the path, and nothing when no bin artifact was reported. exit 1 (with one named line on stderr): the
// file cannot be read or names no such bin - a caller then refuses, because an empty path is not a path.
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

export function cargoExecutable(file, name = '') {
  let raw;
  try { raw = fs.readFileSync(file, 'utf8'); }
  catch (error) { throw new Error('cargo_artifacts_unreadable: ' + file + ': ' + String((error && error.message) || error)); }
  let found = '';
  for (const line of raw.split(/\r?\n/)) {
    if (line.trim() === '') continue;
    let message;
    try { message = JSON.parse(line); } catch { continue; } // a non-JSON line is not an artifact message
    if (!message || message.reason !== 'compiler-artifact') continue;
    const target = message.target;
    if (!target || !Array.isArray(target.kind) || !target.kind.includes('bin')) continue;
    if (name !== '' && target.name !== name) continue;
    if (typeof message.executable === 'string' && message.executable !== '') found = message.executable;
  }
  if (found === '') {
    throw new Error('cargo_artifact_missing: ' + file + ' reports no bin artifact' + (name !== '' ? ' named ' + name : ''));
  }
  return found;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [file, name] = process.argv.slice(2);
  if (!file) { console.error('usage: cargo-executable.mjs <artifacts.json> [bin-name]'); process.exit(1); }
  try { process.stdout.write(cargoExecutable(file, name || '') + '\n'); }
  catch (error) { console.error(String((error && error.message) || error)); process.exit(1); }
}
