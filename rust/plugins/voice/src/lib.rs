//! `voice.wasm`: the portable voice core.
//!
//! Voice is a WASM plugin shared across devices, not the browser's Web Speech API, and this crate
//! is the part that owns the *decisions*: frame segmentation, energy/ZCR voice-activity detection,
//! utterance start/end events with sample-accurate timestamps, and the wake-word match interface.
//! It receives PCM the host already captured (`host.audio("capture", ...)`) and never blocks: there
//! is no clock, no filesystem, no WASI import and no thread here - the module imports nothing at all,
//! so the existing loader instantiates it with `&[]` imports, exactly like `echo` and
//! `whatsapp-transcript`. (The wave brief calls it "wasm32-wasi" meaning a portable wasm module; the
//! loader links no WASI, so a module with imports would not load. Zero imports is the stronger
//! contract and the one testable here.)
//!
//! ## ABI
//!
//! Same tiny ABI as every plugin (`rust/wa-host/src/plugins.rs`): `memory`, `alloc(len)`,
//! `describe() -> i64`, `call(ptr, len) -> i64`, each JSON result packed `ptr << 32 | len`. The
//! plugin is `"surface":"internal"`: deterministic, callable from trusted Lua, not advertised as a
//! model tool. State lives in the instance (the host keeps the store alive between calls), so a
//! run is `configure` once, `push` per chunk, `flush` at the end.
//!
//! ## Calls
//!
//! - `{"op":"configure","rate","channels","frame_ms","energy","zcr_max","start_frames","end_frames"}`
//!   -> `{"ok":true,...resolved configuration...}`. `frame_ms` defaults to 20 and `frame_samples`
//!   is `rate * frame_ms / 1000`; a frame is the fixed window every decision is made over.
//! - `{"op":"push","pcm_base64":"..."}` -> `{"ok":true,"accepted","frames",...,"events":[...]}`.
//!   PCM is 16-bit little-endian, interleaved for `channels`; the tail shorter than one frame is
//!   buffered until the next push. Events are `{"type":"utterance_start"|"utterance_end",
//!   "sample","time_ms",...}` where `sample` is the *exact* boundary - the first sample of the
//!   first voiced frame, and the end of the last voiced frame - while the event itself is emitted
//!   after the decision window that proved it.
//! - `{"op":"flush"}` -> closes an open utterance at its last voiced sample (the tail of a
//!   recording may end mid-burst). An incomplete frame is not evaluated: half a window is not
//!   evidence.
//! - `{"op":"state"}` -> counters, `{"op":"reset"}` -> clears them.
//! - `{"op":"match_wake","features":[...]}` -> the wake-word **match interface**. The model is a
//!   later wave, so this returns a *named* absence, `{"ok":false,"error":"model_absent",
//!   "model":"wake-word-stub-v0"}`, and never a fabricated confidence: a caller that branches on
//!   `ok` cannot mistake "no model" for "not the wake word", and one that branches on `confidence`
//!   gets nothing to branch on.
//!
//! Every refusal is a name (`not_configured`, `invalid_pcm_base64`, `invalid_pcm_length`,
//! `invalid_json`, ...) rather than a silent zero, so the Lua glue can report what happened.
use serde_json::{json, Value};
use std::mem;
use std::slice;

/// Largest JSON one call may carry. A chunk is a few hundred kilobytes at most; this is a fence,
/// not a budget.
const MAX_INPUT: usize = 8 << 20;
/// Largest single `push` in samples, so one call cannot make the instance allocate without bound.
const MAX_PUSH_SAMPLES: usize = 1 << 20;

const DEFAULT_FRAME_MS: u32 = 20;
/// Mean absolute amplitude, on the 16-bit scale, at or above which a frame is a candidate.
const DEFAULT_ENERGY: f64 = 500.0;
/// Zero-crossing rate above which a frame is noise rather than voice, however loud it is.
const DEFAULT_ZCR_MAX: f64 = 0.35;

#[derive(Clone, Copy)]
struct Config {
    rate: u32,
    channels: u16,
    frame_ms: u32,
    frame_samples: usize,
    energy: f64,
    zcr_max: f64,
    /// Consecutive voiced frames that turn a candidate into an utterance.
    start_frames: u32,
    /// Consecutive unvoiced frames that end it.
    end_frames: u32,
}

struct State {
    config: Option<Config>,
    /// Samples of the frame being filled; never longer than `frame_samples`.
    buffer: Vec<i16>,
    /// Completed frames since the last reset.
    frames: u64,
    frames_voiced: u64,
    /// Samples pushed since the last reset: the absolute position of the stream.
    samples: u64,
    voiced_run: u32,
    unvoiced_run: u32,
    open: bool,
    utterance_start: u64,
    last_voiced_end: u64,
    utterances: u64,
}

impl State {
    fn new() -> Self {
        State {
            config: None,
            buffer: Vec::new(),
            frames: 0,
            frames_voiced: 0,
            samples: 0,
            voiced_run: 0,
            unvoiced_run: 0,
            open: false,
            utterance_start: 0,
            last_voiced_end: 0,
            utterances: 0,
        }
    }

    fn reset(&mut self) {
        let config = self.config;
        *self = State::new();
        self.config = config;
    }

    fn time_ms(&self, sample: u64, rate: u32) -> u64 {
        sample * 1000 / rate.max(1) as u64
    }

    /// A fixed window is voiced when it is loud enough *and* slow enough in sign changes: energy
    /// alone counts a mains hum or a key click as speech, and ZCR alone counts a whisper as silence.
    fn process_frame(&mut self, config: &Config, events: &mut Vec<Value>) {
        let frame_start = self.frames * config.frame_samples as u64;
        let length = self.buffer.len().max(1);
        let mut total: u64 = 0;
        let mut crossings: u32 = 0;
        let mut previous: i32 = 0;
        for sample in &self.buffer {
            let value = i32::from(*sample);
            total += value.unsigned_abs() as u64;
            if (value > 0 && previous < 0) || (value < 0 && previous > 0) {
                crossings += 1;
            }
            if value != 0 {
                previous = value;
            }
        }
        let mean_abs = total as f64 / length as f64;
        let zcr = f64::from(crossings) / (length.max(2) - 1) as f64;
        let voiced = mean_abs >= config.energy && zcr <= config.zcr_max;
        self.frames += 1;
        self.buffer.clear();
        let frame_end = frame_start + config.frame_samples as u64;
        if voiced {
            self.frames_voiced += 1;
            self.unvoiced_run = 0;
            if self.open {
                // Already inside an utterance: only its end matters.
            } else {
                self.voiced_run += 1;
                if self.voiced_run >= config.start_frames {
                    self.open = true;
                    self.utterances += 1;
                    // The run began `voiced_run` frames ago: report the start it actually had, not
                    // the frame on which the decision became possible.
                    self.utterance_start = frame_start
                        - u64::from(self.voiced_run - 1) * config.frame_samples as u64;
                    events.push(json!({
                        "type": "utterance_start",
                        "sample": self.utterance_start,
                        "time_ms": self.time_ms(self.utterance_start, config.rate),
                        "energy": mean_abs.round() as u64,
                        "zcr": (zcr * 1000.0).round() / 1000.0,
                    }));
                }
            }
            self.last_voiced_end = frame_end;
        } else {
            self.voiced_run = 0;
            if self.open {
                self.unvoiced_run += 1;
                if self.unvoiced_run >= config.end_frames {
                    self.open = false;
                    events.push(json!({
                        "type": "utterance_end",
                        "sample": self.last_voiced_end,
                        "time_ms": self.time_ms(self.last_voiced_end, config.rate),
                        "energy": mean_abs.round() as u64,
                        "zcr": (zcr * 1000.0).round() / 1000.0,
                    }));
                }
            }
        }
    }
}

/// Guest state. One instance, one store, one thread: the host never calls `call` concurrently, and
/// `addr_of_mut!` keeps the reference out of the `static_mut_refs` lint's way.
static mut STATE: Option<State> = None;

fn state() -> &'static mut State {
    unsafe {
        let pointer = std::ptr::addr_of_mut!(STATE);
        if (*pointer).is_none() {
            *pointer = Some(State::new());
        }
        (*pointer).as_mut().expect("state initialised above")
    }
}

fn configure(args: &Value) -> Result<Value, String> {
    let rate = args.get("rate").and_then(Value::as_u64).unwrap_or(16_000);
    if !(8_000..=48_000).contains(&rate) {
        return Err(format!("rate_unsupported:{rate}"));
    }
    let channels = args.get("channels").and_then(Value::as_u64).unwrap_or(1);
    if !(1..=2).contains(&channels) {
        return Err(format!("channels_unsupported:{channels}"));
    }
    let frame_ms = args
        .get("frame_ms")
        .and_then(Value::as_u64)
        .unwrap_or(DEFAULT_FRAME_MS as u64) as u32;
    if !(1..=100).contains(&frame_ms) {
        return Err(format!("frame_ms_unsupported:{frame_ms}"));
    }
    let frame_samples = (rate as usize * frame_ms as usize) / 1000;
    if frame_samples < 16 {
        return Err(format!("frame_too_short:{frame_samples}"));
    }
    let energy = args
        .get("energy")
        .and_then(Value::as_f64)
        .unwrap_or(DEFAULT_ENERGY);
    if !energy.is_finite() || energy < 0.0 {
        return Err("energy_invalid".to_string());
    }
    let zcr_max = args
        .get("zcr_max")
        .and_then(Value::as_f64)
        .unwrap_or(DEFAULT_ZCR_MAX);
    if !zcr_max.is_finite() || !(0.0..=1.0).contains(&zcr_max) {
        return Err("zcr_max_invalid".to_string());
    }
    let start_frames = args
        .get("start_frames")
        .and_then(Value::as_u64)
        .unwrap_or(3)
        .clamp(1, 100) as u32;
    let end_frames = args
        .get("end_frames")
        .and_then(Value::as_u64)
        .unwrap_or(15)
        .clamp(1, 1000) as u32;
    let config = Config {
        rate: rate as u32,
        channels: channels as u16,
        frame_ms,
        frame_samples,
        energy,
        zcr_max,
        start_frames,
        end_frames,
    };
    let state = state();
    state.reset();
    state.config = Some(config);
    Ok(json!({
        "ok": true,
        "rate": config.rate,
        "channels": config.channels,
        "frame_ms": config.frame_ms,
        "frame_samples": config.frame_samples,
        "energy": config.energy,
        "zcr_max": config.zcr_max,
        "start_frames": config.start_frames,
        "end_frames": config.end_frames,
    }))
}

fn push(args: &Value) -> Result<Value, String> {
    let state = state();
    let config = state.config.ok_or_else(|| "not_configured".to_string())?;
    let encoded = args
        .get("pcm_base64")
        .and_then(Value::as_str)
        .ok_or_else(|| "invalid_pcm_base64".to_string())?;
    let bytes = decode_base64(encoded).map_err(|error| error.to_string())?;
    if bytes.len() % 2 != 0 {
        return Err("invalid_pcm_length".to_string());
    }
    let samples: Vec<i16> = bytes
        .chunks_exact(2)
        .map(|pair| i16::from_le_bytes([pair[0], pair[1]]))
        .collect();
    if samples.len() > MAX_PUSH_SAMPLES {
        return Err(format!("push_too_large:{}", samples.len()));
    }
    let accepted = samples.len();
    let before = state.frames;
    let mut events = Vec::new();
    for sample in samples {
        state.samples += 1;
        state.buffer.push(sample);
        if state.buffer.len() == config.frame_samples {
            state.process_frame(&config, &mut events);
        }
    }
    Ok(json!({
        "ok": true,
        "accepted": accepted,
        "frames": state.frames - before,
        "frames_total": state.frames,
        "buffered": state.buffer.len(),
        "utterances": state.utterances,
        "open": state.open,
        "events": events,
    }))
}

fn flush() -> Value {
    let state = state();
    let mut events = Vec::new();
    if state.open {
        state.open = false;
        if let Some(config) = state.config {
            events.push(json!({
                "type": "utterance_end",
                "sample": state.last_voiced_end,
                "time_ms": state.time_ms(state.last_voiced_end, config.rate),
                "flushed": true,
            }));
        }
    }
    json!({
        "ok": true,
        "events": events,
        "frames": state.frames,
        "samples": state.samples,
        "utterances": state.utterances,
        "open": state.open,
        "buffered": state.buffer.len(),
    })
}

fn state_report() -> Value {
    let state = state();
    match state.config {
        Some(config) => json!({
            "ok": true,
            "configured": true,
            "rate": config.rate,
            "channels": config.channels,
            "frame_ms": config.frame_ms,
            "frame_samples": config.frame_samples,
            "energy": config.energy,
            "zcr_max": config.zcr_max,
            "start_frames": config.start_frames,
            "end_frames": config.end_frames,
            "frames": state.frames,
            "frames_voiced": state.frames_voiced,
            "samples": state.samples,
            "utterances": state.utterances,
            "open": state.open,
            "buffered": state.buffer.len(),
        }),
        None => json!({
            "ok": true,
            "configured": false,
            "frames": state.frames,
            "samples": state.samples,
        }),
    }
}

/// The wake-word match interface. A later wave supplies the model; this is the seam, and it answers
/// with a named absence so no caller can read a confidence that was never computed.
fn match_wake(args: &Value) -> Result<Value, String> {
    let features = args
        .get("features")
        .ok_or_else(|| "features_required".to_string())?;
    let features = features
        .as_array()
        .ok_or_else(|| "features_must_be_array".to_string())?;
    if features.is_empty() {
        return Err("features_empty".to_string());
    }
    for feature in features {
        let value = feature
            .as_f64()
            .ok_or_else(|| "features_must_be_numbers".to_string())?;
        if !value.is_finite() {
            return Err("features_must_be_finite".to_string());
        }
    }
    Ok(json!({
        "ok": false,
        "error": "model_absent",
        "model": "wake-word-stub-v0",
        "features": features.len(),
    }))
}

fn dispatch(input: &[u8]) -> Value {
    let Ok(value) = serde_json::from_slice::<Value>(input) else {
        return json!({"ok": false, "error": "invalid_json"});
    };
    let op = value.get("op").and_then(Value::as_str).unwrap_or_default();
    let outcome = match op {
        "configure" => configure(&value),
        "push" => push(&value),
        "flush" => Ok(flush()),
        "state" => Ok(state_report()),
        "reset" => {
            state().reset();
            Ok(json!({"ok": true, "reset": true}))
        }
        "match_wake" => match_wake(&value),
        "" => Err("op_required".to_string()),
        other => Err(format!("unknown_op:{other}")),
    };
    match outcome {
        Ok(value) => value,
        Err(error) => json!({"ok": false, "error": error}),
    }
}

/// Hand-written standard base64 decode (the crate has no dependencies on purpose). Padding is
/// required where `=` appears; whitespace is ignored so a wrapped payload still decodes.
fn decode_base64(text: &str) -> Result<Vec<u8>, &'static str> {
    fn value_of(byte: u8) -> Option<u8> {
        match byte {
            b'A'..=b'Z' => Some(byte - b'A'),
            b'a'..=b'z' => Some(byte - b'a' + 26),
            b'0'..=b'9' => Some(byte - b'0' + 52),
            b'+' => Some(62),
            b'/' => Some(63),
            _ => None,
        }
    }
    let mut out = Vec::new();
    let mut accumulator: u32 = 0;
    let mut bits = 0u32;
    let mut padding = 0usize;
    for byte in text.bytes() {
        if byte.is_ascii_whitespace() {
            continue;
        }
        if byte == b'=' {
            padding += 1;
            continue;
        }
        if padding > 0 {
            return Err("invalid_pcm_base64");
        }
        let value = value_of(byte).ok_or("invalid_pcm_base64")?;
        accumulator = ((accumulator << 6) | u32::from(value)) & 0x00ff_ffff;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((accumulator >> bits) as u8);
        }
    }
    if bits >= 6 || padding > 2 || (padding > 0 && out.is_empty()) {
        return Err("invalid_pcm_base64");
    }
    let remainder = accumulator & ((1 << bits) - 1);
    if remainder != 0 {
        return Err("invalid_pcm_base64");
    }
    Ok(out)
}

fn reply(value: Value) -> i64 {
    let mut bytes = value.to_string().into_bytes();
    let length = bytes.len() as i64;
    let pointer = bytes.as_mut_ptr() as i64;
    mem::forget(bytes);
    (pointer << 32) | (length & 0xffff_ffff)
}

#[no_mangle]
pub extern "C" fn alloc(length: i32) -> i32 {
    let mut buffer = Vec::<u8>::with_capacity(length.max(0) as usize);
    let pointer = buffer.as_mut_ptr() as i32;
    mem::forget(buffer);
    pointer
}

#[no_mangle]
pub extern "C" fn describe() -> i64 {
    reply(json!({
        "name": "voice",
        "surface": "internal",
        "description": "Frame segmentation, energy/ZCR voice-activity detection and utterance events over host-pushed PCM, plus the wake-word match interface",
        "parameters": {
            "type": "object",
            "properties": {
                "op": {"type": "string", "enum": ["configure", "push", "flush", "state", "reset", "match_wake"]},
                "pcm_base64": {"type": "string"},
                "rate": {"type": "integer"},
                "channels": {"type": "integer"},
                "frame_ms": {"type": "integer"},
                "features": {"type": "array", "items": {"type": "number"}}
            },
            "required": ["op"]
        }
    }))
}

#[no_mangle]
pub extern "C" fn call(pointer: i32, length: i32) -> i64 {
    if pointer < 0 || length < 0 {
        return reply(json!({"ok": false, "error": "invalid_input"}));
    }
    if length as usize > MAX_INPUT {
        return reply(json!({"ok": false, "error": "input_too_large"}));
    }
    let input = unsafe { slice::from_raw_parts(pointer as *const u8, length as usize) };
    reply(dispatch(input))
}
