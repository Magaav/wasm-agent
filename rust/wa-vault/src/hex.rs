//! Hex, because the vault document is one text file an operator can copy, and a second encoding crate
//! for sixteen lines of code would be a dependency nobody needs.

pub fn encode(bytes: &[u8]) -> String {
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    let mut text = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        text.push(DIGITS[(byte >> 4) as usize] as char);
        text.push(DIGITS[(byte & 0x0f) as usize] as char);
    }
    text
}

pub fn decode(text: &str) -> Option<Vec<u8>> {
    if !text.len().is_multiple_of(2) {
        return None;
    }
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len() / 2);
    for pair in bytes.chunks(2) {
        let high = digit(pair[0])?;
        let low = digit(pair[1])?;
        out.push((high << 4) | low);
    }
    Some(out)
}

fn digit(byte: u8) -> Option<u8> {
    match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'a'..=b'f' => Some(byte - b'a' + 10),
        b'A'..=b'F' => Some(byte - b'A' + 10),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hex_round_trips_and_refuses_odd_input() {
        assert_eq!(encode(&[0x00, 0xff, 0x1a]), "00ff1a");
        assert_eq!(decode("00ff1a").unwrap(), vec![0x00, 0xff, 0x1a]);
        assert!(decode("abc").is_none());
        assert!(decode("zz").is_none());
    }
}
