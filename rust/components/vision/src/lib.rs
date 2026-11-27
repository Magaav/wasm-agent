//! Images become words as a component (`wa:vision`).
//!
//! What this file does, and nothing more:
//!
//! * it asks the host for the three model assets through the world's `assets` import and **verifies each
//!   against the sha256 pin in `models.lock`** before a byte is loaded (a mismatch is
//!   `model-hash-mismatch`, the same rule the component set itself follows);
//! * it runs the shared pipeline (`vision-ocr`) on the image it was handed;
//! * it answers in the vocabulary the node already prints for the same faults, so the two paths cannot
//!   say different words for one error.
//!
//! It holds no state between calls except the loaded engine, which is rebuilt only when the pins change -
//! the models are the same bytes for the life of the component, so loading them twice would be a cost with
//! no answer behind it.
use std::cell::OnceCell;

use sha2::{Digest, Sha256};

wit_bindgen::generate!({ path: "../../../wit/vision", world: "vision-component", generate_all });

use crate::wa::vision::types::{Line, Refusal};
use crate::exports::wa::vision::vision::Guest;
use crate::wa::vision::assets;

/// The three pins, exactly as `models.lock` carries them, in the order the interface answers them.
const PINS: &str = include_str!("../../../../models.lock");

const MAX_IMAGE_BYTES: u64 = 20 * 1024 * 1024;
const MAX_TEXT_CHARS: usize = 12_000;

struct VisionComponent;

thread_local! {
    /// The engine, built once from verified bytes. A `OnceCell` rather than a `Mutex`: the host serialises
    /// the calls it makes to one instance, so there is one thread and nothing to lock.
    static ENGINE: OnceCell<Result<vision_ocr::Engine, Refusal>> = const { OnceCell::new() };
}

/// One pin line: `name sha256 bytes origin`.
fn pin_for(name: &str) -> Option<&'static str> {
    PINS.lines()
        .filter(|line| !line.trim_start().starts_with('#'))
        .filter_map(|line| {
            let mut parts = line.split_whitespace();
            let field = parts.next()?;
            let sha = parts.next()?;
            (field == name).then_some(sha)
        })
        .next()
}

fn verified(name: &str) -> Result<Vec<u8>, Refusal> {
    let bytes = assets::load(name).map_err(|reason| Refusal::ModelHashMismatch(format!("{name}:{reason}")))?;
    let Some(expected) = pin_for(name) else {
        return Err(Refusal::ModelHashMismatch(format!("{name}:no pin")));
    };
    let actual: String = Sha256::digest(&bytes).iter().map(|b| format!("{b:02x}")).collect();
    if actual != expected {
        return Err(Refusal::ModelHashMismatch(format!("{name}:{actual}")));
    }
    Ok(bytes)
}

/// Run `body` with the engine, building it from verified bytes on first use. The engine never escapes the
/// closure: a `thread_local` borrow cannot outlive the call, and the host serialises the calls to one
/// instance anyway, so there is nothing to hand back.
fn with_engine<T>(body: impl FnOnce(&vision_ocr::Engine) -> Result<T, Refusal>) -> Result<T, Refusal> {
    ENGINE.with(|cell| {
        let built = cell.get_or_init(|| {
            let det = verified("vision.det")?;
            let rec = verified("vision.rec")?;
            let dict = verified("vision.dict")?;
            let dict_text =
                String::from_utf8(dict).map_err(|_| Refusal::EngineFailed("dictionary is not text".to_string()))?;
            Ok(vision_ocr::Engine::from_bytes(&det, &rec, &dict_text))
        });
        match built {
            Ok(engine) => body(engine),
            Err(refusal) => Err(refusal.clone()),
        }
    })
}

impl Guest for VisionComponent {
    async fn read(image: Vec<u8>) -> Result<Vec<Line>, Refusal> {
        if image.len() as u64 > MAX_IMAGE_BYTES {
            return Err(Refusal::ImageTooLarge(image.len() as u64));
        }
        let decoded = image::load_from_memory(&image)
            .map_err(|error| Refusal::UnsupportedImage(error.to_string()))?
            .to_rgb8();
        let lines = with_engine(|engine| engine.read(&decoded).map_err(Refusal::EngineFailed))?;
        let mut out = Vec::with_capacity(lines.len());
        let mut total = 0usize;
        for line in lines {
            total += line.text.chars().count() + 1;
            out.push(Line {
                text: line.text,
                x0: line.x0,
                y0: line.y0,
                x1: line.x1,
                y1: line.y1,
                confidence: line.confidence,
            });
        }
        if total > MAX_TEXT_CHARS {
            return Err(Refusal::TextTooLong(total as u64));
        }
        if out.is_empty() {
            return Err(Refusal::NoTextDetected);
        }
        Ok(out)
    }

    fn models() -> Vec<String> {
        ["vision.det", "vision.rec", "vision.dict"]
            .iter()
            .filter_map(|name| pin_for(name).map(|sha| format!("{name}={sha}")))
            .collect()
    }
}

export!(VisionComponent);
