//! One recognition as the 0.2 kernel hands it over: a segment `stream` plus one transcript
//! `future` (`wa:kernel@0.2/speech.recognize`).
//!
//! The guest does not poll: it awaits `steps` (segments mapped in, the transcript appended last)
//! and pushes every segment into a [`Tracker`], which is where the timings the pipeline reports
//! come from. Both are plain `futures`/`std` values with no host call and no wasm target
//! requirement, so a native test drives the same code with a **fake speech provider** and a fake
//! clock and measures the first-segment latency the real worker would produce
//! (`cargo test --lib`), while the wasm build only supplies the kernel types.
//!
//! Metadata only: the tracker keeps the text because the pipeline has to post it, and reports
//! counts/milliseconds; nothing here logs.

use futures::stream::{self, Stream, StreamExt};
use std::future::Future;
use std::pin::Pin;

/// One recognized segment, as the kernel's `speech.segment` carries it: the text and the audio
/// offsets (`start-ms`, `end-ms`) the recognizer reported for it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Segment {
    pub start_ms: u64,
    pub end_ms: u64,
    pub text: String,
}

/// The whole transcript, as the kernel's `speech.transcript` carries it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Transcript {
    pub text: String,
    pub language: String,
    /// Wall time the recognizer itself spent, milliseconds.
    pub elapsed_ms: u64,
}

/// What the pipeline sees while a recognition runs: one more segment, and exactly one [`End`].
#[derive(Debug)]
pub enum Step<E> {
    Segment(Segment),
    End(Result<Transcript, E>),
}

/// The two halves as one stream: every segment in order, then the transcript.
///
/// `select` (not `chain`): the transcript future can resolve before the last segment has been
/// read, and the loop must still see it. It ends when both halves have ended, which the kernel
/// guarantees after the job reaches its terminal state.
pub fn steps<S, F, E>(segments: S, transcript: F) -> impl Stream<Item = Step<E>>
where
    S: Stream<Item = Segment>,
    F: Future<Output = Result<Transcript, E>>,
{
    // Pinned once here: the kernel's `StreamReader` is not `Unpin`, and neither half has to be for
    // the caller - the returned stream is boxed by the loop that drives it.
    let segments = Box::pin(segments);
    let recognized = stream::unfold(segments, |mut segments: Pin<Box<S>>| async move {
        segments.as_mut().next().await.map(|segment| (Step::Segment(segment), segments))
    });
    let settled = stream::once(async move { Step::End(transcript.await) });
    stream::select(recognized, settled)
}

/// The streaming side of one recognition: the text recognized so far and the timings a comparison
/// run reads (first segment, whole recognition). Every duration is milliseconds since
/// [`Tracker::start`], which the pipeline sets to the moment it asked for the recognition, so the
/// first-segment latency includes everything between the request and the first text.
#[derive(Clone, Debug)]
pub struct Tracker {
    started_ms: u64,
    text: String,
    segments: u32,
    first_segment_ms: Option<u64>,
    total_ms: Option<u64>,
}

impl Tracker {
    pub fn start(started_ms: u64) -> Tracker {
        Tracker { started_ms, text: String::new(), segments: 0, first_segment_ms: None, total_ms: None }
    }

    /// Add one recognized segment. A segment that carries no text (the worker emits punctuation
    /// or blank windows) is not counted and does not start the clock; the answer says whether
    /// anything was added, so the pipeline only acts on real text.
    pub fn push(&mut self, segment: &Segment, now_ms: u64) -> bool {
        let text = segment.text.trim();
        if text.is_empty() {
            return false;
        }
        if self.first_segment_ms.is_none() {
            self.first_segment_ms = Some(now_ms.saturating_sub(self.started_ms));
        }
        self.segments += 1;
        if !self.text.is_empty() {
            self.text.push(' ');
        }
        self.text.push_str(text);
        true
    }

    /// The text recognized so far, joined the way the transcript joins it.
    pub fn so_far(&self) -> &str {
        &self.text
    }

    /// How many non-empty segments were recognized.
    pub fn segments(&self) -> u32 {
        self.segments
    }

    /// Milliseconds from `start` to the first non-empty segment (`None` if none arrived).
    pub fn first_segment_ms(&self) -> Option<u64> {
        self.first_segment_ms
    }

    /// Milliseconds from `start` to the transcript future resolving: the recognition's own total,
    /// which is not the whole pipeline's latency (the download and the post are outside it).
    pub fn total_ms(&self) -> Option<u64> {
        self.total_ms
    }

    /// The transcript future resolved at `now_ms`.
    pub fn finish(&mut self, now_ms: u64) {
        self.total_ms = Some(now_ms.saturating_sub(self.started_ms));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use futures::executor::block_on;
    use futures::stream::StreamExt;
    use std::cell::Cell;
    use std::pin::Pin;
    use std::rc::Rc;
    use std::task::{Context, Poll};

    /// The clock a fake provider moves; also how many segments it produced, so the fake transcript
    /// future can resolve only after them (as the real worker's final line does).
    #[derive(Clone)]
    struct FakeClock {
        now_ms: Rc<Cell<u64>>,
        produced: Rc<Cell<u32>>,
    }

    /// A fake speech provider's segment half: one segment per poll, the clock moving by the
    /// "decode time" each one cost. Deterministic: no sleeps, so no flaky latency assertions.
    struct FakeSegments {
        clock: FakeClock,
        delays: Vec<u64>,
        texts: Vec<&'static str>,
        next: usize,
    }

    impl Stream for FakeSegments {
        type Item = Segment;

        fn poll_next(mut self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<Option<Segment>> {
            let me = self.as_mut().get_mut();
            let Some(delay) = me.delays.get(me.next).copied() else {
                return Poll::Ready(None);
            };
            me.clock.now_ms.set(me.clock.now_ms.get() + delay);
            let at = me.clock.now_ms.get();
            let text = me.texts.get(me.next).copied().unwrap_or("x").to_string();
            me.next += 1;
            me.clock.produced.set(me.clock.produced.get() + 1);
            Poll::Ready(Some(Segment { start_ms: at.saturating_sub(delay), end_ms: at, text }))
        }
    }

    /// The fake provider's transcript half: pending (waking itself, so `block_on` keeps driving the
    /// segment stream) until the segments it names have been produced, then the whole transcript -
    /// or the worker's failure.
    struct FakeTranscript {
        clock: FakeClock,
        until: u32,
        extra_ms: u64,
        text: &'static str,
        failure: Option<&'static str>,
    }

    impl Future for FakeTranscript {
        type Output = Result<Transcript, String>;

        fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
            let me = self.get_mut();
            if me.clock.produced.get() < me.until {
                cx.waker().wake_by_ref();
                return Poll::Pending;
            }
            me.clock.now_ms.set(me.clock.now_ms.get() + me.extra_ms);
            Poll::Ready(match me.failure {
                Some(reason) => Err(reason.to_string()),
                None => Ok(Transcript { text: me.text.to_string(), language: "pt".into(), elapsed_ms: me.extra_ms }),
            })
        }
    }

    fn provider(now_ms: u64, delays: Vec<u64>, texts: Vec<&'static str>) -> (FakeClock, FakeSegments) {
        let clock = FakeClock { now_ms: Rc::new(Cell::new(now_ms)), produced: Rc::new(Cell::new(0)) };
        let segments = FakeSegments { clock: clock.clone(), delays, texts, next: 0 };
        (clock, segments)
    }

    #[test]
    fn a_fake_provider_measures_the_first_segment_latency() {
        // The recognizer starts at t=1000; the worker takes 250 ms to the first segment, 400 ms more
        // to the second, and reports the finished transcript 250 ms after that.
        let (clock, segments) = provider(1_000, vec![250, 400], vec!["olá", "mundo"]);
        let transcript = FakeTranscript { clock: clock.clone(), until: 2, extra_ms: 250, text: "olá mundo", failure: None };

        let mut tracker = Tracker::start(clock.now_ms.get());
        let mut steps = Box::pin(steps(segments, transcript));
        let mut seen = Vec::new();
        let mut ended = None;
        while let Some(step) = block_on(steps.next()) {
            match step {
                Step::Segment(segment) => {
                    if tracker.push(&segment, clock.now_ms.get()) {
                        seen.push(segment.text.clone());
                    }
                }
                Step::End(result) => {
                    tracker.finish(clock.now_ms.get());
                    ended = Some(result);
                    break;
                }
            }
        }

        assert_eq!(seen, vec!["olá", "mundo"], "segments arrive in order, text only");
        assert_eq!(tracker.so_far(), "olá mundo");
        assert_eq!(tracker.segments(), 2);
        assert_eq!(tracker.first_segment_ms(), Some(250), "first text 250 ms after recognize");
        assert_eq!(tracker.total_ms(), Some(900), "the recognition's own total (250 + 400 + 250)");
        assert_eq!(ended.unwrap().unwrap().text, "olá mundo", "the transcript is what gets posted");
    }

    #[test]
    fn a_blank_segment_does_not_start_the_clock() {
        let (clock, segments) = provider(0, vec![100, 0, 200], vec!["", "   ", "texto"]);
        let transcript = FakeTranscript { clock: clock.clone(), until: 3, extra_ms: 10, text: "texto", failure: None };
        let mut tracker = Tracker::start(clock.now_ms.get());
        let mut steps = Box::pin(steps(segments, transcript));
        let mut added = 0;
        while let Some(step) = block_on(steps.next()) {
            match step {
                Step::Segment(segment) => added += u32::from(tracker.push(&segment, clock.now_ms.get())),
                Step::End(_) => {
                    tracker.finish(clock.now_ms.get());
                    break;
                }
            }
        }
        assert_eq!(added, 1, "only the segment with text is added");
        assert_eq!(tracker.segments(), 1);
        assert_eq!(tracker.first_segment_ms(), Some(300), "the two blank windows do not count as a first segment");
        assert_eq!(tracker.so_far(), "texto");
    }

    #[test]
    fn a_failed_recognition_ends_the_stream_after_the_segments_it_had() {
        let (clock, segments) = provider(0, vec![120], vec!["primeiro"]);
        let transcript = FakeTranscript { clock: clock.clone(), until: 1, extra_ms: 60, text: "", failure: Some("worker_stalled") };
        let mut tracker = Tracker::start(clock.now_ms.get());
        let mut steps = Box::pin(steps(segments, transcript));
        let mut failure = None;
        while let Some(step) = block_on(steps.next()) {
            match step {
                Step::Segment(segment) => {
                    tracker.push(&segment, clock.now_ms.get());
                }
                Step::End(Err(reason)) => {
                    tracker.finish(clock.now_ms.get());
                    failure = Some(reason);
                    break;
                }
                Step::End(Ok(_)) => panic!("the provider failed"),
            }
        }
        assert_eq!(failure.as_deref(), Some("worker_stalled"));
        assert_eq!(tracker.so_far(), "primeiro", "the partial text survives a failure");
        assert_eq!(tracker.total_ms(), Some(180));
    }

    #[test]
    fn an_already_ready_transcript_loses_no_segment() {
        // The pathological order: the transcript future is ready on the first poll, while the
        // segment stream still has both segments queued. Whichever `select` answers first, neither
        // half may be dropped and the transcript resolves exactly once.
        let (_clock, segments) = provider(0, vec![10, 20], vec!["a", "b"]);
        let transcript = async move { Ok::<Transcript, String>(Transcript { text: "a b".into(), language: "pt".into(), elapsed_ms: 30 }) };
        let mut steps = Box::pin(steps(segments, transcript));
        let mut texts = Vec::new();
        let mut ends = 0;
        while let Some(step) = block_on(steps.next()) {
            match step {
                Step::Segment(segment) => texts.push(segment.text),
                Step::End(Ok(_)) => ends += 1,
                Step::End(Err(_)) => panic!("the provider succeeded"),
            }
        }
        assert_eq!(ends, 1, "the transcript resolves once");
        assert_eq!(texts, vec!["a", "b"], "no segment is lost to an early transcript");
    }
}
