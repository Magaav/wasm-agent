// WHICH BYTES DID THE BUILD MAKE? Its own receipt says so.
//
// WHY THIS EXISTS (Fable, 23/11). `scripts/release-linux.sh` built the shipping `wa` with
// `scripts/codemode-build.mjs` - which writes into the node's ONE build root (`scripts/lib/build-target.sh`,
// docs/ONEROOT.md), i.e. `<home>/.wasm-agent/build/target/<tree>/<triple>/release/wa` - and then staged the
// bundle from a GUESSED directory, `rust/target/<triple>/release/wa`. Measured on release F
// (release-20261123T082627Z-3fc25b76): the build succeeded, its receipt named the binary, and the bundle step
// refused with `no built binary at .../rust/target/x86_64-unknown-linux-musl/release/wa`. The public channel
// was published by hand that day, so the step's first real run was the second release in a row that found its
// bugs at the real cut.
//
// So the receipt is read, never guessed around: the build names its binary, its sha256, and the commit and
// tree it was made from. A receipt that describes another commit, another tree, another triple or another
// checkout is a NAMED REFUSAL here - unknown is never yes, and a bundle is never staged from bytes the build
// did not claim.
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

class Refusal extends Error {
  constructor(name, detail) { super(name + ': ' + detail); this.reason = name; this.detail = detail; }
}

const text = (value) => (typeof value === 'string' ? value : '');

// The receipt, judged against the release being staged. `expect` carries any of
// {commit, tree, target, root} - the ones the caller knows. Returns the fields a bundle step needs.
export function readBuildReceipt(file, expect = {}) {
  let receipt;
  try { receipt = JSON.parse(fs.readFileSync(file, 'utf8')); }
  catch (error) { throw new Refusal('receipt_unreadable', file + ' is not JSON: ' + String((error && error.message) || error)); }
  if (!receipt || typeof receipt !== 'object') throw new Refusal('receipt_unreadable', file + ' is not a JSON object');
  if (receipt.ok !== true) {
    throw new Refusal('receipt_not_ok', file + ' does not describe a finished build' +
      (receipt.error ? ' (its own error: ' + String(receipt.error) + ')' : ' (it says ok=' + JSON.stringify(receipt.ok) + ')'));
  }
  const binary = text(receipt.binary);
  if (binary === '') throw new Refusal('receipt_no_binary', file + ' names no binary (field "binary"), so there is no built wa to stage');
  if (text(receipt.binary_sha256) === '') throw new Refusal('receipt_field_missing', file + ' names no binary_sha256, so the bytes cannot be held to the build');
  if (text(receipt.source_commit) === '' || text(receipt.source_tree) === '') {
    throw new Refusal('receipt_field_missing', file + ' names no source_commit/source_tree, so it cannot say which source these bytes are');
  }
  if (expect.commit && text(receipt.source_commit) !== expect.commit) {
    throw new Refusal('receipt_commit_mismatch', file + ' was built from ' + text(receipt.source_commit) + ', not from ' + expect.commit);
  }
  if (expect.tree && text(receipt.source_tree) !== expect.tree) {
    throw new Refusal('receipt_tree_mismatch', file + ' was built from tree ' + text(receipt.source_tree) + ', not from ' + expect.tree);
  }
  if (expect.target && text(receipt.target) !== expect.target) {
    throw new Refusal('receipt_target_mismatch', file + ' was built for ' + (text(receipt.target) || 'this host') + ', not for ' + expect.target);
  }
  if (expect.root && text(receipt.root) !== '') {
    const want = fs.realpathSync(expect.root);
    const got = text(receipt.root);
    let got_real = got;
    try { got_real = fs.realpathSync(got); } catch { got_real = got; }
    if (want !== got_real) throw new Refusal('receipt_root_mismatch', file + ' was built from ' + got + ', not from ' + want);
  }
  return { binary, binary_sha256: text(receipt.binary_sha256), source_commit: text(receipt.source_commit),
    source_tree: text(receipt.source_tree), target: text(receipt.target), kind: text(receipt.kind) };
}

// `node scripts/lib/build-receipt.mjs <receipt.json> [--commit SHA] [--tree SHA] [--target TRIPLE] [--root DIR]`
// -> one `field=value` line per field on stdout (the bundle.manifest's own shape, so a caller reads it with the
// same `sed -n 's/^binary=//p'`), or a named refusal on stderr with exit 1.
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2), expect = {};
  let file = null;
  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (arg === '--commit' || arg === '--tree' || arg === '--target' || arg === '--root') {
      const value = args[++i];
      if (value === undefined || value === '') { console.error('build-receipt: value_required: ' + arg); process.exit(1); }
      expect[arg.slice(2)] = value;
    } else if (arg.startsWith('--')) { console.error('build-receipt: unknown_option: ' + arg); process.exit(1); }
    else if (file === null) file = arg;
    else { console.error('build-receipt: usage: build-receipt.mjs <receipt.json> [--commit SHA] [--tree SHA] [--target TRIPLE] [--root DIR]'); process.exit(1); }
  }
  if (!file) { console.error('build-receipt: usage: build-receipt.mjs <receipt.json> [--commit SHA] [--tree SHA] [--target TRIPLE] [--root DIR]'); process.exit(1); }
  try {
    const fields = readBuildReceipt(file, expect);
    for (const [key, value] of Object.entries(fields)) process.stdout.write(key + '=' + value + '\n');
  } catch (error) {
    if (error instanceof Refusal) { console.error('build-receipt: ' + error.reason + ': ' + error.detail); process.exit(1); }
    console.error('build-receipt: receipt_unreadable: ' + String((error && error.message) || error));
    process.exit(1);
  }
}
