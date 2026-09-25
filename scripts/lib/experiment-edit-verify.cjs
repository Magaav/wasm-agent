// Independent verifier for the WhatsApp-controls code-writing fixture.
// It is injected after the model settles, is never shown to the model, and removes its
// temporary Rust test before returning. A candidate's prose or self-authored tests cannot
// turn a failed check into a pass.
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

function arg(name, fallback = '') {
  const at = process.argv.indexOf('--' + name);
  return at >= 0 && process.argv[at + 1] ? process.argv[at + 1] : fallback;
}
const repo = path.resolve(arg('repo', process.cwd()));
const out = arg('output', '');
const timeout = Number(arg('timeout-ms', '1200000'));
const target = path.resolve(arg('target-dir', fs.mkdtempSync(path.join(os.tmpdir(), 'wa-edit-verify-target-'))));
const result = { schema: 'wasm-agent.edit-workflow-verifier/v1', repo, checks: [], commands: [], passed: false };

function check(ok, name, detail) {
  result.checks.push({ name, ok: !!ok, ...(detail ? { detail: String(detail).slice(0, 2000) } : {}) });
  return !!ok;
}
function run(command, args, options = {}) {
  const started = Date.now();
  const proc = spawnSync(command, args, {
    cwd: repo, env: { ...process.env, CARGO_TARGET_DIR: target }, encoding: 'utf8',
    timeout: options.timeout || timeout, windowsHide: true, maxBuffer: 8 * 1024 * 1024,
  });
  const row = {
    command: [command, ...args].join(' '), status: proc.status, signal: proc.signal,
    elapsed_ms: Date.now() - started, timed_out: !!(proc.error && proc.error.code === 'ETIMEDOUT'),
    stdout_tail: String(proc.stdout || '').slice(-4000), stderr_tail: String(proc.stderr || '').slice(-4000),
  };
  result.commands.push(row);
  return row;
}
function text(relative) {
  try { return fs.readFileSync(path.join(repo, relative), 'utf8'); } catch { return ''; }
}

const diff = run('git', ['diff', '--check']);
check(diff.status === 0, 'diff_is_well_formed', diff.stderr_tail || diff.stdout_tail);
const changed = run('git', ['status', '--porcelain=v1', '--untracked-files=all']);
result.changed = changed.stdout_tail.split(/\r?\n/).filter(Boolean);
check(changed.status === 0 && result.changed.length > 0, 'candidate_has_a_patch', changed.stderr_tail);

let job;
try { job = JSON.parse(text('jobs/whatsapp-copilot.json')); } catch (error) { result.job_parse_error = error.message; }
const env = job && job.action && job.action.env;
check(env && typeof env === 'object' && !Array.isArray(env), 'job_has_action_env');
check(env && String(env.WA_WHATSAPP_MAX_AGE_SECONDS) === '600', 'job_default_max_is_600');
check(env && String(env.WA_WHATSAPP_GRACE_SECONDS) === '300', 'job_default_grace_is_300');
check(env && Object.keys(env).sort().join(',') === 'WA_WHATSAPP_GRACE_SECONDS,WA_WHATSAPP_MAX_AGE_SECONDS',
  'job_exposes_only_requested_controls', env && Object.keys(env).join(','));

const jobs = text('rust/wa-jobs/src/lib.rs');
const sentinel = text('rust/wa-sentinel/src/jobs.rs');
const docs = text('docs/JOBS.md') + '\n' + text('docs/WHATSAPP-COPILOT.md');
for (const name of ['WA_WHATSAPP_MAX_AGE_SECONDS', 'WA_WHATSAPP_GRACE_SECONDS']) {
  check(jobs.includes(name), `schema_names_${name}`);
  check(docs.includes(name), `docs_name_${name}`);
}
check(/action_env\s*\(/.test(sentinel) && /spec\.env/.test(sentinel),
  'sentinel_uses_validated_env', 'expected validated action env to reach operation specs');

const integration = path.join(repo, 'rust', 'wa-jobs', 'tests', 'benchmark_job_env.rs');
fs.mkdirSync(path.dirname(integration), { recursive: true });
if (fs.existsSync(integration)) {
  check(false, 'external_test_path_was_clean', integration);
} else {
  const source = String.raw`use serde_json::{json, Value};

fn script() -> String {
    std::env::current_dir().unwrap().join("benchmark-step.sh").to_string_lossy().into_owned()
}
fn pipeline(env: Value) -> Value {
    json!({"kind":"pipeline","env":env,"steps":[{"kind":"run","script":script()}]})
}
fn rejects(action: Value) -> bool { wa_jobs::validate_action(&action).is_err() }

#[test]
fn external_job_control_contract() {
    assert!(wa_jobs::validate_action(&pipeline(json!({
        "WA_WHATSAPP_MAX_AGE_SECONDS":"600", "WA_WHATSAPP_GRACE_SECONDS":"300"
    }))).is_ok());
    assert!(wa_jobs::validate_action(&pipeline(json!({
        "WA_WHATSAPP_MAX_AGE_SECONDS":600, "WA_WHATSAPP_GRACE_SECONDS":0
    }))).is_ok());
    assert!(rejects(pipeline(json!({"PATH":"600"}))));
    assert!(rejects(pipeline(json!({"WA_WHATSAPP_MAX_AGE_SECONDS":"5m"}))));
    assert!(rejects(pipeline(json!({"WA_WHATSAPP_MAX_AGE_SECONDS":0}))));
    assert!(rejects(pipeline(json!({"WA_WHATSAPP_MAX_AGE_SECONDS":86401}))));
    assert!(rejects(pipeline(json!({"WA_WHATSAPP_GRACE_SECONDS":86401}))));
    assert!(rejects(pipeline(json!({
        "WA_WHATSAPP_MAX_AGE_SECONDS":300, "WA_WHATSAPP_GRACE_SECONDS":600
    }))));
    assert!(rejects(json!({"kind":"subagent","profile":"x","prompt":"y","env":{
        "WA_WHATSAPP_GRACE_SECONDS":300
    }})));
    assert!(rejects(json!({"kind":"pipeline","steps":[{"kind":"run","script":script(),"env":{
        "WA_WHATSAPP_GRACE_SECONDS":300
    }}]})));
}

#[test]
fn external_artifact_keeps_controls() {
    let job = json!({"id":"window","name":"Window","trigger":{"kind":"schedule","every_seconds":30},
        "action":{"kind":"run","script":script(),"timeout_seconds":60,"env":{
            "WA_WHATSAPP_MAX_AGE_SECONDS":"600","WA_WHATSAPP_GRACE_SECONDS":"300"
        }}});
    let artifact = wa_jobs::artifact::export_artifact(&job).expect("the allowlisted controls export");
    assert_eq!(artifact["action"]["env"]["WA_WHATSAPP_MAX_AGE_SECONDS"], "600");
    assert_eq!(artifact["action"]["env"]["WA_WHATSAPP_GRACE_SECONDS"], "300");
    let imported = wa_jobs::artifact::import_artifact(&artifact, &json!({"script":script()}),
        true, "operator").expect("the allowlisted controls import");
    assert_eq!(imported["action"]["env"], job["action"]["env"]);
}
`;
  fs.writeFileSync(integration, source);
  try {
    const contract = run('cargo', ['test', '--offline', '--manifest-path', 'rust/Cargo.toml', '-p', 'wa-jobs', '--test', 'benchmark_job_env']);
    check(contract.status === 0, 'external_rust_contract', contract.stderr_tail || contract.stdout_tail);
    const compile = run('cargo', ['check', '--offline', '--manifest-path', 'rust/wa-sentinel/Cargo.toml']);
    check(compile.status === 0, 'sentinel_compiles', compile.stderr_tail || compile.stdout_tail);
  } finally {
    fs.rmSync(integration, { force: true });
    try { fs.rmdirSync(path.dirname(integration)); } catch { /* candidate may own other integration tests */ }
  }
}

const after = run('git', ['status', '--porcelain=v1', '--untracked-files=all']);
check(after.status === 0 && !after.stdout_tail.includes('benchmark_job_env.rs'),
  'verifier_removed_its_fixture', after.stderr_tail || after.stdout_tail);
result.passed = result.checks.length > 0 && result.checks.every((item) => item.ok);
if (out) {
  fs.mkdirSync(path.dirname(path.resolve(out)), { recursive: true });
  fs.writeFileSync(path.resolve(out), JSON.stringify(result, null, 2));
}
console.log(JSON.stringify(result, null, 2));
process.exit(result.passed ? 0 : 1);
