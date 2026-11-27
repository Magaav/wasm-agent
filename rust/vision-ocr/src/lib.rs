//! The vision pipeline: PP-OCRv3 det+rec run by `rten`, the words today's engine answers.
//!
//! One owner for OCR inside wa: the component (`rust/components/vision`) and this crate are the only place
//! an image becomes words. The models are the ones the engine in use already ships; they are NOT in this
//! repo, and `Engine::load` takes the directory that holds them.

use std::path::Path;
use rten::{Model, ValueView};
use rten_tensor::layout::Layout;

const DET_SIDE: usize = 736;
const DET_THRESH: f32 = 0.3;
const BOX_THRESH: f32 = 0.5;
const UNCLIP: f32 = 1.6;
const REC_H: usize = 48;
const REC_MAX_W: usize = 320;

pub struct Engine { det: Model, rec: Model, dict: Vec<String> }

#[derive(Clone, Copy, Debug)]
struct BoxI { x0: i32, y0: i32, x1: i32, y1: i32 }

impl Engine {
    /// The engine from the two model files and the dictionary text. A caller that has the bytes (a
    /// component carries them) uses `from_bytes` instead.
    pub fn load(models: &Path, dict_path: &Path) -> Engine {
        let det_bytes = std::fs::read(models.join("ch_PP-OCRv3_det_infer.onnx")).expect("det model");
        let rec_bytes = std::fs::read(models.join("ch_PP-OCRv3_rec_infer.onnx")).expect("rec model");
        let dict = std::fs::read_to_string(dict_path).expect("dict");
        Engine::from_bytes(&det_bytes, &rec_bytes, &dict)
    }

    /// The same engine from bytes: the models are the engine's own assets, so a component embeds them and
    /// a row reads them from the directory they ship in. The dictionary travels WITH them (it was read
    /// from the rec model's own metadata), so a model swap cannot leave a stale dictionary behind.
    pub fn from_bytes(det_bytes: &[u8], rec_bytes: &[u8], dict_text: &str) -> Engine {
        let det = Model::load(det_bytes.to_vec()).expect("det model");
        let rec = Model::load(rec_bytes.to_vec()).expect("rec model");
        let dict = dict_text.split('\n').map(|s| s.to_string()).filter(|s| !s.is_empty()).collect::<Vec<_>>();
        Engine { det, rec, dict }
    }

    pub fn read(&self, img: &image::RgbImage) -> Result<Vec<String>, String> {
        let (w, h) = (img.width() as usize, img.height() as usize);
        // ---- det preprocessing: min side to 736, both dims to a multiple of 32
        let scale = DET_SIDE as f32 / w.min(h) as f32;
        let mut nw = ((w as f32 * scale) as usize).max(32);
        let mut nh = ((h as f32 * scale) as usize).max(32);
        nw = ((nw + 31) / 32) * 32;
        nh = ((nh + 31) / 32) * 32;
        let resized = image::imageops::resize(img, nw as u32, nh as u32, image::imageops::FilterType::Triangle);
        let mean = [0.485f32, 0.456, 0.406];
        let std = [0.229f32, 0.224, 0.225];
        let mut input = vec![0f32; 3 * nh * nw];
        for y in 0..nh {
            for x in 0..nw {
                let p = resized.get_pixel(x as u32, y as u32);
                for c in 0..3 {
                    input[c * nh * nw + y * nw + x] = (p[c] as f32 / 255.0 - mean[c]) / std[c];
                }
            }
        }
        let value = ValueView::from_shape([1, 3, nh, nw], &input).map_err(|e| format!("input:{e}"))?;
        let in_id = self.det.node_id("x").map_err(|e| format!("det input:{e}"))?;
        let out = self.det.run_n(vec![(in_id, value.into())], [self.det.output_ids()[0]], None).map_err(|e| format!("det run:{e}"))?;
        let (shape, data) = out[0].clone().into_shape_vec::<f32, 4>().map_err(|e| format!("det out:{e}"))?;
        let map = &data[..shape[2] * shape[3]];
        let (mw, mh) = (shape[3], shape[2]);
        // ---- det post: mask, connected components, boxes, unclip
        let mut mask = vec![false; mw * mh];
        for i in 0..mw * mh { mask[i] = map[i] > DET_THRESH; }
        let mut seen = vec![false; mw * mh];
        let mut boxes: Vec<BoxI> = Vec::new();
        for start in 0..mw * mh {
            if !mask[start] || seen[start] { continue; }
            let mut stack = vec![start];
            seen[start] = true;
            let (mut x0, mut y0, mut x1, mut y1, mut sum, mut n) = (i32::MAX, i32::MAX, -1i32, -1i32, 0f32, 0);
            while let Some(idx) = stack.pop() {
                let (x, y) = ((idx % mw) as i32, (idx / mw) as i32);
                x0 = x0.min(x); y0 = y0.min(y); x1 = x1.max(x); y1 = y1.max(y);
                sum += map[idx]; n += 1;
                for (dx, dy) in [(1i32, 0i32), (-1, 0), (0, 1), (0, -1)] {
                    let (nx, ny) = (x + dx, y + dy);
                    if nx < 0 || ny < 0 || nx >= mw as i32 || ny >= mh as i32 { continue; }
                    let ni = ny as usize * mw + nx as usize;
                    if mask[ni] && !seen[ni] { seen[ni] = true; stack.push(ni); }
                }
            }
            if n == 0 { continue; }
            if sum / n as f32 >= BOX_THRESH { boxes.push(BoxI { x0, y0, x1, y1 }); }
        }
        // unclip and map back to the original image
        let (sx, sy) = (w as f32 / mw as f32, h as f32 / mh as f32);
        let mut lines: Vec<(i32, i32, String)> = Vec::new();
        for b in boxes {
            let bw = (b.x1 - b.x0 + 1) as f32;
            let bh = (b.y1 - b.y0 + 1) as f32;
            let area = bw * bh;
            let perim = 2.0 * (bw + bh);
            let d = if perim > 0.0 { area * UNCLIP / perim } else { 0.0 };
            let x0 = ((b.x0 as f32 - d) * sx).max(0.0) as u32;
            let y0 = ((b.y0 as f32 - d) * sy).max(0.0) as u32;
            let x1 = (((b.x1 as f32 + d) * sx) as u32).min(img.width());
            let y1 = (((b.y1 as f32 + d) * sy) as u32).min(img.height());
            if x1 <= x0 + 1 || y1 <= y0 + 1 { continue; }
            let crop = image::imageops::crop_imm(img, x0, y0, x1 - x0, y1 - y0).to_image();
            let text = self.recognize(&crop)?;
            if !text.is_empty() { lines.push((y0 as i32, x0 as i32, text)); }
        }
        lines.sort();
        Ok(lines.into_iter().map(|(_, _, t)| t).collect())
    }

    fn recognize(&self, crop: &image::RgbImage) -> Result<String, String> {
        let (w, h) = (crop.width() as usize, crop.height() as usize);
        let rw = ((REC_H as f32 * w as f32 / h as f32) as usize).clamp(16, REC_MAX_W);
        let resized = image::imageops::resize(crop, rw as u32, REC_H as u32, image::imageops::FilterType::Triangle);
        let mut input = vec![0f32; 3 * REC_H * rw];
        for y in 0..REC_H {
            for x in 0..rw {
                let p = resized.get_pixel(x as u32, y as u32);
                for c in 0..3 { input[c * REC_H * rw + y * rw + x] = p[c] as f32 / 255.0; }
            }
        }
        let value = ValueView::from_shape([1, 3, REC_H, rw], &input).map_err(|e| format!("rec input:{e}"))?;
        let in_id = self.rec.node_id("x").map_err(|e| format!("rec input:{e}"))?;
        let out = self.rec.run_n(vec![(in_id, value.into())], [self.rec.output_ids()[0]], None).map_err(|e| format!("rec run:{e}"))?;
        let (shape, data) = out[0].clone().into_shape_vec::<f32, 3>().map_err(|e| format!("rec out:{e}"))?;
        let (t, classes) = (shape[1], shape[2]);
        let mut text = String::new();
        let mut last = usize::MAX;
        let mut scores = Vec::new();
        for step in 0..t {
            let row = &data[step * classes..(step + 1) * classes];
            let (mut best, mut best_i) = (f32::MIN, 0usize);
            for (i, v) in row.iter().enumerate() { if *v > best { best = *v; best_i = i; } }
            if best_i != 0 && best_i != last {
                // The class axis is 6625 wide: 0 is the CTC blank, 1..=6623 are the dictionary entries, and
                // the LAST class is the space (the dictionary file has no line for it). rapidocr decodes the
                // same way, which is why the words match once the space is spelled out here.
                if best_i == classes - 1 {
                    text.push(' '); scores.push(best);
                } else if let Some(ch) = self.dict.get(best_i - 1) { text.push_str(ch); scores.push(best); }
            }
            last = best_i;
        }
        let mean = if scores.is_empty() { 0.0 } else { scores.iter().sum::<f32>() / scores.len() as f32 };
        if mean < 0.5 { return Ok(String::new()); }
        Ok(text.trim().to_string())
    }
}

