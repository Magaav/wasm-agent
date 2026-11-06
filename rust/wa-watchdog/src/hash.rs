//! SHA-256, in this crate, on purpose.
//!
//! The watchdog verifies the binary it is about to run (`swap <binary> --sha256 <pin>`), and the whole
//! point of the watchdog is that it survives what it replaces: it must not gain a supply chain the kernel
//! has. SHA-256 is 150 lines of a fixed specification, so it is cheaper to own than to depend on. The
//! implementation is checked against the NIST vectors at the bottom of this file, including the streaming
//! path (`update` in odd-sized pieces must equal one `update`).

const K: [u32; 64] = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

const H0: [u32; 8] = [
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
];

/// A streaming SHA-256. `update` may be called with any chunking; `finish` consumes it.
pub struct Sha256 {
    h: [u32; 8],
    buf: [u8; 64],
    buf_len: usize,
    len_bits: u64,
}

impl Default for Sha256 {
    fn default() -> Self {
        Self::new()
    }
}

impl Sha256 {
    pub fn new() -> Self {
        Sha256 { h: H0, buf: [0u8; 64], buf_len: 0, len_bits: 0 }
    }

    pub fn update(&mut self, data: &[u8]) {
        self.len_bits = self.len_bits.wrapping_add((data.len() as u64).wrapping_mul(8));
        let mut rest = data;
        if self.buf_len > 0 {
            let take = std::cmp::min(64 - self.buf_len, rest.len());
            self.buf[self.buf_len..self.buf_len + take].copy_from_slice(&rest[..take]);
            self.buf_len += take;
            rest = &rest[take..];
            if self.buf_len == 64 {
                let block = self.buf;
                self.compress(&block);
                self.buf_len = 0;
            }
        }
        while rest.len() >= 64 {
            let mut block = [0u8; 64];
            block.copy_from_slice(&rest[..64]);
            self.compress(&block);
            rest = &rest[64..];
        }
        if !rest.is_empty() {
            self.buf[..rest.len()].copy_from_slice(rest);
            self.buf_len = rest.len();
        }
    }

    /// The digest of everything passed to `update`, as 32 big-endian bytes.
    pub fn finish(mut self) -> [u8; 32] {
        let bits = self.len_bits;
        // 0x80, then zeros until the block is 56 bytes long, then the message length in bits.
        let mut pad = Vec::with_capacity(72);
        pad.push(0x80);
        let after_marker = (self.buf_len + 1) % 64;
        let zeros = if after_marker <= 56 { 56 - after_marker } else { 120 - after_marker };
        pad.resize(pad.len() + zeros, 0u8);
        pad.extend_from_slice(&bits.to_be_bytes());
        // `pad` holds exactly the bytes that bring the buffer to a block boundary, so buf_len ends at 0.
        self.update(&pad);
        debug_assert_eq!(self.buf_len, 0, "padding must end on a block boundary");
        let mut out = [0u8; 32];
        for (index, word) in self.h.iter().enumerate() {
            out[index * 4..index * 4 + 4].copy_from_slice(&word.to_be_bytes());
        }
        out
    }

    fn compress(&mut self, block: &[u8; 64]) {
        let mut w = [0u32; 64];
        for i in 0..16 {
            w[i] = u32::from_be_bytes([block[i * 4], block[i * 4 + 1], block[i * 4 + 2], block[i * 4 + 3]]);
        }
        for i in 16..64 {
            let s0 = w[i - 15].rotate_right(7) ^ w[i - 15].rotate_right(18) ^ (w[i - 15] >> 3);
            let s1 = w[i - 2].rotate_right(17) ^ w[i - 2].rotate_right(19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16].wrapping_add(s0).wrapping_add(w[i - 7]).wrapping_add(s1);
        }
        let mut a = self.h[0];
        let mut b = self.h[1];
        let mut c = self.h[2];
        let mut d = self.h[3];
        let mut e = self.h[4];
        let mut f = self.h[5];
        let mut g = self.h[6];
        let mut h = self.h[7];
        for i in 0..64 {
            let s1 = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
            let ch = (e & f) ^ ((!e) & g);
            let t1 = h.wrapping_add(s1).wrapping_add(ch).wrapping_add(K[i]).wrapping_add(w[i]);
            let s0 = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22);
            let maj = (a & b) ^ (a & c) ^ (b & c);
            let t2 = s0.wrapping_add(maj);
            h = g;
            g = f;
            f = e;
            e = d.wrapping_add(t1);
            d = c;
            c = b;
            b = a;
            a = t1.wrapping_add(t2);
        }
        self.h[0] = self.h[0].wrapping_add(a);
        self.h[1] = self.h[1].wrapping_add(b);
        self.h[2] = self.h[2].wrapping_add(c);
        self.h[3] = self.h[3].wrapping_add(d);
        self.h[4] = self.h[4].wrapping_add(e);
        self.h[5] = self.h[5].wrapping_add(f);
        self.h[6] = self.h[6].wrapping_add(g);
        self.h[7] = self.h[7].wrapping_add(h);
    }
}

pub fn sha256(bytes: &[u8]) -> [u8; 32] {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    hasher.finish()
}

pub fn to_hex(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        out.push_str(&format!("{byte:02x}"));
    }
    out
}

pub fn sha256_hex(bytes: &[u8]) -> String {
    to_hex(&sha256(bytes))
}

/// The digest of a file, read in bounded chunks: a kernel binary is tens of megabytes and the pin check
/// must not depend on it being loadable in one piece.
pub fn sha256_file(path: &std::path::Path) -> std::io::Result<String> {
    use std::io::Read;
    let mut file = std::fs::File::open(path)?;
    let mut hasher = Sha256::new();
    let mut buf = vec![0u8; 64 * 1024];
    loop {
        let read = file.read(&mut buf)?;
        if read == 0 {
            break;
        }
        hasher.update(&buf[..read]);
    }
    Ok(to_hex(&hasher.finish()))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// NIST FIPS 180-2 / CAVP vectors. A pin check that is wrong about one of these is worse than none.
    #[test]
    fn known_answer_vectors() {
        let cases: &[(&str, &str)] = &[
            ("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
            ("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
            (
                "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
                "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
            ),
            (
                "abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu",
                "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1",
            ),
        ];
        for (input, expected) in cases {
            assert_eq!(&sha256_hex(input.as_bytes()), expected, "digest of {input:?}");
        }
    }

    #[test]
    fn chunking_does_not_change_the_digest() {
        let data: Vec<u8> = (0..1000u32).map(|i| (i % 251) as u8).collect();
        let whole = sha256_hex(&data);
        for chunk in [1usize, 3, 55, 56, 63, 64, 65, 127, 999] {
            let mut hasher = Sha256::new();
            for piece in data.chunks(chunk) {
                hasher.update(piece);
            }
            assert_eq!(to_hex(&hasher.finish()), whole, "chunk size {chunk}");
        }
    }

    #[test]
    fn a_million_a_bytes() {
        let mut hasher = Sha256::new();
        let block = vec![b'a'; 1000];
        for _ in 0..1000 {
            hasher.update(&block);
        }
        assert_eq!(
            to_hex(&hasher.finish()),
            "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"
        );
    }

    #[test]
    fn a_file_digest_matches_the_bytes_digest() {
        let path = std::env::temp_dir().join(format!("wa-watchdog-hash-{}", std::process::id()));
        let payload: Vec<u8> = (0..70_001u32).map(|i| (i % 97) as u8).collect();
        std::fs::write(&path, &payload).expect("write the scratch file");
        let from_file = sha256_file(&path).expect("hash the scratch file");
        let _ = std::fs::remove_file(&path);
        assert_eq!(from_file, sha256_hex(&payload));
    }
}
