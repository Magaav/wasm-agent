use base64::Engine as _;
use serde_json::{json, Value};
use std::{error::Error, fs, path::PathBuf, time::Instant};
use wasmtime::{Engine, Instance, Memory, Module, Store, TypedFunc};

fn call(
    store: &mut Store<()>,
    memory: &Memory,
    alloc: &TypedFunc<i32, i32>,
    func: &TypedFunc<(i32, i32), i64>,
    free: &TypedFunc<(i32, i32), ()>,
    input: &Value,
) -> Result<Value, Box<dyn Error>> {
    let data = input.to_string();
    let ptr = alloc.call(&mut *store, data.len() as i32)?;
    memory.write(&mut *store, ptr as usize, data.as_bytes())?;
    let packed = func.call(&mut *store, (ptr, data.len() as i32))?;
    let ptr = (packed >> 32) as u32 as usize;
    let len = (packed & 0xffff_ffff) as u32 as usize;
    let mut bytes = vec![0; len];
    memory.read(&*store, ptr, &mut bytes)?;
    free.call(&mut *store, (ptr as i32, len as i32))?;
    Ok(serde_json::from_slice(&bytes)?)
}
fn main() -> Result<(), Box<dyn Error>> {
    let root = PathBuf::from(
        std::env::args()
            .nth(1)
            .expect("benchmark directory required"),
    );
    let pcm_path = PathBuf::from(
        std::env::args()
            .nth(2)
            .expect("16 kHz mono f32le PCM file required"),
    );
    let model_dir = PathBuf::from(std::env::args().nth(3).expect("model directory required"));
    let engine = Engine::default();
    let module = Module::from_file(
        &engine,
        root.join("target/wasm32-unknown-unknown/release/wa_whisper_wasm_benchmark.wasm"),
    )?;
    println!(
        "imports: {:?}",
        module
            .imports()
            .map(|x| format!("{}.{}", x.module(), x.name()))
            .collect::<Vec<_>>()
    );
    let mut store = Store::new(&engine, ());
    let instance = Instance::new(&mut store, &module, &[])?;
    let memory = instance.get_memory(&mut store, "memory").unwrap();
    let alloc = instance.get_typed_func::<i32, i32>(&mut store, "alloc")?;
    let asset = instance.get_typed_func::<(i32, i32, i32), i32>(&mut store, "asset")?;
    let func = instance.get_typed_func::<(i32, i32), i64>(&mut store, "call")?;
    let free = instance.get_typed_func::<(i32, i32), ()>(&mut store, "free")?;
    for (slot, name) in [
        "model.safetensors",
        "config.json",
        "tokenizer.json",
        "mel_filters.safetensors",
    ]
    .iter()
    .enumerate()
    {
        let bytes = fs::read(model_dir.join(name))?;
        let ptr = alloc.call(&mut store, bytes.len() as i32)?;
        memory.write(&mut store, ptr as usize, &bytes)?;
        let status = asset.call(&mut store, (slot as i32, ptr, bytes.len() as i32))?;
        if status != 0 {
            return Err(format!("asset {name} failed").into());
        }
    }
    let start = Instant::now();
    println!(
        "init: {:?} {:?}",
        call(
            &mut store,
            &memory,
            &alloc,
            &func,
            &free,
            &json!({"op":"initialize"})
        )?,
        start.elapsed()
    );
    let bytes = fs::read(pcm_path)?;
    let audio = base64::engine::general_purpose::STANDARD.encode(bytes);
    let request = json!({"op":"transcribe","pcm_f32_base64":audio,"language":"en"});
    for run in 0..4 {
        let start = Instant::now();
        let result = call(&mut store, &memory, &alloc, &func, &free, &request)?;
        println!(
            "{}",
            json!({"run":run,"seconds":start.elapsed().as_secs_f64(),"result":result})
        );
    }
    Ok(())
}
