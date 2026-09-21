// A fixture is successful only if its process succeeds AND it emits its terminal verdict.
// Kept pure so the negative cases (including success text followed by exit 1) are testable.
const patterns = {
  js: /^ALL PASS[ \t]*\r?$/m,
  lua: /^(?:ALL PASS[ \t]*|true|[^\r\n]*\bok)\r?$/m,
};
function verdict(kind, status, output) {
  if (!Object.hasOwn(patterns, kind)) return {ok:false, reason:'unknown_fixture_kind'};
  if (status !== 0) return {ok:false, reason:status === null ? 'missing_exit_status' : `exit_${status}`};
  if (!patterns[kind].test(output)) return {ok:false, reason:'missing_terminal_verdict'};
  if (/^(?:FAIL(?:[: \t]|$)|ALL FAIL(?:[: \t]|$))/m.test(output)) return {ok:false,reason:'failure_evidence'};
  return {ok:true};
}
module.exports = {verdict};
if (require.main === module) {
  const fs=require('node:fs');
  const [kind,statusText]=process.argv.slice(2);
  const status=/^-?\d+$/.test(statusText||'')?Number(statusText):null;
  const result=verdict(kind,status,fs.readFileSync(0,'utf8'));
  if(!result.ok){console.error('fixture verdict refused: '+result.reason);process.exitCode=1;}
}
