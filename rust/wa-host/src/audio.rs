//! `host.audio`: the device-effect capability that moves PCM between a file and the agent.
//!
//! Voice is a WASM plugin shared across devices (`rust/plugins/voice`), not the browser's Web
//! Speech, so the audio *transport* has to be a capability the host owns and every surface can see:
//! the CLI, `/health`, the sandbox and the Lua core all read the same [`crate::capabilities`]
//! registry. This module is the null implementation of that contract - a file-backed ear and mouth
//! that needs no microphone and no network:
//!
//! - `host.audio("capture", {path, rate, channels, chunk_ms})` returns the next chunk of PCM from a
//!   WAV file as `{pcm_base64, rate, channels, samples, offset, eof}`, or **nil** when there is no
//!   source (the file is absent, or has been read to its end - the documented spelling of "missing":
//!   a value, never zero values). `restart: true` is the explicit way back to the first sample.
//! - `host.audio("play", {path, rate, channels, samples | pcm_base64, final})` is the mirror: it
//!   writes a WAV to a path, appending chunk by chunk.
//!
//! Both are incapable of touching an arbitrary path. The declared root - `WASM_AGENT_AUDIO_ROOT`,
//! or `<home>/.wasm-agent/audio` - is the *only* directory either call may name, containment is
//! checked on the canonical path (so a symlink out is refused), and a refusal is a named error
//! (`audio_path_outside_root:...`), never `nil`: "no source" and "not allowed" must not look alike.
//!
//! The WAV reader is hand-written (RIFF/WAVE, 16-bit PCM) on purpose: this wave adds no dependency
//! to the shipped binary for a format this small, and the parser is the part the tests can pin by
//! sample offset. Real microphone capture (cpal/AAudio) is a later wave, deliberately absent.

use crate::lua::{arg_string, lua_pushlstring, lua_pushnil, LuaState};
use base64::Engine as _;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::ffi::{c_char, c_int};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};

/// Bytes of PCM one call will accept (a sink) or hand back in total (a source).
///
/// Bounded like every other host surface: a caller cannot make the process hold an unbounded file,
/// and a plugin cannot make it hold one either.
const MAX_PCM_BYTES: usize = 32 << 20;
/// Default chunk handed to the caller: 100 ms at the source's rate.
const DEFAULT_CHUNK_MS: u32 = 100;
/// Largest single chunk, in samples, so one call cannot return the whole file.
const MAX_CHUNK_SAMPLES: usize = 1 << 16;
/// Sample rates this null implementation accepts.
const RATE_RANGE: std::ops::RangeInclusive<u32> = 8_000..=48_000;

/// A WAV file opened for capture: its samples and how far the caller has read.
struct Source {
    samples: Vec<i16>,
    rate: u32,
    channels: u16,
    cursor: usize,
}

/// A sink being written: PCM accumulated in memory, rewritten as a complete WAV on every call so a
/// reader never sees a header that disagrees with the data already on disk.
struct Sink {
    samples: Vec<i16>,
    rate: u32,
    channels: u16,
}

static SOURCES: OnceLock<Mutex<HashMap<String, Source>>> = OnceLock::new();
static SINKS: OnceLock<Mutex<HashMap<String, Sink>>> = OnceLock::new();

fn sources() -> &'static Mutex<HashMap<String, Source>> {
    SOURCES.get_or_init(|| Mutex::new(HashMap::new()))
}

fn sinks() -> &'static Mutex<HashMap<String, Sink>> {
    SINKS.get_or_init(|| Mutex::new(HashMap::new()))
}

/// The directory both calls are confined to. Explicit override first, then the node's own home -
/// not `HOME` read here, but [`crate::resolve_home`], so a candidate node's `WASM_AGENT_HOME` moves
/// the fixtures with it instead of writing into the operator's real home.
fn declared_root() -> PathBuf {
    if let Ok(explicit) = std::env::var("WASM_AGENT_AUDIO_ROOT") {
        let explicit = explicit.trim().to_string();
        if !explicit.is_empty() {
            return PathBuf::from(explicit);
        }
    }
    PathBuf::from(crate::resolve_home())
        .join(".wasm-agent")
        .join("audio")
}

/// The declared root, existing, canonical. Creating it is part of declaring it: containment is
/// checked against this canonical form, so the directory has to be real before anything is named.
fn root() -> Result<PathBuf, String> {
    let root = declared_root();
    std::fs::create_dir_all(&root).map_err(|error| format!("audio_root_unavailable:{error}"))?;
    std::fs::canonicalize(&root).map_err(|error| format!("audio_root_unavailable:{error}"))
}

/// Resolve a caller-named path to a file inside the declared root, or refuse by name.
///
/// Absoluteness is not the test - containment is. A relative name must be a single ordinary
/// component (no separators, no `..`), an absolute path must resolve inside the root, and the
/// canonical form is what is compared, so a symlink or junction pointing out is refused too.
fn resolve_in_root(requested: &str) -> Result<PathBuf, String> {
    let requested = requested.trim();
    if requested.is_empty() {
        return Err("audio_path_required".to_string());
    }
    let root = root()?;
    let outside = || format!("audio_path_outside_root:{requested}");
    let candidate = Path::new(requested);
    let joined = if candidate.is_absolute() {
        candidate.to_path_buf()
    } else {
        let mut components = candidate.components();
        let first = components.next();
        let single = components.next().is_none();
        if !single || !matches!(first, Some(std::path::Component::Normal(_))) {
            return Err(outside());
        }
        root.join(candidate)
    };
    if joined
        .components()
        .any(|component| matches!(component, std::path::Component::ParentDir))
    {
        return Err(outside());
    }
    if joined.exists() {
        let real = std::fs::canonicalize(&joined)
            .map_err(|error| format!("audio_path_unresolvable:{requested}:{error}"))?;
        return if real.starts_with(&root) {
            Ok(real)
        } else {
            Err(outside())
        };
    }
    // Not created yet (a sink, normally): the parent must be inside the root, and the final
    // component must be an ordinary name, so the file cannot land anywhere else.
    let parent = joined.parent().unwrap_or(&root).to_path_buf();
    let real_parent =
        std::fs::canonicalize(&parent).map_err(|_| format!("audio_path_outside_root:{requested}"))?;
    if !real_parent.starts_with(&root) {
        return Err(outside());
    }
    let name = joined
        .file_name()
        .ok_or_else(|| format!("audio_path_invalid:{requested}"))?;
    Ok(real_parent.join(name))
}

/// Read a 16-bit PCM RIFF/WAVE file. Hand-written: no dependency for a 44-byte header and one
/// little-endian sample type, and every refusal below is a name a caller can act on.
fn parse_wav(bytes: &[u8]) -> Result<(u32, u16, Vec<i16>), String> {
    if bytes.len() < 12 || &bytes[0..4] != b"RIFF" || &bytes[8..12] != b"WAVE" {
        return Err("audio_wav_malformed:not_riff_wave".to_string());
    }
    let mut offset = 12usize;
    let mut format: Option<(u16, u16, u32, u16)> = None;
    let mut data: Option<&[u8]> = None;
    while offset + 8 <= bytes.len() {
        let id = &bytes[offset..offset + 4];
        let size = u32::from_le_bytes(bytes[offset + 4..offset + 8].try_into().expect("4 bytes")) as usize;
        let start = offset + 8;
        let end = start
            .checked_add(size)
            .ok_or_else(|| "audio_wav_malformed:chunk_overflow".to_string())?;
        if end > bytes.len() {
            return Err("audio_wav_malformed:truncated_chunk".to_string());
        }
        if id == b"fmt " {
            if size < 16 {
                return Err("audio_wav_malformed:short_fmt".to_string());
            }
            let encoding = u16::from_le_bytes(bytes[start..start + 2].try_into().expect("2 bytes"));
            let channels = u16::from_le_bytes(bytes[start + 2..start + 4].try_into().expect("2 bytes"));
            let rate = u32::from_le_bytes(bytes[start + 4..start + 8].try_into().expect("4 bytes"));
            let bits = u16::from_le_bytes(bytes[start + 14..start + 16].try_into().expect("2 bytes"));
            format = Some((encoding, channels, rate, bits));
        } else if id == b"data" {
            data = Some(&bytes[start..end]);
        }
        // Chunks are word aligned; an odd size is followed by one pad byte.
        offset = end + (size & 1);
    }
    let (encoding, channels, rate, bits) =
        format.ok_or_else(|| "audio_wav_malformed:missing_fmt".to_string())?;
    let data = data.ok_or_else(|| "audio_wav_malformed:missing_data".to_string())?;
    if encoding != 1 {
        return Err(format!("audio_wav_unsupported:encoding:{encoding}"));
    }
    if bits != 16 {
        return Err(format!("audio_wav_unsupported:bits:{bits}"));
    }
    if !(1..=2).contains(&channels) {
        return Err(format!("audio_wav_unsupported:channels:{channels}"));
    }
    if !RATE_RANGE.contains(&rate) {
        return Err(format!("audio_wav_unsupported:rate:{rate}"));
    }
    let block = channels as usize * 2;
    if data.len() % block != 0 {
        return Err("audio_wav_malformed:data_alignment".to_string());
    }
    let samples = data
        .chunks_exact(2)
        .map(|pair| i16::from_le_bytes([pair[0], pair[1]]))
        .collect();
    Ok((rate, channels, samples))
}

/// The complete WAV for a sink's samples: a 44-byte canonical header and 16-bit little-endian data.
fn wav_bytes(samples: &[i16], rate: u32, channels: u16) -> Vec<u8> {
    let data_bytes = samples.len() * 2;
    let mut out = Vec::with_capacity(44 + data_bytes);
    out.extend_from_slice(b"RIFF");
    out.extend_from_slice(&((36 + data_bytes) as u32).to_le_bytes());
    out.extend_from_slice(b"WAVE");
    out.extend_from_slice(b"fmt ");
    out.extend_from_slice(&16u32.to_le_bytes());
    out.extend_from_slice(&1u16.to_le_bytes()); // PCM
    out.extend_from_slice(&channels.to_le_bytes());
    out.extend_from_slice(&rate.to_le_bytes());
    out.extend_from_slice(&(rate * channels as u32 * 2).to_le_bytes()); // byte rate
    out.extend_from_slice(&(channels * 2).to_le_bytes()); // block align
    out.extend_from_slice(&16u16.to_le_bytes()); // bits per sample
    out.extend_from_slice(b"data");
    out.extend_from_slice(&(data_bytes as u32).to_le_bytes());
    for sample in samples {
        out.extend_from_slice(&sample.to_le_bytes());
    }
    out
}

/// Decode a `pcm_base64` payload into little-endian 16-bit samples.
fn decode_pcm(text: &str) -> Result<Vec<i16>, String> {
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(text.trim())
        .map_err(|_| "audio_invalid_base64".to_string())?;
    if bytes.len() % 2 != 0 {
        return Err("audio_invalid_pcm_alignment".to_string());
    }
    Ok(bytes
        .chunks_exact(2)
        .map(|pair| i16::from_le_bytes([pair[0], pair[1]]))
        .collect())
}

fn capture(args: &Value) -> Result<Value, String> {
    let requested = args.get("path").and_then(Value::as_str).unwrap_or_default();
    let path = resolve_in_root(requested)?;
    if !path.is_file() {
        // No source: `nil`, the documented spelling of a missing value. It is *not* what an
        // escaped path returns - that was refused above by name.
        return Ok(Value::Null);
    }
    let key = path.to_string_lossy().replace('\\', "/");
    let mut map = sources().lock().map_err(|_| "audio_source_lock".to_string())?;
    if !map.contains_key(&key) {
        let bytes = std::fs::read(&path).map_err(|error| format!("audio_source_unreadable:{error}"))?;
        if bytes.len() > MAX_PCM_BYTES {
            return Err(format!("audio_source_too_large:{}", bytes.len()));
        }
        let (rate, channels, samples) = parse_wav(&bytes)?;
        map.insert(
            key.clone(),
            Source {
                samples,
                rate,
                channels,
                cursor: 0,
            },
        );
    }
    let source = map.get_mut(&key).expect("source inserted above");
    if let Some(rate) = args.get("rate").and_then(Value::as_u64) {
        if rate != source.rate as u64 {
            return Err(format!("audio_rate_mismatch:file={} requested={rate}", source.rate));
        }
    }
    if let Some(channels) = args.get("channels").and_then(Value::as_u64) {
        if channels != source.channels as u64 {
            return Err(format!(
                "audio_channels_mismatch:file={} requested={channels}",
                source.channels
            ));
        }
    }
    if source.cursor >= source.samples.len() {
        // Read to its end: `nil`, and the entry stays so a later call cannot silently restart the
        // source under a caller that believed it was finished. `restart` is the explicit way back.
        if args.get("restart").and_then(Value::as_bool) == Some(true) {
            source.cursor = 0;
        } else {
            return Ok(Value::Null);
        }
    }
    let chunk_ms = args
        .get("chunk_ms")
        .and_then(Value::as_u64)
        .unwrap_or(DEFAULT_CHUNK_MS as u64)
        .clamp(1, 1_000) as usize;
    let wanted = (source.rate as usize * chunk_ms / 1000).clamp(1, MAX_CHUNK_SAMPLES);
    let offset = source.cursor;
    let end = (offset + wanted).min(source.samples.len());
    let chunk = &source.samples[offset..end];
    let mut bytes = Vec::with_capacity(chunk.len() * 2);
    for sample in chunk {
        bytes.extend_from_slice(&sample.to_le_bytes());
    }
    source.cursor = end;
    let value = json!({
        "ok": true,
        "path": key,
        "pcm_base64": base64::engine::general_purpose::STANDARD.encode(&bytes),
        "rate": source.rate,
        "channels": source.channels,
        "samples": chunk.len(),
        "offset": offset,
        "eof": end >= source.samples.len(),
    });
    Ok(value)
}

fn play(args: &Value) -> Result<Value, String> {
    let requested = args.get("path").and_then(Value::as_str).unwrap_or_default();
    let path = resolve_in_root(requested)?;
    if path.is_dir() {
        return Err(format!("audio_sink_is_directory:{requested}"));
    }
    let rate = args.get("rate").and_then(Value::as_u64).unwrap_or(16_000) as u32;
    if !RATE_RANGE.contains(&rate) {
        return Err(format!("audio_rate_unsupported:{rate}"));
    }
    let channels = args.get("channels").and_then(Value::as_u64).unwrap_or(1) as u16;
    if !(1..=2).contains(&channels) {
        return Err(format!("audio_channels_unsupported:{channels}"));
    }
    let mut incoming: Vec<i16> = Vec::new();
    if let Some(text) = args.get("pcm_base64").and_then(Value::as_str) {
        incoming.extend(decode_pcm(text)?);
    }
    if let Some(samples) = args.get("samples").and_then(Value::as_array) {
        for (index, sample) in samples.iter().enumerate() {
            let value = sample
                .as_i64()
                .ok_or_else(|| format!("audio_sample_not_integer:{index}"))?;
            let value = i16::try_from(value)
                .map_err(|_| format!("audio_sample_out_of_range:{index}"))?;
            incoming.push(value);
        }
    }
    let key = path.to_string_lossy().replace('\\', "/");
    let mut map = sinks().lock().map_err(|_| "audio_sink_lock".to_string())?;
    let sink = map.entry(key.clone()).or_insert(Sink {
        samples: Vec::new(),
        rate,
        channels,
    });
    if sink.rate != rate || sink.channels != channels {
        return Err(format!(
            "audio_sink_format_conflict:rate={} channels={} requested_rate={rate} requested_channels={channels}",
            sink.rate, sink.channels
        ));
    }
    if (sink.samples.len() + incoming.len()) * 2 > MAX_PCM_BYTES {
        return Err(format!("audio_sink_too_large:{}", sink.samples.len() * 2));
    }
    sink.samples.extend_from_slice(&incoming);
    let bytes = wav_bytes(&sink.samples, sink.rate, sink.channels);
    let total = sink.samples.len();
    let sink_rate = sink.rate;
    let sink_channels = sink.channels;
    // Write first, then forget: a failed write must leave the accumulated PCM in place, or a retry
    // would silently restart the sink and produce a shorter WAV than the caller already reported.
    std::fs::write(&path, &bytes).map_err(|error| format!("audio_sink_unwritable:{error}"))?;
    if args.get("final").and_then(Value::as_bool).unwrap_or(false) {
        map.remove(&key);
    }
    Ok(json!({
        "ok": true,
        "path": key,
        "rate": sink_rate,
        "channels": sink_channels,
        "samples": total,
        "bytes": bytes.len(),
    }))
}

fn dispatch(action: &str, args: &str) -> Result<Value, String> {
    let args: Value = if args.trim().is_empty() {
        json!({})
    } else {
        serde_json::from_str(args).map_err(|error| format!("audio_invalid_arguments:{error}"))?
    };
    match action {
        "capture" => capture(&args),
        "play" => play(&args),
        other => Err(format!("audio_unknown_action:{other}")),
    }
}

/// `host.audio(action, args_json)` -> JSON result | nil.
///
/// One capability, two calls (`capture`, `play`), because that is how it appears in the registry
/// and therefore in `wa capabilities --json`, `/health` and the sandbox: one name, one effect class.
pub extern "C-unwind" fn capability(l: *mut LuaState) -> c_int {
    let action = arg_string(l, 1).unwrap_or_default();
    let args = arg_string(l, 2).unwrap_or_else(|| "{}".into());
    match dispatch(&action, &args) {
        Ok(Value::Null) => unsafe {
            lua_pushnil(l);
            1
        },
        Ok(value) => {
            let text = value.to_string();
            unsafe { lua_pushlstring(l, text.as_ptr() as *const c_char, text.len()) };
            1
        }
        Err(error) => {
            let text = json!({"ok": false, "error": error}).to_string();
            unsafe { lua_pushlstring(l, text.as_ptr() as *const c_char, text.len()) };
            1
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// One root for the whole module, because `WASM_AGENT_AUDIO_ROOT` is process state and these
    /// tests share one process. Every test takes this lock, so a sibling's temp root cannot become
    /// this test's declared root half-way through.
    fn fixture_root() -> std::sync::MutexGuard<'static, ()> {
        static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
        let guard = LOCK
            .get_or_init(|| Mutex::new(()))
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let root = std::env::temp_dir().join(format!("wa-audio-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).expect("fixture root");
        std::env::set_var("WASM_AGENT_AUDIO_ROOT", &root);
        sources().lock().unwrap().clear();
        sinks().lock().unwrap().clear();
        guard
    }

    fn fixture_samples() -> Vec<i16> {
        // 0.5 s silence, 0.4 s of a 200 Hz burst at 16 kHz, 0.5 s silence: the same shape the
        // end-to-end Lua fixture uses, so the two disagree loudly if either drifts.
        let rate = 16_000u32;
        let mut samples = vec![0i16; 8_000];
        for index in 1..=6_400u32 {
            let value = (12_000.0
                * (2.0 * std::f64::consts::PI * 200.0 * index as f64 / rate as f64).sin())
            .round();
            samples.push(value as i16);
        }
        samples.extend(std::iter::repeat(0i16).take(8_000));
        samples
    }

    #[test]
    fn a_written_wav_reads_back_with_its_samples_intact() {
        let _guard = fixture_root();
        let samples: Vec<i16> = vec![0, 1, -1, 32_767, -32_768, 7];
        let bytes = wav_bytes(&samples, 16_000, 1);
        let (rate, channels, parsed) = parse_wav(&bytes).expect("our own WAV parses");
        assert_eq!(rate, 16_000);
        assert_eq!(channels, 1);
        assert_eq!(parsed, samples);
    }

    #[test]
    fn capture_pages_through_the_source_and_then_reports_no_source() {
        let _guard = fixture_root();
        let path = declared_root().join("pages.wav");
        std::fs::write(&path, wav_bytes(&fixture_samples(), 16_000, 1)).expect("write fixture");
        let mut offsets = Vec::new();
        let mut total = 0usize;
        loop {
            let chunk = capture(&json!({"path": "pages.wav", "rate": 16_000, "chunk_ms": 100}))
                .expect("capture");
            if chunk.is_null() {
                break;
            }
            assert_eq!(chunk["rate"], 16_000);
            assert_eq!(chunk["channels"], 1);
            offsets.push(chunk["offset"].as_u64().unwrap());
            total += chunk["samples"].as_u64().unwrap() as usize;
        }
        assert_eq!(total, 8_000 + 6_400 + 8_000);
        assert_eq!(offsets.first().copied(), Some(0));
        // 100 ms at 16 kHz is 1600 samples: 22400 samples is 14 whole chunks.
        assert_eq!(offsets.len(), 14);
        assert_eq!(*offsets.last().unwrap(), 20_800);
        // The source is gone once read, so the next capture is `nil`, not an error.
        assert!(capture(&json!({"path": "pages.wav"})).expect("capture").is_null());
    }

    #[test]
    fn a_missing_file_is_nil_and_an_escaped_path_is_a_named_refusal() {
        let _guard = fixture_root();
        assert!(capture(&json!({"path": "absent.wav"})).expect("missing is nil").is_null());
        let escaped = capture(&json!({"path": "../outside.wav"})).expect_err("must refuse");
        assert!(escaped.starts_with("audio_path_outside_root:"), "{escaped}");
        let absolute = std::env::temp_dir().join("wa-audio-absolute-escape.wav");
        let escaped = capture(&json!({"path": absolute.to_string_lossy()})).expect_err("must refuse");
        assert!(escaped.starts_with("audio_path_outside_root:"), "{escaped}");
        let sunk = play(&json!({"path": "../outside.wav", "samples": [1, 2]})).expect_err("must refuse");
        assert!(sunk.starts_with("audio_path_outside_root:"), "{sunk}");
        let nested = play(&json!({"path": "sub/nested.wav", "samples": [1, 2]})).expect_err("must refuse");
        assert!(nested.starts_with("audio_path_outside_root:"), "{nested}");
    }

    #[test]
    fn the_sink_round_trips_through_capture_by_sample_offset() {
        let _guard = fixture_root();
        let wrote = play(&json!({
            "path": "roundtrip.wav",
            "rate": 16_000,
            "channels": 1,
            "samples": fixture_samples(),
            "final": true,
        }))
        .expect("play");
        assert_eq!(wrote["samples"], 22_400);
        let mut chunks = 0;
        let mut last_eof = false;
        while let Some(chunk) = {
            let value = capture(&json!({"path": "roundtrip.wav", "chunk_ms": 20})).expect("capture");
            if value.is_null() { None } else { Some(value) }
        } {
            chunks += 1;
            last_eof = chunk["eof"].as_bool().unwrap();
            assert_eq!(chunk["samples"], 320);
        }
        assert_eq!(chunks, 70);
        assert!(last_eof, "the last chunk must say eof");
    }

    #[test]
    fn malformed_wav_bytes_are_a_named_error_not_a_panic() {
        assert_eq!(parse_wav(b"not a wave").unwrap_err(), "audio_wav_malformed:not_riff_wave");
        let mut truncated = wav_bytes(&[1i16, 2, 3], 16_000, 1);
        truncated.truncate(46);
        assert_eq!(
            parse_wav(&truncated).unwrap_err(),
            "audio_wav_malformed:truncated_chunk"
        );
        let mut float = wav_bytes(&[1i16, 2], 16_000, 1);
        float[20..22].copy_from_slice(&3u16.to_le_bytes()); // IEEE float encoding
        assert_eq!(parse_wav(&float).unwrap_err(), "audio_wav_unsupported:encoding:3");
        let mut odd = wav_bytes(&[1i16, 2], 16_000, 1);
        let data_size = odd.windows(4).position(|w| w == b"data").expect("data chunk") + 4;
        odd[data_size..data_size + 4].copy_from_slice(&3u32.to_le_bytes());
        assert_eq!(
            parse_wav(&odd).unwrap_err(),
            "audio_wav_malformed:data_alignment"
        );
    }

    #[test]
    fn a_rate_that_disagrees_with_the_file_is_refused_rather_than_resampled() {
        let _guard = fixture_root();
        std::fs::write(
            declared_root().join("rate.wav"),
            wav_bytes(&[0i16; 16], 16_000, 1),
        )
        .expect("write");
        let error = capture(&json!({"path": "rate.wav", "rate": 8_000})).expect_err("must refuse");
        assert_eq!(error, "audio_rate_mismatch:file=16000 requested=8000");
    }

    #[test]
    fn unknown_actions_and_bad_arguments_are_named() {
        let _guard = fixture_root();
        assert_eq!(
            dispatch("listen", "{}").unwrap_err(),
            "audio_unknown_action:listen"
        );
        assert!(dispatch("capture", "{not json")
            .unwrap_err()
            .starts_with("audio_invalid_arguments:"));
        assert_eq!(
            play(&json!({"path": "x.wav", "samples": [70_000]})).unwrap_err(),
            "audio_sample_out_of_range:0"
        );
        assert_eq!(
            play(&json!({"path": "x.wav", "rate": 7})).unwrap_err(),
            "audio_rate_unsupported:7"
        );
    }
}
