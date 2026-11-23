# Transcription: the module each node runs, and how it is measured

Victor, 23/11: "our agent should have a module specialized for transcription per node. superwhisper is
the best?" This page answers with what was measured on 2026-11-23, on the nodes we have, and says
plainly what was not measured. The pipeline that *uses* the recognizer is
[WHATSAPP-TRANSCRIPTION.md](WHATSAPP-TRANSCRIPTION.md); the queue that lets one node decode for
another is [QUEUE.md](QUEUE.md) "Phase 2".

## 1. What the module is today, per node

| node | role | engine | model | language | memory | cold | warm | measured latency |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `openclaw` (OCI Ampere A1 Flex, 2 OCPU, 12 GB, arm64) | producer - owns the WhatsApp account and the `stt.requests` queue | `faster-whisper` 1.2.1, CPU `int8`, greedy (beam 1), VAD | `Systran/faster-whisper-small` multilingual, 462 MB on disk | `pt` (the component config's default, `language`) | worker RSS 515 MB, resident 3 h 30 min at the time of the reading | the recognizer is started with the service and never stopped (`WA_STT_IDLE_SECONDS=0`), so a note never pays the load | see the numbers below | ~30 s of decoding per minute of audio |
| `avell` (this laptop, 16 cores, x86_64) | master, **not** the producer | none provisioned | none | - | - | - | - | - |
| `work`, `nextcloud`, `mail` | masters/guests, not the producer | none provisioned | none | - | - | - | - | - |

`avell` cannot transcribe at all and says so: there is no `~/.local/wa-stt` venv, no model under
`~/.local/share/wa-stt/models`, the node log prints `[stt] worker idle: work=false producer=-
recognizer=false`, and `wa stt status` in a one-shot process prints `runtime:
not-configured-in-this-process`. Nothing depends on it today - it is not the producer - but it is the
node class the second half of this page is about: a node with no capable engine must route to one
that has it.

### The producer's own numbers (real voice notes, from its service log)

Four `wa-transcript v=1 kind=ready` lines survive in the retained log (it rotates; older notes went
with the older file). `recognize_ms` is the recognizer's own time, `since_sent_ms` the whole pipeline
from the moment the note was sent:

| audio | recognize | whole pipeline | chars | seconds per minute of audio |
| --- | --- | --- | --- | --- |
| 170 s | 73.8 s | 75.8 s | 2 334 | 26.0 |
| 22 s | 12.5 s | 13.9 s | 371 | 34.1 |
| 10 s | 7.4 s | 8.8 s | 174 | 44.4 |
| 2 s | 6.5 s | 8.2 s | 47 | (fixed cost dominates) |

So on a 2-OCPU arm64 VPS `small` decodes at roughly **0.45-0.55x real time**, plus about **6 s of
fixed cost** per note (download + worker round trip + index attach). A 22 s note is answered 13.9 s
after it was sent; a 170 s note needs 76 s, and that is inside the 5-minute freshness window.

## 2. The comparison

### What ran here, and what did not

| engine | runs here | measured |
| --- | --- | --- |
| `faster-whisper` (the current one) | yes, on `openclaw` | yes - the latency table above, on real notes |
| Superwhisper 1.3.1 (`superwhisper transcribe FILE`) | installed on this laptop | CLI behaviour measured (below); WER **not** measured |
| whisper.cpp | **not installed** on any node I can reach | no |
| `faster-whisper` `large-v3-turbo` | no (no model on disk anywhere reachable) | no |
| a Parakeet-class model | no | no |

**WER was not measured, and here is why**, in the order the obstacles appeared: this node has no
speech synthesiser (`espeak-ng` and `piper` are both absent, and `ffmpeg` here has no `flite` filter),
so a Portuguese/English test set cannot be generated without installing one; no scratch VPS or arm64
node was available in this session (the live nodes are read-only for this brief); and the repository
must not carry private audio. The harness below is the missing half - it needs two files, a clips
directory and an engines list, and it produces the table.

A synthetic 5-second tone was run through it to prove the path works end to end: `superwhisper`
answered `"No speech detected"` with an empty text, which the harness scored as WER 1.0, and a fixture
engine that echoed the reference scored 0.0. Peak RSS came back `null` because `/usr/bin/time` (GNU
time) is not installed on this laptop - `null` is "unknown", never a zero.

### Superwhisper: can it serve a node at all?

No, and this is measured rather than assumed:

* `superwhisper transcribe FILE` is an **IPC door to a running desktop app**. It returned
  `{"ok":true,"session_id":3}` in **13 ms** and put the file into a session; the text is read back
  afterwards with `superwhisper read`, which answered with the session's JSON (`text`, `audio_seconds`,
  `warning`). There is no mode that prints a transcript and exits.
* It needs the user's graphical session and its per-user preferences
  (`~/.config/superwhisper/preferences.json`), and it picks GPU backends from that session: the run
  here used `Vulkan1` on the laptop's RTX 4050 (`"asr_backend":"vulkan"`). A headless server has
  neither the session nor the GPU.
* Model state on this node: `transcription` = **Offline Lite** (installed, 485 MB, 25 European
  languages), `vocabulary` = a wav2vec2 pronouncer, and `cohere-transcription` (the
  higher-accuracy model) = **missing**. `license.state` is **unlicensed** with
  `credentials.source = free-tier`.
* It is proprietary, and the licence is per desktop install. Nothing about it is arm64-server or
  VPS-shaped, and its model set is not `large-v3-turbo`.

Superwhisper is a good *dictation* front end on this laptop. It is not a candidate for the node
module, and the "is it the best" question is the wrong one for a server: nothing about it is
addressable without a human at the machine.

### What the numbers already say about the current choice

`small` int8 on 2 OCPUs answers a 22 s note in 13.9 s. That is enough for short Portuguese voice
notes and not enough for a 3-minute one inside the 5-minute window on a busy node (170 s of audio
needed 76 s of decoding while other work was running). The two levers, in order of value per unit of
effort: `large-v3-turbo` (a much better model per unit of compute than `small` at the same speed
class, and unmeasured here) and a node with more cores decoding for the small one - which is the
queue that already exists.

## 3. The recommended module shape

One interface, an engine chosen per node, and a node without a capable engine routes to one that has
it. Nothing in this recommendation needs a new protocol: the queue already does the routing.

1. **One interface.** The recognizer seam is a WIT world (`wit/`, `wa:speech`):
   `recognize(audio, mime, language, segments) -> { text, segments, timings }`. Every engine below
   is implementable behind it; nothing above it may learn which one ran.
2. **The engine is configuration, chosen by what the node can run**, in this order:
   * a node with a GPU and a desktop session may use a desktop engine for *dictation*, but not for
     the pipeline (Superwhisper is out of scope for the node module, by the measurement above);
   * a node with >= 4 cores and >= 2 GB free: `faster-whisper large-v3-turbo` (int8 or float16 on a
     GPU), which is the accuracy the operator wants for Portuguese;
   * a small VPS or arm64 node: `faster-whisper small` int8 as today, or whisper.cpp with the same
     small model where a Python venv is not wanted (measured nowhere in this session - say so before
     choosing it);
   * a node with no engine: `WASM_AGENT_STT_ROLE=worker` pointed at the producer, or nothing at all.
3. **Routing is the queue's, not a new mechanism.** `stt.requests` + the signed worker envelope
   (`rust/wa-stt-remote`), the producer's preference policy (remote first when it is measurably
   faster, 3 s grace, then local) and the lease that makes a vanished worker cost a lease instead of
   a note. `docs/QUEUE.md` "Phase 2" has the table; this page adds no rule to it.
4. **A node says which module it has.** `wa stt status` already prints the role and the layer that
   said so; it does not yet name the engine or the model. That is the one field missing for "which
   module does each node run", and it is a two-line addition to that answer.

## 4. Running the harness

It is `scripts/measure-transcription.mjs`, a measurement tool and not a row: it is run by hand, from
the outside, against clips that are not in this repository.

```sh
# 1. the clips, outside the tree, with their reference text (this node has no TTS: record them, or
#    install espeak-ng/piper on the machine that makes them)
mkdir -p /tmp/clips && cp /path/to/pt-short-1.wav /tmp/clips/
cat > /tmp/clips/manifest.json <<'JSON'
[{"file":"pt-short-1.wav","language":"pt","reference":"a reuniao de amanha esta confirmada","seconds":4.2}]
JSON
# 2. the engines, as command lines
cat > /tmp/clips/engines.json <<'JSON'
[{"name":"faster-whisper-small","argv":["/home/ubuntu/.local/wa-stt/bin/python","scripts/whatsapp-stt-local.py","--file","{audio}"],"result":{"kind":"stdout"},"licence":"MIT","headless":true}]
JSON
# 3. measure
node scripts/measure-transcription.mjs --clips /tmp/clips --manifest /tmp/clips/manifest.json \
     --engines /tmp/clips/engines.json --out docs/measurements/transcription-$(date +%F).json
```

It reports, per engine: word error rate (token Levenshtein over folded, punctuation-free words),
seconds of decoding per minute of audio, peak RSS, and the engine's own words when it fails - a
missing model is a failed row, never a zero that reads like a perfect run.

## 5. What this page does not claim

* No WER for any engine, because no engine was measured on speech in this session.
* No whisper.cpp, Parakeet or `large-v3-turbo` number, and no arm64-versus-x86 comparison.
* No cost figure beyond the nodes' own shape (the producer is one OCPU-hour per ~2 hours of audio at
  the measured rate, on a VPS that is already paid for).
* Superwhisper's accuracy is unmeasured here: on this node its higher-accuracy model is not even
  installed.
