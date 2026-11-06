//! The peer cache: the addresses that keep working when the rendezvous is down.
//!
//! The directory answers *where a node is now*; after one answer the address is written here, so the
//! next call needs no directory at all. Two rules keep that from becoming a trust store:
//!
//! * the **roster wins on who** — level and public key are read from the signed roster and the cache
//!   is overwritten if it disagrees; the cache only ever contributes *addresses*;
//! * the roster's addresses keep their place at the front, so a cache written by an older roster
//!   cannot push the current one aside.
//!
//! A corrupt or unreadable file is reported and ignored (`PeerCache::from_file` returns the error);
//! the caller logs it and carries on with the roster. Failing open to the roster is right: the roster
//! is the authority, and a stale cache is exactly what the roster is there to overrule.
use crate::roster::{Roster, RosterNode};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;
use std::path::Path;

pub const CACHE_SCHEMA: u32 = 1;
pub const MAX_CACHED_ADDRESSES: usize = 8;

/// Where an address came from. The strongest source a peer ever had is kept, so the operator can see
/// in the file whether an address is the roster's own or something learned on the way.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Source {
    Learned,
    Rendezvous,
    Roster,
}

impl Source {
    pub fn as_str(self) -> &'static str {
        match self {
            Source::Learned => "learned",
            Source::Rendezvous => "rendezvous",
            Source::Roster => "roster",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CachedPeer {
    pub node_id: String,
    pub name: String,
    pub level: u8,
    pub public_key: String,
    #[serde(default)]
    pub addresses: Vec<String>,
    #[serde(default = "default_source")]
    pub source: Source,
    #[serde(default)]
    pub last_ok_ms: u64,
    #[serde(default)]
    pub last_error: String,
}

fn default_source() -> Source {
    Source::Rendezvous
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PeerCache {
    pub schema: u32,
    #[serde(default)]
    pub saved_at_ms: u64,
    #[serde(default)]
    pub peers: BTreeMap<String, CachedPeer>,
}

impl Default for PeerCache {
    fn default() -> Self {
        PeerCache { schema: CACHE_SCHEMA, saved_at_ms: 0, peers: BTreeMap::new() }
    }
}

impl PeerCache {
    pub fn empty() -> PeerCache {
        PeerCache::default()
    }

    pub fn parse(text: &str) -> Result<PeerCache, String> {
        let cache: PeerCache =
            serde_json::from_str(text).map_err(|error| format!("not a valid peer cache: {error}"))?;
        if cache.schema != CACHE_SCHEMA {
            return Err(format!("peer cache schema {} (this build speaks {CACHE_SCHEMA})", cache.schema));
        }
        Ok(cache)
    }

    /// A missing file is an empty cache (first run), never an error. A file that exists but cannot be
    /// read is an error the caller reports — a silent fallback is how a peer list rots unnoticed.
    pub fn from_file(path: impl AsRef<Path>) -> Result<PeerCache, String> {
        let path = path.as_ref();
        match std::fs::read_to_string(path) {
            Ok(text) => PeerCache::parse(&text),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(PeerCache::empty()),
            Err(error) => Err(format!("{}: {error}", path.display())),
        }
    }

    /// Write atomically (temp file in the same directory, then rename): a half-written cache is a
    /// peer list nobody can parse, and the next start would have to throw it away.
    pub fn save(&mut self, path: impl AsRef<Path>, now_ms: u64) -> Result<(), String> {
        let path = path.as_ref();
        self.saved_at_ms = now_ms;
        if let Some(parent) = path.parent() {
            wa_host_support::paths::private_dir(parent);
        }
        let text = serde_json::to_string_pretty(self).map_err(|error| error.to_string())?;
        let temporary = path.with_extension(format!("tmp-{}", std::process::id()));
        std::fs::write(&temporary, text.as_bytes()).map_err(|error| format!("{}: {error}", temporary.display()))?;
        if std::fs::rename(&temporary, path).is_err() {
            // Windows refuses to rename over an existing file.
            let _ = std::fs::remove_file(path);
            std::fs::rename(&temporary, path)
                .map_err(|error| format!("{}: {error}", path.display()))?;
        }
        Ok(())
    }

    /// Fold the signed roster in: who a node is, at what level, and where it says it can be reached.
    /// Returns how many peers were added or changed (the caller reports it once, on start).
    pub fn merge_roster(&mut self, roster: &Roster, now_ms: u64) -> usize {
        let mut changed = 0;
        for node in &roster.nodes {
            let entry = self.peers.entry(node.node_id.clone()).or_insert_with(|| CachedPeer {
                node_id: node.node_id.clone(),
                name: node.name.clone(),
                level: node.level,
                public_key: node.public_key.clone(),
                addresses: Vec::new(),
                source: Source::Roster,
                last_ok_ms: 0,
                last_error: String::new(),
            });
            let before = entry.clone();
            entry.name = node.name.clone();
            entry.level = node.level;
            entry.public_key = node.public_key.clone();
            if entry.source < Source::Roster {
                entry.source = Source::Roster;
            }
            for address in &node.addresses {
                push_address(entry, address);
            }
            if *entry != before {
                changed += 1;
            }
        }
        let _ = now_ms;
        changed
    }

    /// Fold a rendezvous `/nodes` answer in. This is discovery and only discovery: an address and a
    /// name, plus the key the rendezvous vouches for — which the roster still overrules.
    pub fn merge_rendezvous(&mut self, payload: &Value, now_ms: u64) -> usize {
        let list = payload
            .get("nodes")
            .and_then(Value::as_array)
            .or_else(|| payload.as_array());
        let Some(list) = list else { return 0 };
        let mut changed = 0;
        for node in list {
            let node_id = node["node_id"].as_str().unwrap_or_default();
            if node_id.is_empty() || !node_id.chars().all(|c| c.is_ascii_hexdigit()) {
                continue;
            }
            let name = node["name"].as_str().unwrap_or_default().to_string();
            let public_key = node["public_key"].as_str().unwrap_or_default().to_string();
            let entry = self.peers.entry(node_id.to_string()).or_insert_with(|| CachedPeer {
                node_id: node_id.to_string(),
                name: name.clone(),
                level: 0,
                public_key: public_key.clone(),
                addresses: Vec::new(),
                source: Source::Rendezvous,
                last_ok_ms: now_ms,
                last_error: String::new(),
            });
            let before = entry.clone();
            if !name.is_empty() {
                entry.name = name;
            }
            // The key is only taken from the directory when the roster has not spoken for this node:
            // a roster level and key are the authority, and that is what `source` records.
            if entry.source < Source::Roster && !public_key.is_empty() {
                entry.public_key = public_key;
            }
            if entry.source < Source::Rendezvous {
                entry.source = Source::Rendezvous;
            }
            if let Some(endpoints) = node["endpoints"].as_array() {
                for endpoint in endpoints {
                    if let Some(address) = endpoint.as_str() {
                        push_address(entry, address);
                    }
                }
            }
            if *entry != before {
                changed += 1;
            }
        }
        changed
    }

    /// An address that just worked is worth remembering in front of the others of its class.
    pub fn record_success(&mut self, node_id: &str, address: &str, now_ms: u64) {
        if let Some(entry) = self.peers.get_mut(node_id) {
            entry.last_ok_ms = now_ms;
            entry.last_error.clear();
            if !entry.addresses.iter().any(|known| known == address) {
                push_address(entry, address);
            }
        } else {
            self.peers.insert(
                node_id.to_string(),
                CachedPeer {
                    node_id: node_id.to_string(),
                    name: String::new(),
                    level: 0,
                    public_key: String::new(),
                    addresses: vec![address.to_string()],
                    source: Source::Learned,
                    last_ok_ms: now_ms,
                    last_error: String::new(),
                },
            );
        }
    }

    pub fn record_failure(&mut self, node_id: &str, error: &str) {
        if let Some(entry) = self.peers.get_mut(node_id) {
            entry.last_error = error.chars().take(160).collect();
        }
    }

    /// Where to try, cheapest first: the roster's own list in its order (a LAN address before a
    /// public one), then anything the cache learned that the roster does not know yet.
    pub fn addresses(&self, node: &RosterNode) -> Vec<String> {
        let mut ordered: Vec<String> = Vec::new();
        let mut roster_addresses: Vec<String> = node.addresses.clone();
        roster_addresses.sort_by_key(|address| RosterNode::address_rank(address));
        for address in roster_addresses {
            if !ordered.contains(&address) {
                ordered.push(address);
            }
        }
        if let Some(entry) = self.peers.get(&node.node_id) {
            let mut cached: Vec<String> = entry
                .addresses
                .iter()
                .filter(|address| !ordered.contains(address))
                .cloned()
                .collect();
            cached.sort_by_key(|address| RosterNode::address_rank(address));
            ordered.extend(cached);
        }
        ordered.truncate(MAX_CACHED_ADDRESSES);
        ordered
    }

    pub fn peer(&self, node_id: &str) -> Option<&CachedPeer> {
        self.peers.get(node_id)
    }

    pub fn len(&self) -> usize {
        self.peers.len()
    }

    pub fn is_empty(&self) -> bool {
        self.peers.is_empty()
    }
}

fn push_address(entry: &mut CachedPeer, address: &str) {
    let address = address.trim();
    if address.is_empty() || entry.addresses.iter().any(|known| known == address) {
        return;
    }
    if entry.addresses.len() >= MAX_CACHED_ADDRESSES {
        return;
    }
    entry.addresses.push(address.to_string());
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::roster::Draft;
    use crate::testkit::{fleet_key, node};

    fn roster() -> Roster {
        Draft {
            fleet: "ohana".into(),
            issued_at: 1_762_000_000,
            expires_at: 0,
            nodes: vec![
                node("laptop", 0, &["147.15.64.233:8891", "192.168.1.10:8891"]),
                node("oracle", 1, &[]),
            ],
        }
        .sign(&fleet_key())
    }

    #[test]
    fn the_roster_comes_first_and_a_lan_address_before_a_public_one() {
        let roster = roster();
        let mut cache = PeerCache::empty();
        cache.merge_roster(&roster, 1_762_000_000);
        cache.merge_rendezvous(
            &serde_json::json!({"nodes":[{"node_id": roster.nodes[1].node_id, "name": "oracle",
                                          "public_key": roster.nodes[1].public_key,
                                          "endpoints": ["oracle.example.net:8891"]}]}),
            1_762_000_000,
        );
        cache.record_success(&roster.nodes[1].node_id, "10.0.0.4:8891", 1_762_000_100);
        let addresses = cache.addresses(&roster.nodes[1]);
        assert_eq!(addresses, vec!["10.0.0.4:8891", "oracle.example.net:8891"]);
        // and the roster's own list is LAN first, its order kept inside a class
        assert_eq!(
            cache.addresses(&roster.nodes[0]),
            vec!["192.168.1.10:8891", "147.15.64.233:8891"]
        );
    }

    #[test]
    fn the_directory_may_not_change_who_a_node_is_once_the_roster_has_said() {
        let roster = roster();
        let mut cache = PeerCache::empty();
        cache.merge_roster(&roster, 1_762_000_000);
        cache.merge_rendezvous(
            &serde_json::json!({"nodes":[{"node_id": roster.nodes[0].node_id, "name": "laptop",
                                          "public_key": "deadbeef", "endpoints": ["6.6.6.6:8891"]}]}),
            1_762_000_000,
        );
        let peer = cache.peer(&roster.nodes[0].node_id).unwrap();
        assert_eq!(peer.public_key, roster.nodes[0].public_key);
        assert_eq!(peer.level, 0);
        assert_eq!(peer.source, Source::Roster);
        // the address is still learned: it is a hint about where, not about who
        assert!(cache.addresses(&roster.nodes[0]).contains(&"6.6.6.6:8891".to_string()));
    }

    #[test]
    fn a_cache_round_trips_and_a_broken_one_is_reported_rather_than_ignored() {
        let roster = roster();
        let mut cache = PeerCache::empty();
        cache.merge_roster(&roster, 1_762_000_000);
        let directory = std::env::temp_dir().join(format!("wa-mesh-cache-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&directory);
        let path = directory.join("peers.json");
        cache.save(&path, 1_762_000_100).unwrap();
        let reloaded = PeerCache::from_file(&path).unwrap();
        assert_eq!(reloaded.len(), cache.len());
        assert_eq!(reloaded.saved_at_ms, 1_762_000_100);
        assert_eq!(reloaded.addresses(&roster.nodes[0]), cache.addresses(&roster.nodes[0]));

        std::fs::write(&path, "{not json").unwrap();
        let error = PeerCache::from_file(&path).unwrap_err();
        assert!(error.contains("not a valid peer cache"), "{error}");
        std::fs::write(&path, r#"{"schema":9}"#).unwrap();
        assert!(PeerCache::from_file(&path).is_err());
        let _ = std::fs::remove_file(&path);
        assert!(PeerCache::from_file(&path).unwrap().is_empty(), "a missing cache is a first run, not an error");
        let _ = std::fs::remove_dir_all(&directory);
    }

    #[test]
    fn an_unknown_field_in_the_cache_is_refused() {
        assert!(PeerCache::parse(r#"{"schema":1,"peers":{},"extra":true}"#).is_err());
    }
}
