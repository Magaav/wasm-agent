//! The component through its host: the words the seam answers are the words the engine in use answered.
//!
//! This is the row the caller rehearsal rests on (`wa:kernel/vision` asks `vision_component_host::read` when
//! the `vision` feature is on). It runs the REAL component (`vision.wasm`, built by
//! `scripts/build-vision-component.sh`) against the REAL models the node ships, with the pins from
//! `models.lock` verified by the component itself, and compares the words with
//! `fixtures/vision/golden.json` - the same golden the pipeline row uses.
//!
//! Hermetic in what it needs from the machine: `VISION_ASSETS_DIR` names the directory holding the three
//! assets (vision.det/rec/dict) and `VISION_COMPONENT_WASM` the built artifact. With either missing the row
//! SKIPS by name - a skip is never a pass.
use std::path::PathBuf;

fn assets() -> Option<PathBuf> {
    let dir = std::env::var("VISION_ASSETS_DIR").ok().map(PathBuf::from)?;
    let wasm = std::env::var("VISION_COMPONENT_WASM").ok().map(PathBuf::from)?;
    (dir.join("vision.det").exists() && dir.join("vision.rec").exists() && dir.join("vision.dict").exists() && wasm.exists())
        .then_some(dir)
}

#[test]
fn the_component_answers_the_words_the_engine_answered() {
    let Some(dir) = assets() else {
        eprintln!(
            "SKIPPED: no vision assets (set VISION_ASSETS_DIR to vision.det/rec/dict and VISION_COMPONENT_WASM to the built component)"
        );
        return;
    };
    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap().parent().unwrap().to_path_buf();
    let golden: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(root.join("fixtures/vision/golden.json")).expect("golden")).expect("golden json");
    let config = wa_kernel_runtime::vision_component_host::Config { components_dir: dir.clone() };
    for case in golden["cases"].as_array().expect("cases") {
        let fixture = case["fixture"].as_str().expect("fixture");
        let bytes = std::fs::read(root.join("fixtures/vision").join(fixture)).expect("fixture image");
        let answer = wa_kernel_runtime::vision_component_host::read_with(&config, &bytes);
        if case["ok"] == serde_json::Value::Bool(true) {
            let lines = answer.unwrap_or_else(|refusal| panic!("{fixture}: the component refused: {refusal:?}"));
            let got = lines.iter().map(|line| line.text.clone()).collect::<Vec<_>>().join("\n");
            let want = case["text"].as_str().expect("text");
            assert_eq!(got, want, "{fixture}: the component's words differ from the engine's");
            eprintln!("ok  {fixture}: {got:?} ({} line(s))", lines.len());
        } else {
            match answer {
                Ok(lines) => assert!(lines.is_empty(), "{fixture}: a text-free image must answer no words"),
                Err(refusal) => eprintln!("ok  {fixture}: refused {refusal:?}, as the seam's vocabulary allows"),
            }
        }
    }
}
