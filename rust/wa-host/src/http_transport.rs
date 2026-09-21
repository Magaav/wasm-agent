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
use ureq::config::Config;
use ureq::unversioned::resolver::DefaultResolver;
use ureq::unversioned::transport::{
    Buffers, ConnectProxyConnector, ConnectionDetails, Connector, Either, LazyBuffers, NextTimeout,
    RustlsConnector, Transport,
};
use ureq::Error;

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
}

impl ShutdownTcpTransport {
    fn new(stream: TcpStream) -> Self {
        ShutdownTcpTransport {
            stream,
            buffers: LazyBuffers::new(128 * 1024, 128 * 1024),
            timeout_write: None,
            timeout_read: None,
        }
    }
}

impl Transport for ShutdownTcpTransport {
    fn buffers(&mut self) -> &mut dyn Buffers {
        &mut self.buffers
    }

    fn transmit_output(&mut self, amount: usize, timeout: NextTimeout) -> Result<(), Error> {
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
        if !crate::subagents::in_task() {
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
        let budget = timeout.not_zero().map(|value| *value);
        let started = std::time::Instant::now();
        let slice = std::time::Duration::from_millis(250);
        loop {
            if crate::host::run_cancel_requested() {
                return Err(Error::Timeout(timeout.reason));
            }
            let wait = match budget {
                Some(total) => {
                    let elapsed = started.elapsed();
                    if elapsed >= total {
                        return Err(Error::Timeout(timeout.reason));
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
pub struct ShutdownTcpConnector;

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
                    return Ok(Some(Either::B(ShutdownTcpTransport::new(stream))));
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
        .chain(ShutdownTcpConnector)
        .chain(RustlsConnector::default());
    ureq::Agent::with_parts(config, chain, DefaultResolver::default())
}
