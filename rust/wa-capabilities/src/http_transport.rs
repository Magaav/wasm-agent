//! A ureq transport that can be interrupted while it is silent.
//!
//! A provider that accepts a request and then says nothing blocks a body read
//! until the total body timeout. Chunk-boundary cancellation checks cannot reach
//! that read, so a cancel would wait out the timeout. This module owns the TCP
//! socket for the request, registers a clone with the runtime, and lets a cancel
//! from another thread `shutdown(Both)` it - which wakes the blocked read at once.
//!
//! The timeout budget is unchanged: the socket is set to the request's remaining
//! budget, not to a small poll interval, so a long healthy pause (a reasoning
//! model thinking) is not mistaken for a stall.

use std::io::{Read, Write};
use std::net::TcpStream;
use std::time::Duration;
use std::sync::{Arc, atomic::{AtomicBool, Ordering}};
use ureq::config::Config;
use ureq::unversioned::resolver::DefaultResolver;
use ureq::unversioned::transport::{
    Buffers, ConnectProxyConnector, ConnectionDetails, Connector, Either, LazyBuffers, NextTimeout,
    RustlsConnector, Transport,
};
use ureq::Error;

/// ureq 3 also considers the preceding response-header deadline during body
/// reads. Once headers arrive, SSE instead needs an idle-read limit and the
/// caller's overall deadline; a talking stream must not die at 120 seconds.
#[derive(Clone, Debug)]
pub struct StreamControl {
    headers_received: Arc<AtomicBool>,
    deadline: std::time::Instant,
    idle: Duration,
}

impl StreamControl {
    pub fn received_headers(&self) {
        self.headers_received.store(true, Ordering::SeqCst);
    }

    fn read_budget(&self, timeout: NextTimeout) -> (Option<Duration>, ureq::Timeout) {
        let remaining = self.deadline.saturating_duration_since(std::time::Instant::now());
        if self.headers_received.load(Ordering::SeqCst) {
            if remaining <= self.idle { (Some(remaining), ureq::Timeout::Global) }
            else { (Some(self.idle), ureq::Timeout::RecvBody) }
        } else {
            let phase = timeout.not_zero().map(|value| *value);
            if phase.is_none_or(|value| remaining <= value) {
                (Some(remaining), ureq::Timeout::Global)
            } else { (phase, timeout.reason) }
        }
    }
}

fn is_timeout(error: &std::io::Error) -> bool {
    // Windows reports a socket timeout as `TimedOut`; Unix as `WouldBlock`.
    matches!(error.kind(), std::io::ErrorKind::TimedOut | std::io::ErrorKind::WouldBlock)
}

/// Only set the OS timeout when it actually changes, the way ureq's own transport does.
fn update_timeout(
    timeout: NextTimeout,
    previous: &mut Option<std::time::Duration>,
    stream: &TcpStream,
    set: impl Fn(&TcpStream, Option<std::time::Duration>) -> std::io::Result<()>,
) -> std::io::Result<()> {
    // `not_zero` returns ureq's internal Duration; it derefs to std's.
    let next = timeout.not_zero().map(|value| *value);
    if next != *previous {
        set(stream, next)?;
        *previous = next;
    }
    Ok(())
}

#[derive(Debug)]
pub struct ShutdownTcpTransport {
    stream: TcpStream,
    buffers: LazyBuffers,
    timeout_write: Option<Duration>,
    timeout_read: Option<Duration>,
    stream_control: Option<StreamControl>,
}

impl ShutdownTcpTransport {
    fn new(stream: TcpStream, stream_control: Option<StreamControl>) -> Self {
        ShutdownTcpTransport {
            stream,
            buffers: LazyBuffers::new(128 * 1024, 128 * 1024),
            timeout_write: None,
            timeout_read: None,
            stream_control,
        }
    }
}

impl Transport for ShutdownTcpTransport {
    fn buffers(&mut self) -> &mut dyn Buffers {
        &mut self.buffers
    }

    fn transmit_output(&mut self, amount: usize, timeout: NextTimeout) -> Result<(), Error> {
        if let Some(control) = &self.stream_control {
            let remaining = control.deadline.saturating_duration_since(std::time::Instant::now());
            if remaining.is_zero() { return Err(Error::Timeout(ureq::Timeout::Global)); }
            let wait = timeout.not_zero().map(|value| (*value).min(remaining)).unwrap_or(remaining);
            self.stream.set_write_timeout(Some(wait)).map_err(Error::Io)?;
            self.timeout_write = Some(wait);
            let output = &self.buffers.output()[..amount];
            return self.stream.write_all(output).map_err(|error| {
                if is_timeout(&error) { Error::Timeout(ureq::Timeout::Global) } else { Error::Io(error) }
            });
        }
        update_timeout(timeout, &mut self.timeout_write, &self.stream, |stream, value| {
            stream.set_write_timeout(value)
        })
        .map_err(Error::Io)?;
        let output = &self.buffers.output()[..amount];
        match self.stream.write_all(output) {
            Ok(()) => Ok(()),
            Err(error) if is_timeout(&error) => Err(Error::Timeout(timeout.reason)),
            Err(error) => Err(Error::Io(error)),
        }
    }

    fn await_input(&mut self, timeout: NextTimeout) -> Result<bool, Error> {
        if !crate::subagents::in_task() && self.stream_control.is_none() {
            // No task, no cancellation to observe: one read on the request's own budget.
            update_timeout(timeout, &mut self.timeout_read, &self.stream, |stream, value| {
                stream.set_read_timeout(value)
            })
            .map_err(Error::Io)?;
            let input = self.buffers.input_append_buf();
            let amount = match self.stream.read(input) {
                Ok(amount) => amount,
                Err(error) if is_timeout(&error) => return Err(Error::Timeout(timeout.reason)),
                Err(error) => return Err(Error::Io(error)),
            };
            self.buffers.input_appended(amount);
            return Ok(amount > 0);
        }
        // A task may be cancelled while this read is silent. `shutdown` on a
        // duplicated handle does not wake a blocked `recv` on Windows (measured: the
        // read stays blocked with the socket open), so wait in short slices and
        // re-check the cancellation flag. A slice timeout is a POLL, not a failure:
        // the read is retried, so a long healthy pause before the first token is not
        // cut short, and the request's own budget still bounds the whole wait.
        let (budget, reason) = self.stream_control.as_ref().map(|control| control.read_budget(timeout))
            .unwrap_or_else(|| (timeout.not_zero().map(|value| *value), timeout.reason));
        let started = std::time::Instant::now();
        let slice = std::time::Duration::from_millis(250);
        loop {
            if crate::host::run_cancel_requested() {
                return Err(Error::Timeout(reason));
            }
            let wait = match budget {
                Some(total) => {
                    let elapsed = started.elapsed();
                    if elapsed >= total {
                        return Err(Error::Timeout(reason));
                    }
                    (total - elapsed).min(slice)
                }
                None => slice,
            };
            self.stream.set_read_timeout(Some(wait)).map_err(Error::Io)?;
            self.timeout_read = Some(wait);
            let input = self.buffers.input_append_buf();
            match self.stream.read(input) {
                Ok(amount) => {
                    self.buffers.input_appended(amount);
                    return Ok(amount > 0);
                }
                Err(error) if is_timeout(&error) => continue,
                Err(error) => return Err(Error::Io(error)),
            }
        }
    }

    fn is_open(&mut self) -> bool {
        // Mirrors ureq's own probe: a connection with unread bytes to the server
        // or a closed peer is not reusable.
        if self.stream.set_nonblocking(true).is_err() {
            return false;
        }
        let mut byte = [0u8];
        let open = match self.stream.read(&mut byte) {
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => true,
            _ => false,
        };
        let _ = self.stream.set_nonblocking(false);
        open
    }

    fn is_tls(&self) -> bool {
        false
    }
}

/// Opens TCP sockets and registers them so a cancel can wake a silent read.
#[derive(Debug)]
pub struct ShutdownTcpConnector {
    stream_control: Option<StreamControl>,
}

impl<In: Transport> Connector<In> for ShutdownTcpConnector {
    type Out = Either<In, ShutdownTcpTransport>;

    fn connect(
        &self,
        details: &ConnectionDetails,
        chained: Option<In>,
    ) -> Result<Option<Self::Out>, Error> {
        if let Some(transport) = chained {
            // A proxy connector already opened a socket (and my connector ran for
            // it through `run_connector`), so pass it through.
            return Ok(Some(Either::A(transport)));
        }
        let connect = details
            .timeout
            .not_zero()
            .map(|value| *value)
            .unwrap_or(std::time::Duration::from_secs(10));
        let connect = self.stream_control.as_ref().map(|control|
            connect.min(control.deadline.saturating_duration_since(std::time::Instant::now()))).unwrap_or(connect);
        if connect.is_zero() { return Err(Error::Timeout(ureq::Timeout::Global)); }
        let mut last_error = None;
        for address in details.addrs.iter() {
            match TcpStream::connect_timeout(address, connect) {
                Ok(stream) => {
                    if details.config.no_delay() {
                        let _ = stream.set_nodelay(true);
                    }
                    // The handle that lets another thread shut this read down.
                    crate::subagents::register_active_socket(&stream);
                    // Close the window between a cancel arriving and this socket being
                    // registered: if it was already requested, the read that is about to
                    // block must not wait for a chunk that may never come.
                    if crate::host::run_cancel_requested() {
                        let _ = stream.shutdown(std::net::Shutdown::Both);
                    }
                    return Ok(Some(Either::B(ShutdownTcpTransport::new(stream, self.stream_control.clone()))));
                }
                Err(error) => last_error = Some(error),
            }
        }
        Err(match last_error {
            Some(error) => Error::Io(error),
            None => Error::ConnectionFailed,
        })
    }
}

/// Build an agent whose TCP reads can be interrupted by `shutdown`.
pub fn agent(config: Config) -> ureq::Agent {
    let chain = ConnectProxyConnector::default()
        .chain(ShutdownTcpConnector { stream_control: None })
        .chain(RustlsConnector::default());
    ureq::Agent::with_parts(config, chain, DefaultResolver::default())
}

/// One stream owns its phase marker and deadline; pooled requests never share it.
pub fn stream_agent(config: Config, idle: Duration, total: Duration) -> (ureq::Agent, StreamControl) {
    let control = StreamControl {
        headers_received: Arc::new(AtomicBool::new(false)),
        deadline: std::time::Instant::now() + total,
        idle,
    };
    let chain = ConnectProxyConnector::default()
        .chain(ShutdownTcpConnector { stream_control: Some(control.clone()) })
        .chain(RustlsConnector::default());
    (ureq::Agent::with_parts(config, chain, DefaultResolver::default()), control)
}

#[cfg(test)]
mod streaming_timeout_tests {
    use super::*;
    use std::net::TcpListener;

    fn server(header_delay: Duration, gap: Duration, chunks: usize) -> (String, std::thread::JoinHandle<()>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}/stream", listener.local_addr().unwrap());
        let worker = std::thread::spawn(move || {
            let (mut socket, _) = listener.accept().unwrap();
            socket.set_read_timeout(Some(Duration::from_secs(3))).unwrap();
            socket.set_write_timeout(Some(Duration::from_secs(3))).unwrap();
            let mut bytes = Vec::new();
            let mut byte = [0];
            while socket.read(&mut byte).unwrap_or(0) == 1 {
                bytes.push(byte[0]);
                if bytes.ends_with(b"\r\n\r\n") { break; }
            }
            std::thread::sleep(header_delay);
            if socket.write_all(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n").is_err() { return; }
            for _ in 0..chunks {
                std::thread::sleep(gap);
                if socket.write_all(b"3\r\nx\n\n\r\n").is_err() { return; }
            }
            let _ = socket.write_all(b"0\r\n\r\n");
        });
        (url, worker)
    }

    fn config() -> Config {
        ureq::Agent::config_builder().proxy(None)
            .timeout_recv_response(Some(Duration::from_millis(250)))
            .timeout_recv_body(Some(Duration::from_millis(500)))
            .build()
    }

    #[test]
    fn healthy_stream_outlives_header_timeout() {
        let (url, worker) = server(Duration::ZERO, Duration::from_millis(100), 12);
        let (agent, control) = stream_agent(config(), Duration::from_millis(500), Duration::from_secs(5));
        let response = agent.get(&url).call().unwrap();
        control.received_headers();
        let mut body = String::new();
        response.into_body().into_reader().read_to_string(&mut body).unwrap();
        assert_eq!(body, "x\n\n".repeat(12));
        worker.join().unwrap();
    }

    #[test]
    fn old_header_policy_cuts_a_talking_stream() {
        let (url, worker) = server(Duration::ZERO, Duration::from_millis(100), 12);
        let (agent, _control) = stream_agent(config(), Duration::from_millis(500), Duration::from_secs(5));
        let response = agent.get(&url).call().unwrap();
        let mut body = String::new();
        let error = response.into_body().into_reader().read_to_string(&mut body).unwrap_err();
        assert!(error.to_string().contains("receive response"), "{error}");
        worker.join().unwrap();
    }

    #[test]
    fn silent_headers_still_timeout() {
        let (url, worker) = server(Duration::from_millis(600), Duration::ZERO, 0);
        let (agent, _) = stream_agent(config(), Duration::from_millis(500), Duration::from_secs(3));
        let error = agent.get(&url).call().unwrap_err();
        assert!(error.to_string().contains("receive response"), "{error}");
        worker.join().unwrap();
    }

    #[test]
    fn silent_body_uses_idle_timeout() {
        let (url, worker) = server(Duration::ZERO, Duration::from_millis(800), 1);
        let (agent, control) = stream_agent(config(), Duration::from_millis(500), Duration::from_secs(3));
        let response = agent.get(&url).call().unwrap();
        control.received_headers();
        let error = response.into_body().into_reader().read_to_string(&mut String::new()).unwrap_err();
        assert!(error.to_string().contains("receive body"), "{error}");
        worker.join().unwrap();
    }

    #[test]
    fn talking_body_still_obeys_total_deadline() {
        let (url, worker) = server(Duration::ZERO, Duration::from_millis(100), 20);
        let (agent, control) = stream_agent(config(), Duration::from_millis(500), Duration::from_millis(750));
        let response = agent.get(&url).call().unwrap();
        control.received_headers();
        let error = response.into_body().into_reader().read_to_string(&mut String::new()).unwrap_err();
        assert!(error.to_string().contains("global"), "{error}");
        worker.join().unwrap();
    }
}
