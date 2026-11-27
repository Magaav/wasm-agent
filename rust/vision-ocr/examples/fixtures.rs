use std::path::Path;
use vision_ocr::Engine;

fn main() {
    let base = "/home/victor/.wasm-agent/ocr-venv/lib/python3.14/site-packages/rapidocr_onnxruntime/models";
    let engine = Engine::load(Path::new(base), &Path::new(env!("CARGO_MANIFEST_DIR")).join("ppocr_keys.txt"));
    for name in ["document.png", "screenshot.png", "notext.png"] {
        let path = Path::new("/home/victor/.wasm-agent/worktrees/vision-is-a-component/fixtures/vision").join(name);
        let img = image::open(&path).expect("fixture").to_rgb8();
        match engine.read(&img) {
            Ok(lines) => println!("{name}: {:?}", lines.join("\\n")),
            Err(e) => println!("{name}: ERROR {e}"),
        }
    }
}
