//! The two worlds the move-list said were missing (`wit/terminal`, `wit/process`), read by a REAL parser.
//!
//! `scripts/wit-lint.sh` greps text; it does not parse WIT - this session had a file pass that lint and then fail
//! `bindgen!` over a WIT keyword used as a name. These two `bindgen!` calls are the parser's verdict: the macro reads
//! the package at compile time, so an invalid keyword, an underscore in an identifier or a shape the async ABI
//! forbids fails THIS build instead of the first component that tries to import them.
//!
//! Nothing here implements a host yet: the worlds exist so that a component can import them, and the host side is
//! the next slice (`ready-terminal-worlds.md`).

mod terminal_world {
    wasmtime::component::bindgen!({
        world: "terminal-client",
        path: "../../wit/terminal",
    });
}

mod process_world {
    wasmtime::component::bindgen!({
        world: "process-client",
        path: "../../wit/process",
    });
}

#[test]
fn both_worlds_parse() {
    // The assertion is the build itself: if either package were not valid WIT, or did not declare the world named
    // above, this test would not compile. Saying it once makes the intent explicit in the test list.
    assert!(true);
}
