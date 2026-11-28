//! The `wa:terminal` seam: the DOCUMENT the node paints, behind a trait so the node wires `wa-term`'s program in
//! (over `wa-term-proto`) and a test wires a script.
//!
//! The world was reshaped on 28/11 after reading the program's own dispatcher: it answers a document (write,
//! block, code_block, head, rewrite, pin_toggle) and no `open` - a pty is the operations runner's job (law 17).

use std::future;
use wasmtime::component::{Access, Accessor, HasData, ResourceTable};

wasmtime::component::bindgen!({
    world: "terminal-client",
    path: "../../wit/terminal",
});

use wa::terminal::types::Error as Fault;

/// Where the document comes from: the node backs this with the terminal program, a test with a script.
pub trait Document: Send {
    fn write(&mut self, text: &str) -> Result<(), Fault>;
    fn block(&mut self, open: bool) -> Result<(), Fault>;
    fn code_block(&mut self) -> Result<(), Fault>;
    fn head(&mut self, text: &str) -> Result<u32, Fault>;
    fn rewrite(&mut self, line: u32, text: &str) -> Result<u32, Fault>;
    fn pin_toggle(&mut self) -> Result<Option<bool>, Fault>;
    fn dirty(&mut self) -> bool;
}

pub struct Host {
    pub table: ResourceTable,
    pub document: Box<dyn Document>,
}

impl Host {
    pub fn new(document: Box<dyn Document>) -> Host {
        Host { table: ResourceTable::new(), document }
    }
}

impl HasData for Host {
    type Data<'a> = &'a mut Host;
}

impl wa::terminal::types::Host for Host {}

/// The one sync verb: whether the document changed since the last frame.
impl wa::terminal::document::Host for Host {
    fn dirty(&mut self) -> bool {
        self.document.dirty()
    }
}

/// The async verbs. They resolve FLAT to the WIT error - no `wasmtime::Result` layer, unlike the resource methods
/// of the process world, which nest.
impl wa::terminal::document::HostWithStore<Host> for Host {
    fn write<'a>(
        access: &'a Accessor<Host, Host>,
        text: String,
    ) -> impl future::Future<Output = Result<(), Fault>> + Send + 'a {
        async move { access.with(|mut access| access.data_mut().document.write(&text)) }
    }

    fn block<'a>(
        access: &'a Accessor<Host, Host>,
        open: bool,
    ) -> impl future::Future<Output = Result<(), Fault>> + Send + 'a {
        async move { access.with(|mut access| access.data_mut().document.block(open)) }
    }

    fn code_block<'a>(
        access: &'a Accessor<Host, Host>,
    ) -> impl future::Future<Output = Result<(), Fault>> + Send + 'a {
        async move { access.with(|mut access| access.data_mut().document.code_block()) }
    }

    fn head<'a>(
        access: &'a Accessor<Host, Host>,
        text: String,
    ) -> impl future::Future<Output = Result<u32, Fault>> + Send + 'a {
        async move { access.with(|mut access| access.data_mut().document.head(&text)) }
    }

    fn rewrite<'a>(
        access: &'a Accessor<Host, Host>,
        line: u32,
        text: String,
    ) -> impl future::Future<Output = Result<u32, Fault>> + Send + 'a {
        async move { access.with(|mut access| access.data_mut().document.rewrite(line, &text)) }
    }

    fn pin_toggle<'a>(
        access: &'a Accessor<Host, Host>,
    ) -> impl future::Future<Output = Result<Option<bool>, Fault>> + Send + 'a {
        async move { access.with(|mut access| access.data_mut().document.pin_toggle()) }
    }
}

#[cfg(test)]
mod rows {
    use super::*;

    #[derive(Default)]
    struct Script {
        lines: Vec<String>,
        pinned: Option<bool>,
        dirty: bool,
    }

    impl Document for Script {
        fn write(&mut self, text: &str) -> Result<(), Fault> {
            self.lines.push(text.to_string());
            self.dirty = true;
            Ok(())
        }

        fn block(&mut self, _open: bool) -> Result<(), Fault> {
            Ok(())
        }

        fn code_block(&mut self) -> Result<(), Fault> {
            Ok(())
        }

        fn head(&mut self, text: &str) -> Result<u32, Fault> {
            self.lines.push(text.to_string());
            Ok(self.lines.len() as u32)
        }

        fn rewrite(&mut self, line: u32, text: &str) -> Result<u32, Fault> {
            if line == 0 || line as usize > self.lines.len() {
                return Err(Fault::Refused("no such line".to_string()));
            }
            self.lines[line as usize - 1] = text.to_string();
            Ok(line)
        }

        fn pin_toggle(&mut self) -> Result<Option<bool>, Fault> {
            Ok(self.pinned)
        }

        fn dirty(&mut self) -> bool {
            self.dirty
        }
    }

    /// ROW: the document seam answers in the program's own terms - a heading lands where the program says it did,
    /// a rewrite of a line that does not exist is a refusal rather than a silent nothing, and `dirty` follows the
    /// writes. This is the shape `wa-term-proto` carries, tested without the program.
    #[test]
    fn document_verbs_answer_in_the_programs_terms() {
        let mut document = Script::default();
        assert_eq!(document.head("one").unwrap(), 1);
        assert_eq!(document.head("two").unwrap(), 2);
        document.write("three").unwrap();
        assert!(document.dirty());
        assert_eq!(document.rewrite(2, "second").unwrap(), 2);
        match document.rewrite(9, "nowhere") {
            Err(Fault::Refused(_)) => {}
            other => panic!("rewriting a missing line must be refused, got {other:?}"),
        }
        assert_eq!(document.pin_toggle().unwrap(), None);
    }
}
