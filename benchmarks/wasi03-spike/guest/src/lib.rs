//! WASI 0.3 spike guest: an exported async function consuming a host stream<list<u8>>.
wit_bindgen::generate!({ path: "../wit", world: "spike" });

use spike::ws::socket::Conn;

struct Spike;

impl Guest for Spike {
    async fn run(count: u32, size: u32, interval_us: u32) -> (u32, u64) {
        let conn = Conn::open(count, size, interval_us);
        let mut frames = conn.messages();
        let (mut n, mut bytes) = (0u32, 0u64);
        while let Some(frame) = frames.next().await {
            n += 1;
            bytes += frame.len() as u64;
        }
        (n, bytes)
    }
}

export!(Spike);
