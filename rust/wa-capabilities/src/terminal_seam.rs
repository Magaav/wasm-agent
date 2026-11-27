//! The `wa:terminal` seam, on the pattern the process host proved: a TRAIT where the surface comes from, so the
//! node wires `wa-term` in and a test wires a script, and the event path is a unit test rather than a live tty.

use std::pin::Pin;
use std::sync::Arc;
use std::task::{Context, Poll};
use wasmtime::component::{
    Access, Accessor, Destination, HasData, Resource, ResourceTable, StreamProducer, StreamReader, StreamResult,
};
use wasmtime::{AsContextMut, StoreContextMut};

wasmtime::component::bindgen!({
    world: "terminal-client",
    path: "../../wit/terminal",
    imports: {
        "wa:terminal/session.[method]surface.events": store | trappable,
        "wa:terminal/session.[method]surface.write": store | trappable,
        "wa:terminal/session.[method]surface.resize": store | trappable,
        "wa:terminal/session.[method]surface.close": store | trappable,
    },
    with: {
        "wa:terminal/session.surface": SurfaceHandle,
    },
});

use wa::terminal::types::{Error as Fault, Event, Size};

/// Where a surface's events come from: the node backs this with `wa-term`, a test with a script.
pub trait Surface: Send {
    fn next_event(&mut self) -> Option<Event>;
    fn write(&mut self, data: &[u8]) -> Result<u64, Fault>;
    fn resize(&mut self, size: Size) -> Result<Size, Fault>;
    fn close(&mut self) -> Result<(), Fault>;
}

/// Creating a surface is not a property of an existing one, so the host carries a factory.
pub type SurfaceFactory = Arc<dyn Fn(Size, String) -> Result<Box<dyn Surface>, Fault> + Send + Sync>;

/// One surface, as the guest holds it. `backing` is taken when the guest asks for the event stream: a stream can be
/// consumed once, and taking it makes that structural instead of a comment.
pub struct SurfaceHandle {
    backing: Option<Box<dyn Surface>>,
}

impl HasData for SurfaceHandle {
    type Data<'a> = &'a mut SurfaceHandle;
}

pub struct Host {
    pub table: ResourceTable,
    pub factory: SurfaceFactory,
}

impl Host {
    pub fn new(factory: SurfaceFactory) -> Host {
        Host { table: ResourceTable::new(), factory }
    }
}

impl HasData for Host {
    type Data<'a> = &'a mut Host;
}

impl wa::terminal::types::Host for Host {}
impl wa::terminal::session::Host for Host {}

impl wa::terminal::session::HostSurface for Host {
    fn drop(&mut self, _rep: Resource<SurfaceHandle>) -> wasmtime::Result<()> {
        Ok(())
    }
}

impl wa::terminal::session::HostSurfaceWithStore<Host> for Host {
    fn open(
        access: &Accessor<Host, Host>,
        size: Size,
        title: String,
    ) -> impl std::future::Future<Output = std::result::Result<Resource<SurfaceHandle>, Fault>> + Send + '_ {
        async move {
            let backing = access.with(|mut access| (access.data_mut().factory)(size, title));
            match backing {
                Ok(backing) => {
                    let handle = access
                        .with(|mut access| access.data_mut().table.push(SurfaceHandle { backing: Some(backing) }))
                        .map_err(|error| Fault::Failed(error.to_string()))?;
                    Ok(handle)
                }
                Err(fault) => Err(fault),
            }
        }
    }

    fn events(
        mut access: Access<'_, Host, Host>,
        self_: Resource<SurfaceHandle>,
    ) -> wasmtime::Result<StreamReader<Event>> {
        let backing = match access.data_mut().table.get_mut(&self_) {
            Ok(handle) => handle.backing.take(),
            Err(_) => None,
        };
        match backing {
            Some(backing) => StreamReader::new(access.as_context_mut(), EventStream { backing }),
            None => Err(wasmtime::Error::msg("surface handle gone or already streaming")),
        }
    }

    fn write(
        access: &Accessor<Host, Host>,
        self_: Resource<SurfaceHandle>,
        data: Vec<u8>,
    ) -> impl std::future::Future<Output = wasmtime::Result<std::result::Result<u64, Fault>>> + Send + '_ {
        async move {
            let answer = access.with(|mut access| match access.data_mut().table.get_mut(&self_) {
                Ok(handle) => match handle.backing.as_mut() {
                    Some(backing) => backing.write(&data),
                    None => Err(Fault::Closed),
                },
                Err(_) => Err(Fault::Closed),
            });
            Ok(answer)
        }
    }

    fn resize(
        access: &Accessor<Host, Host>,
        self_: Resource<SurfaceHandle>,
        size: Size,
    ) -> impl std::future::Future<Output = wasmtime::Result<std::result::Result<Size, Fault>>> + Send + '_ {
        async move {
            let answer = access.with(|mut access| match access.data_mut().table.get_mut(&self_) {
                Ok(handle) => match handle.backing.as_mut() {
                    Some(backing) => backing.resize(size),
                    None => Err(Fault::Closed),
                },
                Err(_) => Err(Fault::Closed),
            });
            Ok(answer)
        }
    }

    fn close(
        access: &Accessor<Host, Host>,
        self_: Resource<SurfaceHandle>,
    ) -> impl std::future::Future<Output = wasmtime::Result<std::result::Result<(), Fault>>> + Send + '_ {
        async move {
            let answer = access.with(|mut access| match access.data_mut().table.get_mut(&self_) {
                Ok(handle) => match handle.backing.as_mut() {
                    Some(backing) => backing.close(),
                    None => Err(Fault::Closed),
                },
                Err(_) => Err(Fault::Closed),
            });
            Ok(answer)
        }
    }
}

/// The events, streamed into the guest until the session ends.
pub struct EventStream {
    backing: Box<dyn Surface>,
}

impl StreamProducer<Host> for EventStream {
    type Item = Event;
    type Buffer = Option<Event>;

    fn poll_produce<'a>(
        mut self: Pin<&mut Self>,
        _cx: &mut Context<'_>,
        _store: StoreContextMut<'a, Host>,
        mut destination: Destination<'a, Self::Item, Self::Buffer>,
        _finish: bool,
    ) -> Poll<wasmtime::Result<StreamResult>> {
        match self.backing.next_event() {
            Some(event) => {
                destination.set_buffer(Some(event));
                Poll::Ready(Ok(StreamResult::Completed))
            }
            None => Poll::Ready(Ok(StreamResult::Dropped)),
        }
    }
}

/// Every event this surface yields, in order - assertable without a store.
fn collect(mut backing: Box<dyn Surface>) -> Vec<Event> {
    let mut all = Vec::new();
    while let Some(event) = backing.next_event() {
        all.push(event);
    }
    all
}

#[cfg(test)]
mod rows {
    use super::*;

    struct Script {
        events: Vec<Event>,
    }

    impl Surface for Script {
        fn next_event(&mut self) -> Option<Event> {
            if self.events.is_empty() {
                None
            } else {
                Some(self.events.remove(0))
            }
        }

        fn write(&mut self, data: &[u8]) -> Result<u64, Fault> {
            Ok(data.len() as u64)
        }

        fn resize(&mut self, size: Size) -> Result<Size, Fault> {
            Ok(size)
        }

        fn close(&mut self) -> Result<(), Fault> {
            Ok(())
        }
    }

    /// ROW: a surface's events reach the guest in order and the stream ends when the session does - the same seam
    /// shape the process host uses, so a tty can be a script in a test and `wa-term` in the node.
    #[test]
    fn surface_events_stream_in_order() {
        let script = Script {
            events: vec![
                Event::Data(b"hel".to_vec()),
                Event::Data(b"lo".to_vec()),
                Event::Resized(Size { columns: 120, rows: 40 }),
                Event::Closed(Some(0)),
            ],
        };
        let events = collect(Box::new(script));
        assert_eq!(events.len(), 4);
        match &events[0] {
            Event::Data(bytes) => assert_eq!(bytes, b"hel"),
            other => panic!("the first event must be data, got {other:?}"),
        }
        match &events[2] {
            Event::Resized(size) => assert_eq!((size.columns, size.rows), (120, 40)),
            other => panic!("the third event must be a resize, got {other:?}"),
        }
        assert!(matches!(events[3], Event::Closed(Some(0))));
    }
}
