//! nnguest <graph-name> <iterations>: load-by-name, then time `compute` on a [1,80,3000] f32 input
//! (Whisper encoder input_features). The tensor is rebuilt every iteration so the copy into the
//! host is part of the measured cost, as it would be for real audio.
wit_bindgen::generate!({ world: "ml", path: "../wit" });

use std::time::Instant;
use wasi::nn::graph;
use wasi::nn::tensor::{Tensor, TensorType};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let name = args.get(1).cloned().unwrap_or_else(|| "whisper-encoder".into());
    let iters: usize = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(5);
    let t = Instant::now();
    let g = graph::load_by_name(&name).expect("load-by-name");
    let ctx = g.init_execution_context().expect("init-execution-context");
    println!("guest: graph {name} ready in {} ms", t.elapsed().as_millis());
    let data = vec![0u8; 80 * 3000 * 4];
    let mut times = Vec::new();
    for i in 0..=iters {
        let t = Instant::now();
        let input = Tensor::new(&vec![1, 80, 3000], TensorType::Fp32, &data);
        let outputs = ctx.compute(vec![("input_features".to_string(), input)]).expect("compute");
        let ms = t.elapsed().as_secs_f64() * 1000.0;
        let (out_name, out) = &outputs[0];
        if i == 0 {
            println!("guest: warmup {ms:.0} ms -> {out_name} {:?} ({} bytes)", out.dimensions(), out.data().len());
        } else {
            times.push(ms);
        }
    }
    times.sort_by(|a, b| a.partial_cmp(b).unwrap());
    println!("guest: wasi-nn median {:.0} ms over {} runs (min {:.0}, max {:.0})", times[times.len() / 2], times.len(), times[0], times[times.len() - 1]);
}
