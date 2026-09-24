//! Live freshness: watch the indexed root and reindex changed files.
//!
//! `notify` gives change events; the reindex itself is the same content-hash incremental pass the
//! CLI runs, so an event that did not actually change bytes costs nothing. Events are debounced
//! because a single save arrives as a burst (create temp, write, rename), and reindexing on each
//! one would parse the same file three times.

use crate::store::Store;
use notify::{RecursiveMode, Watcher};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{channel, RecvTimeoutError};
use std::sync::Arc;
use std::time::Duration;

/// Dropping the handle stops the watcher thread.
pub struct WatchHandle {
    stop: Arc<AtomicBool>,
}

impl WatchHandle {
    pub fn stop(&self) {
        self.stop.store(true, Ordering::SeqCst);
    }
}

impl Drop for WatchHandle {
    fn drop(&mut self) {
        self.stop();
    }
}

/// Index `root` once, then keep the `db` fresh as files change. Never blocks the caller.
pub fn spawn(root: PathBuf, db: PathBuf) -> std::io::Result<WatchHandle> {
    let stop = Arc::new(AtomicBool::new(false));
    let stop_thread = stop.clone();
    std::thread::Builder::new()
        .name("wa-graph-watch".into())
        .spawn(move || {
            let (tx, rx) = channel();
            let mut watcher = match notify::recommended_watcher(move |res| {
                let _ = tx.send(res);
            }) {
                Ok(watcher) => watcher,
                Err(error) => {
                    eprintln!("graph_watch_create_failed: {error}");
                    return;
                }
            };
            if let Err(error) = watcher.watch(&root, RecursiveMode::Recursive) {
                eprintln!("graph_watch_register_failed: {error}");
                return;
            }
            // Register first: an edit during the initial scan must leave an event to replay.
            index_once(&root, &db);
            while !stop_thread.load(Ordering::SeqCst) {
                match rx.recv_timeout(Duration::from_millis(500)) {
                    Ok(Ok(event)) => {
                        if ignored(&event) {
                            continue;
                        }
                        // Debounce: drain the rest of the burst, then reindex once.
                        loop {
                            match rx.recv_timeout(Duration::from_millis(250)) {
                                Ok(Ok(_)) => {}
                                Ok(Err(error)) => eprintln!("graph_watch_event_failed: {error}"),
                                Err(_) => break,
                            }
                        }
                        index_once(&root, &db);
                    }
                    Ok(Err(error)) => {
                        eprintln!("graph_watch_event_failed: {error}");
                        index_once(&root, &db);
                    }
                    Err(RecvTimeoutError::Timeout) => {}
                    Err(RecvTimeoutError::Disconnected) => break,
                }
            }
            drop(watcher);
        })?;
    Ok(WatchHandle { stop })
}

/// Build artifacts and VCS internals are not source; a change there must not trigger a reindex.
fn ignored(event: &notify::Event) -> bool {
    event.paths.iter().all(|path| {
        let text = path.to_string_lossy().replace('\\', "/");
        text.contains("/.git/")
            || text.contains("/target/")
            || text.contains("/.wa-graph/")
            || text.contains("/node_modules/")
            || text.contains("/releases/")
    })
}

fn index_once(root: &Path, db: &Path) {
    match Store::open(db).and_then(|mut store| store.index(root, false)) {
        Ok(_) => {}
        Err(error) => eprintln!("graph_watch_index_failed: {error}"),
    }
}
