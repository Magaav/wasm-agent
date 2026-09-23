//! Experimental no-import Whisper WASM module for a warm inference benchmark.
//! This does not run in the scheduled WhatsApp job.
use base64::Engine as _;
use candle_core::{Device, IndexOp, Tensor};
use candle_nn::VarBuilder;
use candle_transformers::models::whisper::{self as m, Config};
use serde_json::{json, Value};
use std::{cell::RefCell, mem, slice};
use tokenizers::Tokenizer;
mod audio;

#[no_mangle]
unsafe extern "Rust" fn __getrandom_v03_custom(
    dest: *mut u8,
    len: usize,
) -> Result<(), getrandom::Error> {
    // Deterministic seed for this isolated benchmark. A production plugin
    // needs host-provided entropy.
    let mut seed = 0x4d595df4d0f33173u64;
    for byte in unsafe { slice::from_raw_parts_mut(dest, len) } {
        seed ^= seed << 13;
        seed ^= seed >> 7;
        seed ^= seed << 17;
        *byte = seed as u8;
    }
    Ok(())
}

struct Assets {
    weights: Vec<u8>,
    config: Vec<u8>,
    tokenizer: Vec<u8>,
    mel_filters: Vec<u8>,
}
impl Assets {
    fn new() -> Self {
        Self {
            weights: vec![],
            config: vec![],
            tokenizer: vec![],
            mel_filters: vec![],
        }
    }
}
struct Recognizer {
    model: m::model::Whisper,
    tokenizer: Tokenizer,
    filters: Vec<f32>,
    suppressed: Vec<bool>,
}
thread_local! {
    static ASSETS: RefCell<Assets> = RefCell::new(Assets::new());
    static RECOGNIZER: RefCell<Option<Recognizer>> = const { RefCell::new(None) };
}

fn answer(value: Value) -> i64 {
    let mut bytes = value.to_string().into_bytes().into_boxed_slice();
    let result = ((bytes.as_mut_ptr() as i64) << 32) | bytes.len() as i64;
    mem::forget(bytes);
    result
}
#[no_mangle]
pub extern "C" fn alloc(length: i32) -> i32 {
    let mut bytes = Vec::<u8>::with_capacity(length.max(0) as usize);
    let ptr = bytes.as_mut_ptr() as i32;
    mem::forget(bytes);
    ptr
}
#[no_mangle]
pub extern "C" fn free(ptr: i32, len: i32) {
    if ptr < 0 || len <= 0 {
        return;
    }
    let slice = std::ptr::slice_from_raw_parts_mut(ptr as *mut u8, len as usize);
    drop(unsafe { Box::from_raw(slice) });
}
#[no_mangle]
pub extern "C" fn describe() -> i64 {
    answer(
        json!({"name":"whatsapp_speech","surface":"internal","description":"Local Whisper speech recognition","parameters":{"type":"object"}}),
    )
}
// Binary asset transfer happens once per process. The host reads local files;
// the WASM module has no filesystem or network imports.
#[no_mangle]
pub extern "C" fn asset(slot: i32, ptr: i32, len: i32) -> i32 {
    if ptr < 0 || len <= 0 || !(0..=3).contains(&slot) {
        return -1;
    }
    let bytes = unsafe { Vec::from_raw_parts(ptr as *mut u8, len as usize, len as usize) };
    ASSETS.with_borrow_mut(|a| match slot {
        0 => a.weights = bytes,
        1 => a.config = bytes,
        2 => a.tokenizer = bytes,
        3 => a.mel_filters = bytes,
        _ => unreachable!(),
    });
    0
}
fn initialize() -> Result<Value, String> {
    ASSETS.with_borrow_mut(|assets| -> Result<Value, String> {
        let config: Config = serde_json::from_slice(&assets.config).map_err(|e| e.to_string())?;
        let tokenizer = Tokenizer::from_bytes(&assets.tokenizer).map_err(|e| e.to_string())?;
        let tensors = safetensors::SafeTensors::deserialize(&assets.mel_filters)
            .map_err(|e| e.to_string())?;
        let filter = tensors.tensor("mel_80").map_err(|e| e.to_string())?;
        let filters: Vec<f32> = filter
            .data()
            .chunks_exact(4)
            .map(|v| f32::from_le_bytes(v.try_into().unwrap()))
            .collect();
        let weights = mem::take(&mut assets.weights);
        let vb = VarBuilder::from_buffered_safetensors(weights, m::DTYPE, &Device::Cpu)
            .map_err(|e| e.to_string())?;
        let model = m::model::Whisper::load(&vb, config).map_err(|e| e.to_string())?;
        let mut suppressed = vec![false; model.config.vocab_size];
        for &token in &model.config.suppress_tokens {
            if let Some(entry) = suppressed.get_mut(token as usize) {
                *entry = true;
            }
        }
        RECOGNIZER.with_borrow_mut(|r| {
            *r = Some(Recognizer {
                model,
                tokenizer,
                filters,
                suppressed,
            })
        });
        Ok(json!({"ok":true}))
    })
}
fn transcribe(value: &Value) -> Result<Value, String> {
    let audio = value
        .get("pcm_f32_base64")
        .and_then(Value::as_str)
        .ok_or("pcm_f32_base64_required")?;
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(audio)
        .map_err(|e| e.to_string())?;
    if bytes.len() % 4 != 0 || bytes.len() > 4 * 16000 * 30 {
        return Err("invalid_audio_length".into());
    }
    let samples: Vec<f32> = bytes
        .chunks_exact(4)
        .map(|v| f32::from_le_bytes(v.try_into().unwrap()))
        .collect();
    let language = value
        .get("language")
        .and_then(Value::as_str)
        .unwrap_or("en");
    RECOGNIZER.with_borrow_mut(|cell| {
        let r = cell.as_mut().ok_or("model_not_initialized")?;
        r.model.reset_kv_cache();
        let config = &r.model.config;
        let mel = audio::pcm_to_mel(config, &samples, &r.filters);
        let mel_len = mel.len() / config.num_mel_bins;
        let mel = Tensor::from_vec(mel, (1, config.num_mel_bins, mel_len), &Device::Cpu)
            .map_err(|e| e.to_string())?;
        let features = r
            .model
            .encoder
            .forward(&mel, true)
            .map_err(|e| e.to_string())?;
        let token = |s: &str| {
            r.tokenizer
                .token_to_id(s)
                .ok_or_else(|| format!("missing_token:{s}"))
        };
        let eot = token(m::EOT_TOKEN)?;
        let mut ids = vec![
            token(m::SOT_TOKEN)?,
            token(&format!("<|{language}|>"))?,
            token(m::TRANSCRIBE_TOKEN)?,
            token(m::NO_TIMESTAMPS_TOKEN)?,
        ];
        for step in 0..config.max_target_positions / 2 {
            let input = Tensor::new(ids.as_slice(), &Device::Cpu)
                .and_then(|x| x.unsqueeze(0))
                .map_err(|e| e.to_string())?;
            let ys = r
                .model
                .decoder
                .forward(&input, &features, step == 0)
                .map_err(|e| e.to_string())?;
            let (_, seq_len, _) = ys.dims3().map_err(|e| e.to_string())?;
            let logits = r
                .model
                .decoder
                .final_linear(&ys.i((..1, seq_len - 1..)).map_err(|e| e.to_string())?)
                .and_then(|x| x.i((0, 0)))
                .map_err(|e| e.to_string())?;
            let values = logits.to_vec1::<f32>().map_err(|e| e.to_string())?;
            let next = values
                .iter()
                .enumerate()
                .filter(|(i, _)| !r.suppressed[*i])
                .max_by(|a, b| a.1.total_cmp(b.1))
                .ok_or("empty_logits")?
                .0 as u32;
            if next == eot {
                break;
            }
            ids.push(next);
        }
        let transcript = r.tokenizer.decode(&ids, true).map_err(|e| e.to_string())?;
        Ok(json!({"ok":true,"transcript":transcript.trim(),"language":language}))
    })
}
#[no_mangle]
pub extern "C" fn call(ptr: i32, len: i32) -> i64 {
    let result = (|| -> Result<Value, String> {
        if ptr < 0 || len < 0 || len > 3_000_000 {
            return Err("invalid_input_length".into());
        }
        // Consume the buffer allocated by alloc so repeated calls stay warm
        // without retaining every base64 audio request in linear memory.
        let bytes = unsafe { Vec::from_raw_parts(ptr as *mut u8, len as usize, len as usize) };
        let value: Value = serde_json::from_slice(&bytes).map_err(|e| e.to_string())?;
        match value.get("op").and_then(Value::as_str) {
            Some("initialize") => initialize(),
            Some("transcribe") => transcribe(&value),
            _ => Err("invalid_op".into()),
        }
    })();
    answer(result.unwrap_or_else(|error| json!({"ok":false,"error":error})))
}
