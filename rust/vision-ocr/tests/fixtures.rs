//! The fixture row: the Rust pipeline answers the same words today's engine answered.
//!
//! `fixtures/vision/golden.json` was recorded from the engine in use (`rapidocr_onnxruntime`, the Python
//! worker `scripts/whatsapp-ocr-local.py`) on three SYNTHETIC images - rendered text only, no real document,
//! no names, numbers or JIDs. This row runs the same three through `vision-ocr` and compares the words.
//!
//! Where the models come from: they are the ones the engine already ships; **models are never copied into
//! this repo** - `VISION_OCR_MODELS` names the directory (default: the node's OCR venv), and the row SKIPS by
//! name when it is not there, because a skip is not a pass.
use std::path::{Path, PathBuf};
use std::process::Command;

fn models_dir() -> Option<PathBuf> {
    let dir = std::env::var("VISION_OCR_MODELS").ok().map(PathBuf::from).unwrap_or_else(|| {
        PathBuf::from("/home/victor/.wasm-agent/ocr-venv/lib/python3.14/site-packages/rapidocr_onnxruntime/models")
    });
    dir.join("ch_PP-OCRv3_det_infer.onnx").exists().then_some(dir)
}

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap().parent().unwrap().to_path_buf()
}

#[test]
fn the_words_match_the_engine_in_use() {
    let Some(models) = models_dir() else {
        eprintln!("SKIPPED: no PP-OCRv3 models (set VISION_OCR_MODELS to the directory that holds them)");
        return;
    };
    let root = repo_root();
    let dict = Path::new(env!("CARGO_MANIFEST_DIR")).join("ppocr_keys.txt");
    let golden: serde_json::Value = serde_json::from_str(
        &std::fs::read_to_string(root.join("fixtures/vision/golden.json")).expect("golden"),
    )
    .expect("golden json");
    let engine = vision_ocr::Engine::load(&models, &dict);
    for case in golden["cases"].as_array().expect("cases") {
        let fixture = case["fixture"].as_str().expect("fixture");
        let img = image::open(root.join("fixtures/vision").join(fixture)).expect("fixture image").to_rgb8();
        let lines = engine.read(&img).expect("pipeline runs");
        let got = lines.iter().map(|l| l.text.clone()).collect::<Vec<_>>().join("\n");
        if case["ok"] == serde_json::Value::Bool(true) {
            let want = case["text"].as_str().expect("text");
            assert_eq!(got, want, "{fixture}: the words differ from the engine in use");
            eprintln!("ok  {fixture}: {got:?} ({} line(s), first confidence {:.3})", lines.len(), lines.first().map(|l| l.confidence).unwrap_or(0.0));
        } else {
            assert_eq!(got, "", "{fixture}: a text-free image must answer no words (the engine in use errored here: {})", case["error"]);
            eprintln!("ok  {fixture}: no text, as the component will say");
        }
    }
    let _ = Command::new("true");
}
