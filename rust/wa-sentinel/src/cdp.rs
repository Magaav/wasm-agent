//! Explicit page-scoped CDP event adapter. No browser discovery, ambient tab choice, or automatic
//! WhatsApp scraping. An operator-reviewed page adapter emits {id,data} through the named binding.
use super::*;
use ring::rand::{SecureRandom, SystemRandom};
use std::{
    io::{Read, Write},
    net::{SocketAddr, TcpStream},
};
fn b64(bytes: &[u8]) -> String {
    const A: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::new();
    for c in bytes.chunks(3) {
        let v = ((c[0] as u32) << 16)
            | ((c.get(1).copied().unwrap_or(0) as u32) << 8)
            | c.get(2).copied().unwrap_or(0) as u32;
        out.push(A[((v >> 18) & 63) as usize] as char);
        out.push(A[((v >> 12) & 63) as usize] as char);
        out.push(if c.len() > 1 {
            A[((v >> 6) & 63) as usize] as char
        } else {
            '='
        });
        out.push(if c.len() > 2 {
            A[(v & 63) as usize] as char
        } else {
            '='
        });
    }
    out
}
struct Socket {
    stream: TcpStream,
    buffer: Vec<u8>,
    fragment: Vec<u8>,
    fragmenting: bool,
}
impl Socket {
    fn connect(url: &str) -> Result<Self> {
        let rest = url
            .strip_prefix("ws://")
            .context("only loopback ws is supported")?;
        let (authority, path) = rest.split_once('/').context("missing CDP path")?;
        let (host, port) = authority.split_once(':').context("missing CDP port")?;
        if !["127.0.0.1", "localhost"].contains(&host)
            || !path.starts_with("devtools/page/")
            || path.contains(['\r', '\n', ' '])
        {
            bail!("CDP must name an explicit loopback page")
        }
        let address: SocketAddr = format!("127.0.0.1:{}", port.parse::<u16>()?).parse()?;
        let mut stream = TcpStream::connect_timeout(&address, Duration::from_secs(1))?;
        stream.set_read_timeout(Some(Duration::from_millis(100)))?;
        stream.set_write_timeout(Some(Duration::from_secs(1)))?;
        let mut nonce = [0; 16];
        SystemRandom::new()
            .fill(&mut nonce)
            .map_err(|_| anyhow::anyhow!("random source failed"))?;
        let key = b64(&nonce);
        write!(stream,"GET /{path} HTTP/1.1\r\nHost: {authority}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n")?;
        let mut response = Vec::new();
        let started = Instant::now();
        while !response.ends_with(b"\r\n\r\n") {
            if response.len() > 8192 || started.elapsed() > Duration::from_secs(2) {
                bail!("CDP handshake exceeded its budget")
            }
            let mut byte = [0];
            match stream.read(&mut byte) {
                Ok(0) => bail!("CDP closed handshake"),
                Ok(_) => response.push(byte[0]),
                Err(e)
                    if matches!(
                        e.kind(),
                        std::io::ErrorKind::TimedOut | std::io::ErrorKind::WouldBlock
                    ) => {}
                Err(e) => return Err(e.into()),
            }
        }
        let response = String::from_utf8(response)?;
        let expected = b64(ring::digest::digest(
            &ring::digest::SHA1_FOR_LEGACY_USE_ONLY,
            format!("{key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11").as_bytes(),
        )
        .as_ref());
        if !response.starts_with("HTTP/1.1 101 ")
            || !response.lines().any(|line| {
                line.split_once(':').is_some_and(|(k, v)| {
                    k.eq_ignore_ascii_case("Sec-WebSocket-Accept") && v.trim() == expected
                })
            })
        {
            bail!("CDP websocket handshake not verified")
        }
        Ok(Self {
            stream,
            buffer: vec![],
            fragment: vec![],
            fragmenting: false,
        })
    }
    fn send(&mut self, opcode: u8, data: &[u8]) -> Result<()> {
        if data.len() > 65536 {
            bail!("CDP message too large")
        }
        let mut frame = vec![0x80 | opcode];
        if data.len() < 126 {
            frame.push(0x80 | data.len() as u8)
        } else if data.len() <= 65535 {
            frame.push(0x80 | 126);
            frame.extend_from_slice(&(data.len() as u16).to_be_bytes())
        } else {
            frame.push(0x80 | 127);
            frame.extend_from_slice(&(data.len() as u64).to_be_bytes())
        }
        let mut mask = [0; 4];
        SystemRandom::new()
            .fill(&mut mask)
            .map_err(|_| anyhow::anyhow!("random source failed"))?;
        frame.extend(mask);
        frame.extend(data.iter().enumerate().map(|(i, b)| b ^ mask[i % 4]));
        self.stream.write_all(&frame)?;
        Ok(())
    }
    fn command(&mut self, id: u64, method: &str, params: Value) -> Result<()> {
        self.send(
            1,
            json!({"id":id,"method":method,"params":params})
                .to_string()
                .as_bytes(),
        )
    }
    fn poll(&mut self) -> Result<Option<Value>> {
        let mut data = [0; 8192];
        match self.stream.read(&mut data) {
            Ok(0) => bail!("CDP disconnected"),
            Ok(n) => self.buffer.extend_from_slice(&data[..n]),
            Err(e)
                if matches!(
                    e.kind(),
                    std::io::ErrorKind::TimedOut | std::io::ErrorKind::WouldBlock
                ) => {}
            Err(e) => return Err(e.into()),
        }
        if self.buffer.len() > 131072 {
            bail!("CDP frame buffer limit")
        }
        loop {
            if self.buffer.len() < 2 {
                return Ok(None);
            }
            let b = self.buffer[0];
            let masked = self.buffer[1] & 128 != 0;
            let mut len = (self.buffer[1] & 127) as usize;
            let mut header = 2;
            if masked || b & 0x70 != 0 {
                bail!("unsupported CDP websocket frame")
            }
            if len == 126 {
                if self.buffer.len() < 4 {
                    return Ok(None);
                }
                len = u16::from_be_bytes(self.buffer[2..4].try_into()?) as usize;
                header = 4;
            } else if len == 127 {
                if self.buffer.len() < 10 {
                    return Ok(None);
                }
                let n = u64::from_be_bytes(self.buffer[2..10].try_into()?);
                if n > 65536 {
                    bail!("CDP frame too large")
                }
                len = n as usize;
                header = 10;
            }
            if len > 65536 {
                bail!("CDP frame too large")
            }
            if self.buffer.len() < header + len {
                return Ok(None);
            }
            let payload = self.buffer[header..header + len].to_vec();
            self.buffer.drain(..header + len);
            let opcode = b & 15;
            let fin = b & 128 != 0;
            if opcode >= 8 && (!fin || len > 125) {
                bail!("invalid CDP control frame")
            }
            match opcode {
                8 => bail!("CDP closed"),
                9 => {
                    self.send(10, &payload)?;
                    continue;
                }
                10 => continue,
                1 if !self.fragmenting => {
                    self.fragment = payload;
                    self.fragmenting = !fin;
                }
                0 if self.fragmenting => {
                    self.fragment.extend(payload);
                    self.fragmenting = !fin;
                }
                _ => bail!("unsupported CDP data frame"),
            }
            if self.fragment.len() > 65536 {
                bail!("CDP message too large")
            }
            if fin {
                let message = serde_json::from_slice(&self.fragment)?;
                self.fragment.clear();
                return Ok(Some(message));
            }
        }
    }
}
pub fn watch(store: wa_jobs::Store, job: Value) {
    let id = job["id"].as_str().unwrap();
    let revision = job["revision"].as_i64().unwrap();
    let binding = job["trigger"]["binding"].as_str().unwrap();
    while store.current(id, revision).unwrap_or(false) {
        let result = (|| -> Result<()> {
            let mut socket = Socket::connect(job["trigger"]["websocket_url"].as_str().unwrap())?;
            socket.command(1, "Runtime.enable", json!({}))?;
            socket.command(2, "Runtime.addBinding", json!({"name":binding}))?;
            let expression = job["trigger"]["setup_expression"].as_str();
            let mut ready = false;
            while store
                .current(id, revision)
                .map_err(|e| anyhow::anyhow!(e.to_string()))?
            {
                let Some(event) = socket.poll()? else {
                    continue;
                };
                if event.get("error").is_some() || event["result"].get("exceptionDetails").is_some()
                {
                    bail!("CDP adapter command failed: {}", event)
                }
                if event["id"] == 2 {
                    if let Some(expression) = expression {
                        socket.command(
                            3,
                            "Runtime.evaluate",
                            json!({"expression":expression,"returnByValue":true}),
                        )?;
                    } else {
                        ready = true;
                    }
                }
                if event["id"] == 3 {
                    ready = true;
                }
                if ready {
                    store
                        .source_status(id, revision, "listening to explicit CDP binding")
                        .map_err(|e| anyhow::anyhow!(e.to_string()))?;
                    ready = false;
                }
                if event["method"] == "Runtime.bindingCalled" && event["params"]["name"] == binding
                {
                    let payload: Value = serde_json::from_str(
                        event["params"]["payload"]
                            .as_str()
                            .context("binding payload must be JSON")?,
                    )?;
                    let event_id = payload["id"]
                        .as_str()
                        .context("adapter must supply a stable event id")?;
                    // Queue pressure is visible. Retrying this SAME event is safe; reconnecting and losing it is not.
                    loop {
                        if !store.current(id, revision).unwrap_or(false) {
                            return Ok(());
                        }
                        match store.enqueue(
                            id,
                            revision,
                            event_id,
                            &payload["data"],
                            now_epoch() as i64,
                        ) {
                            Ok(_) => break,
                            Err(e) if e.to_string().starts_with("job_queue_full") => {
                                let _ = store.source_status(
                                    id,
                                    revision,
                                    "backpressure: delivery queue full; retaining current event",
                                );
                                std::thread::sleep(Duration::from_millis(200));
                            }
                            Err(e) => return Err(anyhow::anyhow!(e.to_string())),
                        }
                    }
                }
            }
            Ok(())
        })();
        if let Err(e) = result {
            let _ = store.source_status(
                id,
                revision,
                &format!(
                    "source_error:{e}; reconnecting; events during disconnection may be missed"
                ),
            );
        }
        for _ in 0..20 {
            if !store.current(id, revision).unwrap_or(false) {
                return;
            }
            std::thread::sleep(Duration::from_millis(100));
        }
    }
}
