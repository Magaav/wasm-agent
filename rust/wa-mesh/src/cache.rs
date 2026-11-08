//! The peer cache's file: `peers.json`, the addresses that keep working when the rendezvous is down.
//!
//! The *rule* is `wa-mesh-core::cache`'s — the roster wins on who (level and public key), the directory
//! only ever contributes *where*, and a private address is tried before a public one — because the
//! `wa:mesh` guest answers it too when `WA_MESH_COMPONENT=1`. This file is the node's half: the path, the
//! atomic write, and the one-generation backup that keeps a half-written cache from being a peer list
//! nobody can parse.
use std::path::Path;

pub use wa_mesh_core::cache::{CachedPeer, PeerCache, Source};

/// Write atomically (temp file in the same directory, then rename): a half-written cache is a peer list
/// nobody can parse, and the next start would have to throw it away.
pub fn save(cache: &mut PeerCache, path: impl AsRef<Path>, now_ms: u64) -> Result<(), String> {
    let path = path.as_ref();
    let text = cache.encoded(now_ms)?;
    if let Some(parent) = path.parent() {
        wa_host_support::paths::private_dir(parent);
    }
    let temporary = path.with_extension(format!("tmp-{}", std::process::id()));
    std::fs::write(&temporary, text.as_bytes()).map_err(|error| format!("{}: {error}", temporary.display()))?;
    if std::fs::rename(&temporary, path).is_err() {
        // Windows refuses to rename over an existing file.
        let _ = std::fs::remove_file(path);
        std::fs::rename(&temporary, path).map_err(|error| format!("{}: {error}", path.display()))?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use wa_mesh_core::roster::Draft;

    fn roster() -> wa_mesh_core::Roster {
        Draft {
            fleet: "ohana".into(),
            issued_at: 1_762_000_000,
            expires_at: 0,
            nodes: vec![
                crate::testkit::node("laptop", 0, &["147.15.64.233:8891", "192.168.1.10:8891"]),
                crate::testkit::node("oracle", 1, &[]),
            ],
        }
        .sign(&crate::testkit::fleet_key())
    }

    #[test]
    fn a_cache_round_trips_through_the_nodes_file() {
        let roster = roster();
        let mut cache = PeerCache::empty();
        cache.merge_roster(&roster, 1_762_000_000);
        let directory = std::env::temp_dir().join(format!("wa-mesh-cache-file-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&directory);
        let path = directory.join("peers.json");
        save(&mut cache, &path, 1_762_000_100).unwrap();
        let reloaded = PeerCache::from_file(&path).unwrap();
        assert_eq!(reloaded.len(), cache.len());
        assert_eq!(reloaded.saved_at_ms, 1_762_000_100);
        assert_eq!(reloaded.addresses(&roster.nodes[0]), cache.addresses(&roster.nodes[0]));
        std::fs::write(&path, "{not json").unwrap();
        assert!(PeerCache::from_file(&path).unwrap_err().contains("not a valid peer cache"));
        let _ = std::fs::remove_file(&path);
        assert!(PeerCache::from_file(&path).unwrap().is_empty(), "a missing cache is a first run");
        let _ = std::fs::remove_dir_all(&directory);
    }
}
