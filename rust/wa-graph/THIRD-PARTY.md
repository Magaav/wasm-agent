# Go grammar provenance

`tree-sitter-go = "=0.23.4"` is the official maintained tree-sitter Go grammar,
https://github.com/tree-sitter/tree-sitter-go, released under MIT. This pinned
release declares tree-sitter 0.24 for its own tests and is compatible with our
0.24 parser; it is not a claim that 0.23.4 is the latest grammar release.
Cargo.lock pins the crates.io archive checksum:
`b13d476345220dbe600147dd444165c5791bf85ef53e28acbedd46112ee18431`.

The published crate metadata declares MIT but its include list omits LICENSE.
The full notice is retained at `licenses/tree-sitter-go-LICENSE`, retrieved from
https://raw.githubusercontent.com/tree-sitter/tree-sitter-go/v0.23.4/LICENSE.
SHA-256: `2e0110e07abef7c2548b26ec9d6969775617ca539a0dc8dbeeb14d6452c711d1`.
No Go SDK, module cache download, or inference service is required for indexing.
