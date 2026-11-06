//! Fixture for the WASI grant policy (`docs/WASI-INTERFACES.md`, tier B): `wasi:sockets@0.3.0`.
//!
//! What it proves, in the component's own log:
//!   * `net connect <addr> ok` - a connect to the address the grant names succeeds against a real
//!     local listener. The address is passed in through `service.run(config)`, so the test decides it.
//!   * `net connect <addr> refused=<code>` - the same call to another address is refused by the
//!     host's address check (the grant holds `127.0.0.1:<port>`, not the other host), never by luck.
//!   * `net dns ok|refused` - `resolve-addresses` is a separate grant (`dns`), because a name lookup
//!     is an outbound request of its own.
//!
//! `create` is where `wasi:sockets` itself is gated: with no `net` grant the interface is not linked
//! and the component is refused before it runs, so this fixture never reports "not granted" itself.
wit_bindgen::generate!({ path: "../../../wit/kernel-v2", world: "wasi-probe-net", generate_all });

use std::time::Duration;
use wa::kernel::{lifecycle, log};
use wasi::clocks::monotonic_clock;
use wasi::sockets::ip_name_lookup;
use wasi::sockets::types::{IpAddress, IpAddressFamily, IpSocketAddress, Ipv4SocketAddress, TcpSocket};

struct Service;

fn line(text: &str) {
    log::write(log::Level::Info, "wasi-net", text);
}

/// The `ip-socket-address` for a dotted quad and a port (the fixture only speaks IPv4).
fn v4(port: u16, a: u8, b: u8, c: u8, d: u8) -> IpSocketAddress {
    IpSocketAddress::Ipv4(Ipv4SocketAddress { port, address: (a, b, c, d) })
}

async fn connect(port: u16, a: u8, b: u8, c: u8, d: u8) -> String {
    let address = v4(port, a, b, c, d);
    match TcpSocket::create(IpAddressFamily::Ipv4) {
        Ok(socket) => match socket.connect(address.clone()).await {
            Ok(()) => format!("net connect {address:?} ok"),
            Err(error) => format!("net connect {address:?} refused={error:?}"),
        },
        Err(error) => format!("net create refused={error:?}"),
    }
}

impl exports::wa::kernel::service::Guest for Service {
    async fn run(config: String) -> Result<(), String> {
        let config: serde_json::Value = serde_json::from_str(&config).unwrap_or_default();
        let port = config["port"].as_u64().unwrap_or(0) as u16;
        let other = config["other"].as_u64().unwrap_or(9) as u16;
        line(&format!("net granted={} refused={}", port, other));
        line(&connect(port, 127, 0, 0, 1).await);
        line(&connect(other, 127, 0, 0, 2).await);
        // A name lookup: granted by `dns`, and answered for a name that needs no network (`localhost`).
        match ip_name_lookup::resolve_addresses("localhost".to_string()).await {
            Ok(list) => {
                let kinds: Vec<&str> = list.iter().map(|a| if matches!(a, IpAddress::Ipv4(_)) { "v4" } else { "v6" }).collect();
                line(&format!("net dns ok {kinds:?}"));
            }
            Err(error) => line(&format!("net dns refused={error:?}")),
        }
        lifecycle::report(lifecycle::Health::Ready, None);
        loop {
            if lifecycle::stopping() {
                line("stopping cleanly");
                return Ok(());
            }
            monotonic_clock::wait_for(Duration::from_millis(100).as_nanos() as u64).await;
        }
    }
}

export!(Service);
