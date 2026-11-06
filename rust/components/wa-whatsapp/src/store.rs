//! Durable store: wacore's InMemoryBackend for every read, plus write-through of the state a restart
//! must keep to the host key-value file (wa_kv), replayed into memory at start.
//!
//! Persisted (a restart without them means re-pairing or undecryptable messages): the device, Signal
//! identities, sessions, pre-keys (with the uploaded flag), signed pre-keys, sender keys, app-state
//! sync keys, versions and mutation MACs, LID<->PN mappings and privacy tokens. Everything else
//! (device lists, base keys, sent-message cache, group metadata, sender-key distribution status,
//! message secrets) is a cache the protocol rebuilds from the network, kept in memory only.
//!
//! Keys: dev | id/<addr> | ses/<addr> | pk/<id> | spk/<id> | sk/<addr> | sync/<hex> | ver/<name> |
//! mac/<name>/<hex> | lid/<lid> | tc/<jid>.
use async_trait::async_trait;
use bytes::Bytes;
use std::sync::Arc;
use wacore::appstate::hash::HashState;
use wacore::store::error::{Result, StoreError};
use wacore::store::in_memory::InMemoryBackend;
use wacore::store::traits::*;
use wacore::store::Device;
use wacore_appstate::processor::AppStateMutationMAC;

use crate::wa::kernel::kv;

fn io(what: &str, error: crate::wa::kernel::types::Error) -> StoreError {
    StoreError::Io(std::io::Error::other(format!("kv {what} failed: {error:?}")))
}
// Every kv call is awaited: `wa:kernel@0.2` declares them async. The host answers without
// suspending (a local store), so each await completes in the poll it started in and the replay
// costs what it did on 0.1.
async fn put(key: &str, value: &[u8]) -> Result<()> {
    kv::set(key.as_bytes().to_vec(), value.to_vec()).await.map_err(|e| io("set", e))
}
async fn del(key: &str) -> Result<()> {
    kv::delete(key.as_bytes().to_vec()).await.map_err(|e| io("delete", e))
}
async fn del_prefix(prefix: &str) -> Result<()> {
    kv::delete_prefix(prefix.as_bytes().to_vec()).await.map(|_| ()).map_err(|e| io("delete-prefix", e))
}
async fn get(key: &str) -> Option<Vec<u8>> {
    kv::get(key.as_bytes().to_vec()).await.ok().flatten()
}
fn json<T: serde::Serialize>(value: &T) -> Result<Vec<u8>> {
    serde_json::to_vec(value).map_err(|e| StoreError::Serialization(Box::new(e)))
}
fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}
fn unhex(text: &str) -> Option<Vec<u8>> {
    (0..text.len()).step_by(2).map(|i| u8::from_str_radix(text.get(i..i + 2)?, 16).ok()).collect()
}

/// Whether the stored device record (read directly, independent of the replay) is a paired one.
pub async fn stored_device_paired() -> bool {
    get("dev").await.and_then(|v| serde_json::from_slice::<serde_json::Value>(&v).ok()).is_some_and(|d| !d["pn"].is_null())
}

pub struct PersistentBackend {
    inner: InMemoryBackend,
}

impl PersistentBackend {
    /// Open the store and replay everything persisted into memory. Returns the entry count.
    pub async fn open() -> Result<(Self, usize)> {
        let backend = PersistentBackend { inner: InMemoryBackend::new() };
        // Replay in pages ordered by key (kv.scan with an exclusive cursor).
        let mut entries: Vec<(String, Vec<u8>)> = Vec::new();
        let mut cursor: Option<Vec<u8>> = None;
        loop {
            let page = kv::scan(Vec::new(), cursor.clone(), 1000).await.map_err(|e| io("scan", e))?;
            if page.is_empty() {
                break;
            }
            cursor = page.last().map(|e| e.key.clone());
            entries.extend(page.into_iter().map(|e| (String::from_utf8_lossy(&e.key).into_owned(), e.value)));
        }
        // The device first: everything else hangs off it.
        entries.sort_by_key(|(k, _)| k != "dev");
        let count = entries.len();
        for (key, value) in entries {
            backend.restore(&key, &value).await;
        }
        Ok((backend, count))
    }

    async fn restore(&self, key: &str, v: &[u8]) {
        let (kind, rest) = key.split_once('/').unwrap_or((key, ""));
        let i = &self.inner;
        let _ = match kind {
            "dev" => match serde_json::from_slice::<Device>(v) {
                Ok(device) => i.save(&device).await,
                Err(_) => Ok(()),
            },
            "id" if v.len() == 32 => i.put_identity(rest, v.try_into().unwrap()).await,
            "ses" => i.put_session(rest, v).await,
            "pk" if !v.is_empty() => match rest.parse::<u32>() {
                Ok(id) => i.store_prekey(id, &v[1..], v[0] == 1).await,
                Err(_) => Ok(()),
            },
            "spk" => match rest.parse::<u32>() {
                Ok(id) => i.store_signed_prekey(id, v).await,
                Err(_) => Ok(()),
            },
            "sk" => i.put_sender_key(rest, v).await,
            "sync" => match (unhex(rest), serde_json::from_slice::<AppStateSyncKey>(v)) {
                (Some(id), Ok(key)) => i.set_sync_key(&id, key).await,
                _ => Ok(()),
            },
            "ver" => match serde_json::from_slice::<HashState>(v) {
                Ok(state) => i.set_version(rest, state).await,
                Err(_) => Ok(()),
            },
            "mac" => match rest.rsplit_once('/').and_then(|(name, idx)| Some((name, unhex(idx)?))) {
                Some((name, index_mac)) => i.put_mutation_macs(name, 0, &[AppStateMutationMAC { index_mac, value_mac: v.to_vec() }]).await,
                None => Ok(()),
            },
            "lid" => match serde_json::from_slice::<LidPnMappingEntry>(v) {
                Ok(entry) => i.put_lid_mapping(&entry).await,
                Err(_) => Ok(()),
            },
            "tc" => match serde_json::from_slice::<TcTokenEntry>(v) {
                Ok(entry) => i.put_tc_token(rest, &entry).await,
                Err(_) => Ok(()),
            },
            _ => Ok(()),
        };
    }
}

#[async_trait(?Send)]
impl SignalStore for PersistentBackend {
    async fn put_identity(&self, address: &str, key: [u8; 32]) -> Result<()> {
        put(&format!("id/{address}"), &key).await?;
        self.inner.put_identity(address, key).await
    }
    async fn load_identity(&self, address: &str) -> Result<Option<[u8; 32]>> {
        self.inner.load_identity(address).await
    }
    async fn delete_identity(&self, address: &str) -> Result<()> {
        del(&format!("id/{address}")).await?;
        self.inner.delete_identity(address).await
    }
    async fn get_session(&self, address: &str) -> Result<Option<Bytes>> {
        self.inner.get_session(address).await
    }
    async fn put_session(&self, address: &str, session: &[u8]) -> Result<()> {
        put(&format!("ses/{address}"), session).await?;
        self.inner.put_session(address, session).await
    }
    async fn delete_session(&self, address: &str) -> Result<()> {
        del(&format!("ses/{address}")).await?;
        self.inner.delete_session(address).await
    }
    async fn has_signal_state_for_user(&self, user: &str) -> Result<bool> {
        self.inner.has_signal_state_for_user(user).await
    }
    async fn store_prekey(&self, id: u32, record: &[u8], uploaded: bool) -> Result<()> {
        let mut value = Vec::with_capacity(record.len() + 1);
        value.push(uploaded as u8);
        value.extend_from_slice(record);
        put(&format!("pk/{id}"), &value).await?;
        self.inner.store_prekey(id, record, uploaded).await
    }
    async fn load_prekey(&self, id: u32) -> Result<Option<Bytes>> {
        self.inner.load_prekey(id).await
    }
    async fn mark_prekeys_uploaded(&self, ids: &[u32]) -> Result<()> {
        for id in ids {
            let key = format!("pk/{id}");
            if let Some(mut value) = get(&key).await {
                if !value.is_empty() && value[0] != 1 {
                    value[0] = 1;
                    put(&key, &value).await?;
                }
            }
        }
        self.inner.mark_prekeys_uploaded(ids).await
    }
    async fn remove_prekey(&self, id: u32) -> Result<()> {
        del(&format!("pk/{id}")).await?;
        self.inner.remove_prekey(id).await
    }
    async fn get_max_prekey_id(&self) -> Result<u32> {
        self.inner.get_max_prekey_id().await
    }
    async fn store_signed_prekey(&self, id: u32, record: &[u8]) -> Result<()> {
        put(&format!("spk/{id}"), record).await?;
        self.inner.store_signed_prekey(id, record).await
    }
    async fn load_signed_prekey(&self, id: u32) -> Result<Option<Vec<u8>>> {
        self.inner.load_signed_prekey(id).await
    }
    async fn load_all_signed_prekeys(&self) -> Result<Vec<(u32, Vec<u8>)>> {
        self.inner.load_all_signed_prekeys().await
    }
    async fn remove_signed_prekey(&self, id: u32) -> Result<()> {
        del(&format!("spk/{id}")).await?;
        self.inner.remove_signed_prekey(id).await
    }
    async fn put_sender_key(&self, address: &str, record: &[u8]) -> Result<()> {
        put(&format!("sk/{address}"), record).await?;
        self.inner.put_sender_key(address, record).await
    }
    async fn get_sender_key(&self, address: &str) -> Result<Option<Vec<u8>>> {
        self.inner.get_sender_key(address).await
    }
    async fn delete_sender_key(&self, address: &str) -> Result<()> {
        del(&format!("sk/{address}")).await?;
        self.inner.delete_sender_key(address).await
    }
}

#[async_trait(?Send)]
impl AppSyncStore for PersistentBackend {
    async fn get_sync_key(&self, key_id: &[u8]) -> Result<Option<AppStateSyncKey>> {
        self.inner.get_sync_key(key_id).await
    }
    async fn set_sync_key(&self, key_id: &[u8], key: AppStateSyncKey) -> Result<()> {
        put(&format!("sync/{}", hex(key_id)), &json(&key)?).await?;
        self.inner.set_sync_key(key_id, key).await
    }
    async fn get_version(&self, name: &str) -> Result<HashState> {
        self.inner.get_version(name).await
    }
    async fn set_version(&self, name: &str, state: HashState) -> Result<()> {
        put(&format!("ver/{name}"), &json(&state)?).await?;
        self.inner.set_version(name, state).await
    }
    async fn put_mutation_macs(&self, name: &str, version: u64, mutations: &[AppStateMutationMAC]) -> Result<()> {
        for m in mutations {
            put(&format!("mac/{name}/{}", hex(&m.index_mac)), &m.value_mac).await?;
        }
        self.inner.put_mutation_macs(name, version, mutations).await
    }
    async fn get_mutation_mac(&self, name: &str, index_mac: &[u8]) -> Result<Option<Vec<u8>>> {
        self.inner.get_mutation_mac(name, index_mac).await
    }
    async fn delete_mutation_macs(&self, name: &str, index_macs: &[Vec<u8>]) -> Result<()> {
        for idx in index_macs {
            del(&format!("mac/{name}/{}", hex(idx))).await?;
        }
        self.inner.delete_mutation_macs(name, index_macs).await
    }
    async fn clear_mutation_macs(&self, name: &str) -> Result<()> {
        del_prefix(&format!("mac/{name}/")).await?;
        self.inner.clear_mutation_macs(name).await
    }
    async fn get_latest_sync_key_id(&self) -> Result<Option<Vec<u8>>> {
        self.inner.get_latest_sync_key_id().await
    }
}

#[async_trait(?Send)]
impl ProtocolStore for PersistentBackend {
    async fn get_sender_key_devices(&self, group_jid: &str) -> Result<Vec<(String, bool)>> {
        self.inner.get_sender_key_devices(group_jid).await
    }
    async fn set_sender_key_status(&self, group_jid: &str, entries: &[(&str, bool)]) -> Result<()> {
        self.inner.set_sender_key_status(group_jid, entries).await
    }
    async fn clear_sender_key_devices(&self, group_jid: &str) -> Result<()> {
        self.inner.clear_sender_key_devices(group_jid).await
    }
    async fn delete_sender_key_device_rows(&self, device_jids: &[&str]) -> Result<()> {
        self.inner.delete_sender_key_device_rows(device_jids).await
    }
    async fn clear_all_sender_key_devices(&self) -> Result<()> {
        self.inner.clear_all_sender_key_devices().await
    }
    async fn get_lid_mapping(&self, lid: &str) -> Result<Option<LidPnMappingEntry>> {
        self.inner.get_lid_mapping(lid).await
    }
    async fn get_pn_mapping(&self, phone: &str) -> Result<Option<LidPnMappingEntry>> {
        self.inner.get_pn_mapping(phone).await
    }
    async fn put_lid_mapping(&self, entry: &LidPnMappingEntry) -> Result<()> {
        put(&format!("lid/{}", entry.lid), &json(entry)?).await?;
        self.inner.put_lid_mapping(entry).await
    }
    async fn get_all_lid_mappings(&self) -> Result<Vec<LidPnMappingEntry>> {
        self.inner.get_all_lid_mappings().await
    }
    async fn save_base_key(&self, address: &str, message_id: &str, base_key: &[u8]) -> Result<()> {
        self.inner.save_base_key(address, message_id, base_key).await
    }
    async fn has_same_base_key(&self, address: &str, message_id: &str, current_base_key: &[u8]) -> Result<bool> {
        self.inner.has_same_base_key(address, message_id, current_base_key).await
    }
    async fn delete_base_key(&self, address: &str, message_id: &str) -> Result<()> {
        self.inner.delete_base_key(address, message_id).await
    }
    async fn update_device_list(&self, record: DeviceListRecord) -> Result<()> {
        self.inner.update_device_list(record).await
    }
    async fn get_devices(&self, user: &str) -> Result<Option<DeviceListRecord>> {
        self.inner.get_devices(user).await
    }
    async fn delete_devices(&self, user: &str) -> Result<()> {
        self.inner.delete_devices(user).await
    }
    async fn get_group_metadata(&self, group_jid: &str) -> Result<Option<Vec<u8>>> {
        self.inner.get_group_metadata(group_jid).await
    }
    async fn put_group_metadata(&self, group_jid: &str, blob: &[u8]) -> Result<()> {
        self.inner.put_group_metadata(group_jid, blob).await
    }
    async fn delete_group_metadata(&self, group_jid: &str) -> Result<()> {
        self.inner.delete_group_metadata(group_jid).await
    }
    async fn get_tc_token(&self, jid: &str) -> Result<Option<TcTokenEntry>> {
        self.inner.get_tc_token(jid).await
    }
    async fn put_tc_token(&self, jid: &str, entry: &TcTokenEntry) -> Result<()> {
        put(&format!("tc/{jid}"), &json(entry)?).await?;
        self.inner.put_tc_token(jid, entry).await
    }
    async fn delete_tc_token(&self, jid: &str) -> Result<()> {
        del(&format!("tc/{jid}")).await?;
        self.inner.delete_tc_token(jid).await
    }
    async fn get_all_tc_token_jids(&self) -> Result<Vec<String>> {
        self.inner.get_all_tc_token_jids().await
    }
    async fn delete_expired_tc_tokens(&self, token_cutoff: i64, sender_cutoff: i64) -> Result<u32> {
        let before = self.inner.get_all_tc_token_jids().await?;
        let n = self.inner.delete_expired_tc_tokens(token_cutoff, sender_cutoff).await?;
        if n > 0 {
            let after: std::collections::HashSet<String> = self.inner.get_all_tc_token_jids().await?.into_iter().collect();
            for jid in before.iter().filter(|j| !after.contains(*j)) {
                del(&format!("tc/{jid}")).await?;
            }
        }
        Ok(n)
    }
    async fn store_sent_message(&self, chat_jid: &str, message_id: &str, payload: &[u8]) -> Result<()> {
        self.inner.store_sent_message(chat_jid, message_id, payload).await
    }
    async fn take_sent_message(&self, chat_jid: &str, message_id: &str) -> Result<Option<Vec<u8>>> {
        self.inner.take_sent_message(chat_jid, message_id).await
    }
    async fn delete_expired_sent_messages(&self, cutoff_timestamp: i64) -> Result<u32> {
        self.inner.delete_expired_sent_messages(cutoff_timestamp).await
    }
    async fn store_pending_inbound(&self, chat: &str, sender: &str, id: &str, message: &[u8]) -> Result<()> {
        self.inner.store_pending_inbound(chat, sender, id, message).await
    }
    async fn get_pending_inbound(&self, chat: &str, sender: &str, id: &str) -> Result<Option<Vec<u8>>> {
        self.inner.get_pending_inbound(chat, sender, id).await
    }
    async fn delete_pending_inbound(&self, chat: &str, sender: &str, id: &str) -> Result<()> {
        self.inner.delete_pending_inbound(chat, sender, id).await
    }
    async fn delete_expired_pending_inbound(&self, cutoff_timestamp: i64) -> Result<u32> {
        self.inner.delete_expired_pending_inbound(cutoff_timestamp).await
    }
}

#[async_trait(?Send)]
impl DeviceStore for PersistentBackend {
    async fn save(&self, device: &Device) -> Result<()> {
        put("dev", &json(device)?).await?;
        self.inner.save(device).await
    }
    async fn load(&self) -> Result<Option<Device>> {
        self.inner.load().await
    }
    async fn exists(&self) -> Result<bool> {
        self.inner.exists().await
    }
    async fn create(&self) -> Result<i32> {
        self.inner.create().await
    }
}

#[async_trait(?Send)]
impl MsgSecretStore for PersistentBackend {
    async fn put_msg_secrets(&self, entries: Vec<MsgSecretEntry>) -> Result<usize> {
        self.inner.put_msg_secrets(entries).await
    }
    async fn get_msg_secret(&self, chat: &str, sender: &str, msg_id: &str) -> Result<Option<Vec<u8>>> {
        self.inner.get_msg_secret(chat, sender, msg_id).await
    }
    async fn get_msg_secret_with_ts(&self, chat: &str, sender: &str, msg_id: &str) -> Result<Option<(Vec<u8>, i64)>> {
        self.inner.get_msg_secret_with_ts(chat, sender, msg_id).await
    }
    async fn delete_expired_msg_secrets(&self, cutoff_timestamp: i64) -> Result<u32> {
        self.inner.delete_expired_msg_secrets(cutoff_timestamp).await
    }
}

/// Single-threaded guest: the backend never crosses a thread.
unsafe impl Send for PersistentBackend {}
unsafe impl Sync for PersistentBackend {}

#[allow(dead_code)]
fn _assert_backend(b: PersistentBackend) -> Arc<dyn Backend> {
    Arc::new(b)
}
