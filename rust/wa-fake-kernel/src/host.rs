//! The `wa:kernel@0.2` host functions, answered from memory.
//!
//! Every call goes through [`exchange`], which is also where record and replay live: the fake
//! kernel answers, writes the answer into the ring when recording, and reads it from the file when
//! replaying - the same door for both, so a step can never be recorded and not replayable.
//!
//! Grants are the node's, checked at the same points: `net` covers every dial (http and websocket),
//! `storage` gates kv, `stt` gates the recognizer, and a key or a secret the test did not set is a
//! refusal, never an empty value.

use crate::{wa, Answer, Call, FakeKernel, Kernel, LogLine, RecognitionScript, RunOutcome, ServiceComponent, State};
use serde_json::{json, Value};
use std::collections::VecDeque;
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll};
use wasmtime::component::{
    Access, Accessor, Component, Destination, FutureProducer, FutureReader, Resource, StreamProducer, StreamReader, StreamResult,
};
use wasmtime::{AsContextMut, StoreContextMut};

use wa::kernel::types::Error as KError;

/// `list<u8>` on the wire: hex, so a record stays one compact line and no encoding can be ambiguous.
fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

/// The inverse. A malformed hex string is an error with a name, never a silent empty list.
fn unhex(text: &str) -> Result<Vec<u8>, String> {
    if !text.len().is_multiple_of(2) {
        return Err("odd_hex".into());
    }
    let mut out = Vec::with_capacity(text.len() / 2);
    let bytes = text.as_bytes();
    for pair in bytes.chunks(2) {
        let s = std::str::from_utf8(pair).map_err(|_| "hex_not_utf8".to_string())?;
        out.push(u8::from_str_radix(s, 16).map_err(|_| format!("bad_hex:{s}"))?);
    }
    Ok(out)
}

fn hexes(values: &[Vec<u8>]) -> Vec<String> {
    values.iter().map(|value| hex(value)).collect()
}

/// Answer one host call: replay it when replaying, run the script when not, and write it down when
/// recording. The call log gets every answered call either way.
fn exchange<F: FnOnce(&mut Kernel) -> Answer>(kernel: &Arc<Mutex<Kernel>>, interface: &str, function: &str, args: Value, scripted: F) -> Answer {
    let Ok(mut state) = kernel.lock() else { return Answer::Err("kernel_poisoned".into()) };
    let answer = match state.journal.ask(interface, function, &args) {
        Some(replayed) => replayed,
        None => scripted(&mut state),
    };
    let call = Call { interface: interface.to_string(), function: function.to_string(), args: args.to_string(), answer: answer.encode() };
    state.journal.note(&call, &args, &answer);
    state.calls.push(call);
    answer
}

/// A call whose answer is the component's own writing - a log line, a health report. It is run and
/// put in the call log, but never in the ring: there is nothing to feed back (a replay re-runs the
/// component, so those lines happen again), and its text names the run, not the host's answer.
fn output_call<F: FnOnce(&mut Kernel)>(kernel: &Arc<Mutex<Kernel>>, interface: &str, function: &str, args: Value, act: F) {
    let Ok(mut state) = kernel.lock() else { return };
    act(&mut state);
    state.calls.push(Call { interface: interface.to_string(), function: function.to_string(), args: args.to_string(), answer: "ok:null".into() });
}

/// A live signal: answered from the kernel as it is *now*, logged, never recorded. `stopping` is the
/// one: how many times a component asks depends on wall time, so a recorded count could not be
/// replayed, and the true answer (what the caller asked for a moment ago) is the one that matters -
/// a replayed component that is told to stop must stop.
fn live_call(kernel: &Arc<Mutex<Kernel>>, interface: &str, function: &str, args: Value, act: impl FnOnce(&Kernel) -> Answer) -> Answer {
    let Ok(mut state) = kernel.lock() else { return Answer::Err("kernel_poisoned".into()) };
    let answer = act(&state);
    state.calls.push(Call { interface: interface.to_string(), function: function.to_string(), args: args.to_string(), answer: answer.encode() });
    answer
}

/// `Answer` → the kernel's error: a refusal stays a refusal, everything else is `failed`.
fn failed(answer: Answer) -> KError {
    match answer {
        Answer::Err(reason) if reason.starts_with("replay_") => KError::Failed(reason),
        Answer::Err(reason) if reason == "storage not declared" || reason == "stt not declared" => KError::Refused(reason),
        Answer::Err(reason) => KError::Failed(reason),
        Answer::Ok(_) => KError::Failed("kernel_answer_was_ok".into()),
    }
}

fn ok_value(answer: Answer) -> Result<Value, KError> {
    match answer {
        Answer::Ok(value) => Ok(value),
        Answer::Err(reason) => Err(failed(Answer::Err(reason))),
    }
}

/// A refused address keeps the node's shape: `refused(<the url it was asked for>)`.
fn refused(url: &str) -> KError {
    KError::Refused(url.to_string())
}

// ---- resources the kernel hands out ------------------------------------------------------------

/// A scripted socket. Inbound frames are a queue the stream drains; `echo` puts every sent frame
/// back on it (a peer that answers), and `sent` is what the component actually sent.
pub struct Socket {
    inbound: VecDeque<Vec<u8>>,
    echo: bool,
    sent: Vec<Vec<u8>>,
    closed: bool,
}

/// A scripted http response, whose body the guest drains as a stream.
pub struct Response {
    status: u16,
    headers: Vec<(String, String)>,
    body: Option<Vec<u8>>,
}

/// A scripted recognition: the segments to stream and the transcript to resolve.
pub struct Recognition {
    script: RecognitionScript,
}

impl wa::kernel::types::Host for State {}

impl wa::kernel::kv::Host for State {}

impl wa::kernel::kv::HostWithStore<State> for State {
    async fn get(accessor: &Accessor<State, Self>, key: Vec<u8>) -> Result<Option<Vec<u8>>, KError> {
        let kernel = accessor.with(|mut access| access.get().kernel.clone());
        let answer = exchange(&kernel, "wa:kernel/kv", "get", json!({"key": hex(&key)}), |state| {
            if !state.storage {
                return Answer::Err("storage not declared".into());
            }
            Answer::Ok(match state.kv.get(&key) {
                Some(value) => json!(hex(value)),
                None => Value::Null,
            })
        });
        match ok_value(answer)? {
            Value::Null => Ok(None),
            Value::String(text) => unhex(&text).map(Some).map_err(KError::Failed),
            other => Err(KError::Failed(format!("replay_answer_not_bytes:{other}"))),
        }
    }

    async fn set(accessor: &Accessor<State, Self>, key: Vec<u8>, value: Vec<u8>) -> Result<(), KError> {
        let kernel = accessor.with(|mut access| access.get().kernel.clone());
        let answer = exchange(&kernel, "wa:kernel/kv", "set", json!({"key": hex(&key), "value": hex(&value)}), |state| {
            if !state.storage {
                return Answer::Err("storage not declared".into());
            }
            state.kv.insert(key.clone(), value.clone());
            Answer::Ok(json!(null))
        });
        ok_value(answer).map(|_| ())
    }

    async fn delete(accessor: &Accessor<State, Self>, key: Vec<u8>) -> Result<(), KError> {
        let kernel = accessor.with(|mut access| access.get().kernel.clone());
        let answer = exchange(&kernel, "wa:kernel/kv", "delete", json!({"key": hex(&key)}), |state| {
            if !state.storage {
                return Answer::Err("storage not declared".into());
            }
            state.kv.remove(&key);
            Answer::Ok(json!(null))
        });
        ok_value(answer).map(|_| ())
    }

    async fn delete_prefix(accessor: &Accessor<State, Self>, prefix: Vec<u8>) -> Result<u32, KError> {
        let kernel = accessor.with(|mut access| access.get().kernel.clone());
        let answer = exchange(&kernel, "wa:kernel/kv", "delete_prefix", json!({"prefix": hex(&prefix)}), |state| {
            if !state.storage {
                return Answer::Err("storage not declared".into());
            }
            let doomed: Vec<Vec<u8>> = state.kv.keys().filter(|key| key.starts_with(&prefix)).cloned().collect();
            let count = doomed.len();
            for key in doomed {
                state.kv.remove(&key);
            }
            Answer::Ok(json!(count))
        });
        match ok_value(answer)? {
            Value::Number(count) => Ok(count.as_u64().unwrap_or(0) as u32),
            other => Err(KError::Failed(format!("replay_answer_not_a_count:{other}"))),
        }
    }

    async fn scan(accessor: &Accessor<State, Self>, prefix: Vec<u8>, cursor: Option<Vec<u8>>, limit: u32) -> Result<Vec<wa::kernel::kv::Entry>, KError> {
        let kernel = accessor.with(|mut access| access.get().kernel.clone());
        let args = json!({"prefix": hex(&prefix), "cursor": cursor.clone().map(|c| hex(&c)), "limit": limit});
        let answer = exchange(&kernel, "wa:kernel/kv", "scan", args, |state| {
            if !state.storage {
                return Answer::Err("storage not declared".into());
            }
            let page: Vec<Value> = state
                .kv
                .range(prefix.clone()..)
                .take_while(|(key, _)| key.starts_with(&prefix))
                .filter(|(key, _)| cursor.as_ref().map(|after| key.as_slice() > after.as_slice()).unwrap_or(true))
                .take(limit as usize)
                .map(|(key, value)| json!({"key": hex(key), "value": hex(value)}))
                .collect();
            Answer::Ok(Value::Array(page))
        });
        let Value::Array(page) = ok_value(answer)? else { return Err(KError::Failed("replay_answer_not_a_page".into())) };
        page.into_iter()
            .map(|entry| {
                let key = entry["key"].as_str().ok_or_else(|| KError::Failed("replay_entry_without_key".into()))?;
                let value = entry["value"].as_str().ok_or_else(|| KError::Failed("replay_entry_without_value".into()))?;
                Ok(wa::kernel::kv::Entry { key: unhex(key).map_err(KError::Failed)?, value: unhex(value).map_err(KError::Failed)? })
            })
            .collect()
    }
}

impl wa::kernel::lifecycle::Host for State {
    fn stopping(&mut self) -> bool {
        let kernel = self.kernel.clone();
        let answer = live_call(&kernel, "wa:kernel/lifecycle", "stopping", json!(null), |state| Answer::Ok(json!(state.stopping)));
        matches!(answer, Answer::Ok(Value::Bool(true)))
    }

    fn report(&mut self, state: wa::kernel::lifecycle::Health, detail: Option<String>) {
        let health = match state {
            wa::kernel::lifecycle::Health::Starting => "starting",
            wa::kernel::lifecycle::Health::Ready => "ready",
            wa::kernel::lifecycle::Health::Degraded => "degraded",
        };
        let kernel = self.kernel.clone();
        let args = json!({"state": health, "detail": detail});
        output_call(&kernel, "wa:kernel/lifecycle", "report", args, |state| {
            state.health = format!("{health}{}", detail.as_ref().map(|d| format!(": {d}")).unwrap_or_default());
        });
    }
}

impl wa::kernel::log::Host for State {
    fn write(&mut self, level: wa::kernel::log::Level, target: String, message: String) {
        let level = match level {
            wa::kernel::log::Level::Trace => "trace",
            wa::kernel::log::Level::Debug => "debug",
            wa::kernel::log::Level::Info => "info",
            wa::kernel::log::Level::Warn => "warn",
            wa::kernel::log::Level::Error => "error",
        }
        .to_string();
        let kernel = self.kernel.clone();
        let args = json!({"level": level, "target": target, "message": message});
        output_call(&kernel, "wa:kernel/log", "write", args, |state| {
            state.logs.push(LogLine { level: level.clone(), target: target.clone(), message: message.clone() });
        });
    }
}

impl wa::kernel::credentials::Host for State {
    /// A secret's **value never enters a record** (`docs/REPLAY.md`'s rule, and this crate's): the
    /// step records only whether the name was granted. A replay therefore hands the component the
    /// stand-in `replayed-secret` instead of the real value - what a replayed component can still
    /// prove is that it asked for the right name at the right time.
    fn get(&mut self, name: String) -> Result<String, KError> {
        let kernel = self.kernel.clone();
        let (present, replaying, secret) = match kernel.lock() {
            Ok(state) => (state.secrets.contains_key(&name), state.journal.is_replaying(), state.secrets.get(&name).cloned()),
            Err(_) => return Err(KError::Failed("kernel_poisoned".into())),
        };
        let asked = name.clone();
        let answer = exchange(&kernel, "wa:kernel/credentials", "get", json!({"name": asked}), move |_state| Answer::Ok(json!({"present": present})));
        match answer {
            Answer::Ok(answer) if answer["present"].as_bool() == Some(true) => {
                if replaying {
                    Ok("replayed-secret".into())
                } else {
                    // The value is read from the live kernel, never from the record.
                    secret.ok_or(KError::Refused(name))
                }
            }
            Answer::Ok(_) => Err(KError::Refused(name)),
            Answer::Err(reason) => Err(failed(Answer::Err(reason))),
        }
    }
}

// ---- websocket ---------------------------------------------------------------------------------

impl wa::kernel::websocket::Host for State {}

impl wa::kernel::websocket::HostSocket for State {
    fn close(&mut self, socket: Resource<Socket>, _code: u16, _reason: String) {
        let kernel = self.kernel.clone();
        exchange(&kernel, "wa:kernel/websocket", "close", json!(null), move |_state| Answer::Ok(json!(null)));
        if let Ok(socket) = self.table.get_mut(&socket) {
            socket.closed = true;
            socket.inbound.clear();
        }
    }

    fn drop(&mut self, socket: Resource<Socket>) -> wasmtime::Result<()> {
        self.table.delete(socket)?;
        Ok(())
    }
}

impl wa::kernel::websocket::HostSocketWithStore<State> for State {
    async fn send(accessor: &Accessor<State, Self>, socket: Resource<Socket>, frame: Vec<u8>) -> Result<(), KError> {
        let kernel = accessor.with(|mut access| access.get().kernel.clone());
        let state = accessor.with(|mut access| {
            let state = access.get();
            match state.table.get_mut(&socket) {
                Ok(socket) if !socket.closed => {
                    socket.sent.push(frame.clone());
                    if socket.echo {
                        socket.inbound.push_back(frame.clone());
                    }
                    Some(())
                }
                _ => None,
            }
        });
        let answer = exchange(&kernel, "wa:kernel/websocket", "send", json!({"frame": hex(&frame)}), move |_state| match state {
            Some(()) => Answer::Ok(json!(null)),
            None => Answer::Err("closed".into()),
        });
        match answer {
            Answer::Ok(_) => Ok(()),
            Answer::Err(reason) if reason == "closed" => Err(KError::Closed),
            Answer::Err(reason) => Err(failed(Answer::Err(reason))),
        }
    }

    async fn connect(accessor: &Accessor<State, Self>, url: String, origin: Option<String>) -> Result<Resource<Socket>, KError> {
        let kernel = accessor.with(|mut access| access.get().kernel.clone());
        let answer = exchange(&kernel, "wa:kernel/websocket", "connect", json!({"url": url, "origin": origin}), |state| {
            let Some(authority) = crate::scripts::url_authority(&url) else { return Answer::Err(format!("refused:{url}")) };
            if !crate::scripts::dial_allowed(&state.net, &authority) {
                return Answer::Err(format!("refused:{url}"));
            }
            match state.ws.iter().find(|rule| rule.url == url) {
                Some(rule) => Answer::Ok(json!({
                    "url": rule.url,
                    "inbound": hexes(&rule.inbound),
                    "echo": rule.echo,
                })),
                None => Answer::Err(format!("websocket_not_scripted:{url}")),
            }
        });
        let value = match answer {
            Answer::Ok(value) => value,
            Answer::Err(reason) => match reason.strip_prefix("refused:") {
                Some(url) => return Err(refused(url)),
                None => return Err(failed(Answer::Err(reason))),
            },
        };
        let _ = value["url"].as_str();
        let socket = Socket {
            inbound: value["inbound"].as_array().into_iter().flatten().filter_map(|frame| frame.as_str().and_then(|text| unhex(text).ok())).collect(),
            echo: value["echo"].as_bool().unwrap_or(false),
            sent: Vec::new(),
            closed: false,
        };
        accessor.with(|mut access| access.get().table.push(socket).map_err(|error| KError::Failed(error.to_string())))
    }

    fn messages(mut access: Access<State, Self>, socket: Resource<Socket>) -> wasmtime::Result<StreamReader<Vec<u8>>> {
        StreamReader::new(access.as_context_mut(), FrameProducer { socket })
    }
}

/// The inbound frames: each poll delivers one, and an empty queue ends the stream (the peer closed).
struct FrameProducer {
    socket: Resource<Socket>,
}

impl StreamProducer<State> for FrameProducer {
    type Item = Vec<u8>;
    type Buffer = Option<Vec<u8>>;

    fn poll_produce<'a>(
        self: Pin<&mut Self>,
        _cx: &mut Context<'_>,
        mut store: StoreContextMut<'a, State>,
        mut dst: Destination<'a, Self::Item, Self::Buffer>,
        _finish: bool,
    ) -> Poll<wasmtime::Result<StreamResult>> {
        let frame = store.data_mut().table.get_mut(&self.socket).ok().and_then(|socket| socket.inbound.pop_front());
        match frame {
            Some(frame) => {
                dst.set_buffer(Some(frame));
                Poll::Ready(Ok(StreamResult::Completed))
            }
            None => Poll::Ready(Ok(StreamResult::Dropped)),
        }
    }
}

// ---- http --------------------------------------------------------------------------------------

impl wa::kernel::http::Host for State {}

impl wa::kernel::http::HostResponse for State {
    fn status(&mut self, response: Resource<Response>) -> u16 {
        self.table.get(&response).map(|response| response.status).unwrap_or(0)
    }
    fn headers(&mut self, response: Resource<Response>) -> Vec<(String, String)> {
        self.table.get(&response).map(|response| response.headers.clone()).unwrap_or_default()
    }
    fn drop(&mut self, response: Resource<Response>) -> wasmtime::Result<()> {
        self.table.delete(response)?;
        Ok(())
    }
}

impl wa::kernel::http::HostResponseWithStore<State> for State {
    fn body(mut access: Access<State, Self>, response: Resource<Response>) -> wasmtime::Result<StreamReader<Vec<u8>>> {
        let body = access.data_mut().table.get_mut(&response).ok().and_then(|response| response.body.take()).unwrap_or_default();
        let chunks: Vec<Vec<u8>> = body.chunks(64 << 10).map(|chunk| chunk.to_vec()).collect();
        StreamReader::new(access.as_context_mut(), BodyProducer { chunks: chunks.into_iter() })
    }
}

struct BodyProducer {
    chunks: std::vec::IntoIter<Vec<u8>>,
}

impl StreamProducer<State> for BodyProducer {
    type Item = Vec<u8>;
    type Buffer = Option<Vec<u8>>;

    fn poll_produce<'a>(
        self: Pin<&mut Self>,
        _cx: &mut Context<'_>,
        _store: StoreContextMut<'a, State>,
        mut dst: Destination<'a, Self::Item, Self::Buffer>,
        _finish: bool,
    ) -> Poll<wasmtime::Result<StreamResult>> {
        match self.get_mut().chunks.next() {
            Some(chunk) => {
                dst.set_buffer(Some(chunk));
                Poll::Ready(Ok(StreamResult::Completed))
            }
            None => Poll::Ready(Ok(StreamResult::Dropped)),
        }
    }
}

impl wa::kernel::http::HostWithStore<State> for State {
    async fn send(accessor: &Accessor<State, Self>, request: wa::kernel::http::Request) -> Result<Resource<Response>, KError> {
        let kernel = accessor.with(|mut access| access.get().kernel.clone());
        let method = request.method.clone();
        let url = request.url.clone();
        let headers = request.headers.clone();
        let body = request.body.clone();
        let answer = exchange(
            &kernel,
            "wa:kernel/http",
            "send",
            json!({"method": method, "url": url, "headers": headers, "body": hex(&body)}),
            |state| {
                let Some(authority) = crate::scripts::url_authority(&url) else { return Answer::Err(format!("refused:{url}")) };
                if !crate::scripts::dial_allowed(&state.net, &authority) {
                    return Answer::Err(format!("refused:{url}"));
                }
                match state.http.iter().find(|rule| rule.matches(&method, &url)) {
                    Some(rule) => Answer::Ok(json!({"status": rule.status, "headers": rule.headers, "body": hex(&rule.body)})),
                    None => Answer::Err(format!("http_not_scripted:{method} {url}")),
                }
            },
        );
        let value = match answer {
            Answer::Ok(value) => value,
            Answer::Err(reason) => match reason.strip_prefix("refused:") {
                Some(url) => return Err(refused(url)),
                None => return Err(failed(Answer::Err(reason))),
            },
        };
        let response = Response {
            status: value["status"].as_u64().unwrap_or(0) as u16,
            headers: value["headers"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(|pair| Some((pair[0].as_str()?.to_string(), pair[1].as_str()?.to_string())))
                .collect(),
            body: Some(value["body"].as_str().and_then(|text| unhex(text).ok()).unwrap_or_default()),
        };
        accessor.with(|mut access| access.get().table.push(response).map_err(|error| KError::Failed(error.to_string())))
    }
}

// ---- speech ------------------------------------------------------------------------------------

impl wa::kernel::speech::Host for State {}

impl wa::kernel::speech::HostRecognition for State {
    fn drop(&mut self, recognition: Resource<Recognition>) -> wasmtime::Result<()> {
        self.table.delete(recognition)?;
        Ok(())
    }
}

impl wa::kernel::speech::HostWithStore<State> for State {
    async fn recognize(accessor: &Accessor<State, Self>, audio: Vec<u8>, mime: String, language: String) -> Result<Resource<Recognition>, KError> {
        let kernel = accessor.with(|mut access| access.get().kernel.clone());
        let answer = exchange(&kernel, "wa:kernel/speech", "recognize", json!({"mime": mime, "language": language, "audio_bytes": audio.len()}), |state| {
            if !state.stt {
                return Answer::Err("stt not declared".into());
            }
            match &state.speech {
                Some(script) => Answer::Ok(script.to_json()),
                None => Answer::Err("speech_not_scripted".into()),
            }
        });
        let value = ok_value(answer)?;
        let script = RecognitionScript::from_json(&value);
        accessor.with(|mut access| access.get().table.push(Recognition { script }).map_err(|error| KError::Failed(error.to_string())))
    }
}

impl wa::kernel::speech::HostRecognitionWithStore<State> for State {
    fn segments(mut access: Access<State, Self>, recognition: Resource<Recognition>) -> wasmtime::Result<StreamReader<wa::kernel::speech::Segment>> {
        let script = access.data_mut().table.get_mut(&recognition).map(|recognition| recognition.script.clone()).unwrap_or_default();
        StreamReader::new(access.as_context_mut(), SegmentProducer { segments: script.segments.into_iter().collect(), failed: script.error.is_some() })
    }

    fn transcript(mut access: Access<State, Self>, recognition: Resource<Recognition>) -> wasmtime::Result<FutureReader<Result<wa::kernel::speech::Transcript, KError>>> {
        let script = access.data_mut().table.get_mut(&recognition).map(|recognition| recognition.script.clone()).unwrap_or_default();
        FutureReader::new(access.as_context_mut(), TranscriptFuture { script, answered: false })
    }
}

struct SegmentProducer {
    segments: VecDeque<(u64, u64, String)>,
    failed: bool,
}

impl StreamProducer<State> for SegmentProducer {
    type Item = wa::kernel::speech::Segment;
    type Buffer = Option<wa::kernel::speech::Segment>;

    fn poll_produce<'a>(
        self: Pin<&mut Self>,
        _cx: &mut Context<'_>,
        _store: StoreContextMut<'a, State>,
        mut dst: Destination<'a, Self::Item, Self::Buffer>,
        _finish: bool,
    ) -> Poll<wasmtime::Result<StreamResult>> {
        let me = self.get_mut();
        if me.failed {
            return Poll::Ready(Ok(StreamResult::Dropped));
        }
        match me.segments.pop_front() {
            Some((start_ms, end_ms, text)) => {
                dst.set_buffer(Some(wa::kernel::speech::Segment { start_ms, end_ms, text }));
                Poll::Ready(Ok(if me.segments.is_empty() { StreamResult::Dropped } else { StreamResult::Completed }))
            }
            None => Poll::Ready(Ok(StreamResult::Dropped)),
        }
    }
}

struct TranscriptFuture {
    script: RecognitionScript,
    answered: bool,
}

impl FutureProducer<State> for TranscriptFuture {
    type Item = Result<wa::kernel::speech::Transcript, KError>;

    fn poll_produce(
        self: Pin<&mut Self>,
        _cx: &mut Context<'_>,
        _store: StoreContextMut<State>,
        _finish: bool,
    ) -> Poll<wasmtime::Result<Option<Self::Item>>> {
        let me = self.get_mut();
        if me.answered {
            return Poll::Ready(Ok(None));
        }
        me.answered = true;
        let answer = match &me.script.error {
            Some(reason) => Err(KError::Failed(reason.clone())),
            None => Ok(wa::kernel::speech::Transcript {
                text: me.script.text.clone(),
                language: me.script.language.clone(),
                elapsed_ms: me.script.elapsed_ms,
            }),
        };
        Poll::Ready(Ok(Some(answer)))
    }
}

// ---- the run itself ----------------------------------------------------------------------------

/// Compile once per process per artifact: a fixture is megabytes of debug wasm, and a test suite
/// runs the same build many times. Keyed by a hash of the bytes, which is what `is_component`-style
/// identity means here - there is no pin in a fake kernel.
fn compiled(engine: &wasmtime::Engine, wasm: &[u8]) -> Result<Component, String> {
    use std::hash::{Hash, Hasher};
    static CACHE: std::sync::OnceLock<Mutex<std::collections::HashMap<u64, Component>>> = std::sync::OnceLock::new();
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    wasm.hash(&mut hasher);
    let key = hasher.finish();
    let cache = CACHE.get_or_init(|| Mutex::new(std::collections::HashMap::new()));
    if let Some(found) = cache.lock().ok().and_then(|cache| cache.get(&key).cloned()) {
        return Ok(found);
    }
    let component = Component::new(engine, wasm).map_err(|error| format!("compile_failed:{error}"))?;
    if let Ok(mut cache) = cache.lock() {
        cache.insert(key, component.clone());
    }
    Ok(component)
}

/// Run one component: compile, link, instantiate, call `service.run(config)` and collect what is
/// left. The deadline is enforced twice - the tokio timer drops a parked guest, the epoch traps a
/// guest that never yields - because a component can fail to end in either way.
pub(crate) fn run(fake: &FakeKernel, wasm: &[u8], config: &str) -> RunOutcome {
    let deadline = fake.deadline;
    let deadline_ticks = (deadline.as_millis() / 100).max(1) as u64 + 1;
    let engine = match crate::engine() {
        Ok(engine) => engine,
        Err(error) => return RunOutcome { outcome: error, ..RunOutcome::default() },
    };
    let component = match compiled(&engine, wasm) {
        Ok(component) => component,
        Err(error) => return RunOutcome { outcome: error, ..RunOutcome::default() },
    };
    let linker = match crate::linker(&engine) {
        Ok(linker) => linker,
        Err(error) => return RunOutcome { outcome: error, ..RunOutcome::default() },
    };
    let kernel = fake.kernel.clone();
    let (mut store, stdout, stderr) = crate::store(kernel.clone(), &fake.env, fake.config_env.then_some(config), fake.memory_mb);
    store.set_epoch_deadline(deadline_ticks);
    let runtime = match tokio::runtime::Builder::new_current_thread().enable_time().build() {
        Ok(runtime) => runtime,
        Err(error) => return RunOutcome { outcome: format!("runtime_failed:{error}"), ..RunOutcome::default() },
    };
    let outcome = runtime.block_on(async {
        let bindings = match ServiceComponent::instantiate_async(&mut store, &component, &linker).await {
            Ok(bindings) => bindings,
            Err(error) => return Err(("instantiate_failed", error)),
        };
        let config = config.to_string();
        let guest = store.run_concurrent(async move |store| bindings.wa_kernel_service().call_run(store, config).await);
        match tokio::time::timeout(deadline, guest).await {
            Ok(Ok(Ok(Ok(())))) => Ok("exit_0".to_string()),
            Ok(Ok(Ok(Err(reason)))) => Ok(format!("service_error:{reason}")),
            Ok(Ok(Err(error))) | Ok(Err(error)) => {
                if let Some(exit) = error.downcast_ref::<wasmtime_wasi::I32Exit>() {
                    return Ok(format!("exit_{}", exit.0));
                }
                Err(("call_failed", error))
            }
            Err(_elapsed) => Ok("deadline".to_string()),
        }
    });
    let outcome = match outcome {
        Ok(outcome) => outcome,
        Err((kind, error)) => format!("{kind}:{}", error.root_cause()),
    };
    let stopping = kernel.lock().map(|state| state.stopping).unwrap_or(false);
    let mut run = RunOutcome { outcome: if outcome == "deadline" && stopping { "stopped".into() } else { outcome }, ..RunOutcome::default() };
    if let Ok(state) = kernel.lock() {
        run.health = state.health.clone();
        run.logs = state.logs.clone();
        run.calls = state.calls.clone();
        run.kv = state.kv.clone();
        run.records = state.journal.records();
        run.replay_mismatch = state.journal.mismatch().map(str::to_string);
    }
    run.stdout = String::from_utf8_lossy(&stdout.contents()).into_owned();
    run.stderr = String::from_utf8_lossy(&stderr.contents()).into_owned();
    run
}

