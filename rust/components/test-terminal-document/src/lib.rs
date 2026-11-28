//! TEST FIXTURE for the terminal document seam. Not shipped, not published, not in `components.lock`.

wit_bindgen::generate!({
    path: "wit",
    world: "fixture",
    generate_all,
});

use crate::exports::wa::test_terminal_document::painter::{Guest, Painted};
use crate::wa::terminal::document;

struct Painter;

impl Guest for Painter {
    async fn paint(title: String, body: String) -> Result<Painted, String> {
        let head = document::head(title.clone()).await.map_err(|error| format!("{error:?}"))?;
        document::write(body.clone()).await.map_err(|error| format!("{error:?}"))?;
        document::block(false).await.map_err(|error| format!("{error:?}"))?;
        let dirty = document::dirty();
        let last = document::head(format!("end {}", body.len())).await.map_err(|error| format!("{error:?}"))?;
        Ok(Painted { lines_written: 2, last_line: last.max(head), dirty })
    }
}

export!(Painter);
