//! The fabric's tests: the three scenarios the brief names (placement, a node killed mid-job, every
//! peer gone), the flag-off path, the wire's refusals, and the placement latency distribution.
//!
//! Every scenario runs on the real records and the real `wa-queue` lease; only the relay hop is a
//! function call, so a test can move the clock by hand and assert an exact millisecond number
//! (`docs/FABRIC.md`, "Tests").

use std::collections::BTreeMap;
use std::time::Instant;

use serde_json::json;
use wa_queue::{JobId, JobState};

use crate::lease::{queue_name, worker_id, FabricLease, LeaseError};
use crate::metrics::RecordOutcome;
use crate::offer::{self, Accept, Offer, Refuse, Reply, Step};
use crate::placement::{self, LocalReason, Plan, Request};
use crate::presence::{Capabilities, Heartbeat, Load, NodeId, PresenceView};
use crate::sim::{SimFabric, Via};
use crate::Config;

fn fabric(ids: &[&str], caps: &[&str]) -> SimFabric {
    let mut sim = SimFabric::new(Config::default(), ids, caps);
    sim.beat();
    sim
}

fn node(id: &str) -> NodeId {
    NodeId::new(id).expect("valid id")
}

// ---------------------------------------------------------------- presence -------------------------------------------------

#[test]
fn a_peer_is_stale_after_three_missed_beats_and_live_again_on_the_next_one() {
    let config = Config::default();
    let mut view = PresenceView::new(&config);
    assert_eq!(view.stale_after_ms(), 3 * config.heartbeat_ms);
    assert_eq!(view.stale_after_ms(), 9_000);

    let beat = || Heartbeat::new("peer", ["stt"], Load::new(0, 5, 20), "0.1.0", 0);
    let first = view.observe(beat(), 1_000);
    assert!(first.new && !first.resurrected);
    assert!(view.is_live("peer", 9_000));
    assert_eq!(view.missed_beats("peer", 9_000), 2);
    assert!(!view.is_live("peer", 10_001), "three beats missed is stale");

    let back = view.observe(beat(), 10_500);
    assert!(back.resurrected, "a peer that comes back is live on the same beat");
    assert!(view.is_live("peer", 10_500));
    assert_eq!(view.live(10_500).len(), 1);

    // A sample nobody has heard from for four TTLs is forgotten, so a fleet that changes all day
    // cannot grow the map without bound.
    assert_eq!(view.prune(10_500 + view.forget_after_ms() + 1), 1);
    assert!(view.is_empty());
}

#[test]
fn a_heartbeat_round_trips_and_refuses_an_unknown_field() {
    let beat = Heartbeat::new("n1", ["stt", "ocr"], Load::new(3, 40, 55), "1.2.3", 42);
    let decoded = Heartbeat::decode(&beat.encode()).expect("decodes");
    assert_eq!(decoded, beat);

    let mut value: serde_json::Value = serde_json::from_slice(&beat.encode()).unwrap();
    value["surprise"] = json!(1);
    assert_eq!(Heartbeat::decode(value.to_string().as_bytes()), Err(crate::wire::Refusal::Malformed("unknown_field")));

    let mut version: serde_json::Value = serde_json::from_slice(&beat.encode()).unwrap();
    version["v"] = json!(99);
    assert_eq!(Heartbeat::decode(version.to_string().as_bytes()), Err(crate::wire::Refusal::Version(99)));

    let long = Heartbeat::new("n1", ["stt"], Load::new(0, 0, 0), "v", 0);
    let mut oversized: serde_json::Value = serde_json::from_slice(&long.encode()).unwrap();
    oversized["node"] = json!("x".repeat(200));
    assert!(matches!(Heartbeat::decode(oversized.to_string().as_bytes()), Err(crate::wire::Refusal::TooLarge("node"))));
}

// ---------------------------------------------------------------- placement ------------------------------------------------

#[test]
fn placement_picks_the_idle_capable_node_and_says_why() {
    let mut sim = fabric(&["small", "big", "noservice"], &["stt"]);
    // `big` is the 16-thread box with nothing queued; `noservice` does not serve speech at all.
    sim.node_mut(1).caps = Capabilities::of(["stt", "ocr"]);
    sim.node_mut(2).caps = Capabilities::of(["ocr"]);
    sim.set_load(0, 60, 50); // `small` is this node and it is busy
    sim.set_load(1, 3, 20);
    sim.beat();

    let submitted = sim.submit(0, "stt", b"audio").expect("placed");
    let decision = &submitted.decision;
    match &decision.plan {
        Plan::Offer { to, window_ms } => {
            assert_eq!(to.as_str(), "big");
            assert_eq!(*window_ms, crate::DEFAULT_OFFER_WINDOW_MS);
        }
        other => panic!("expected an offer to big, got {other:?}"),
    }
    // The winner is cheapest, and the reason is in the parts.
    let winner = &decision.candidates[0];
    assert_eq!(winner.node.as_str(), "big");
    assert_eq!(winner.score.part("queue_depth"), Some(0));
    assert!(winner.score.total_ms < decision.self_score.as_ref().unwrap().total_ms);
    // `noservice` is not a candidate and the view says why.
    assert!(decision.excluded.iter().any(|excluded| excluded.node.as_str() == "noservice" && excluded.why == "incapable"));

    let placement = submitted.placement.expect("an answer arrived");
    assert_eq!(placement.runner, 1);
    assert!(matches!(&placement.via, Via::Accepted { node, offers, .. } if node == "big" && *offers == 1));
    // One placement, one offer: the counter must not count the decision and the send separately.
    assert_eq!(sim.node(0).metrics.placements, 1);
    assert_eq!(sim.node(0).metrics.offers, 1);
    assert_eq!(sim.node(0).metrics.placed, 1);
}

#[test]
fn a_big_payload_goes_where_the_bytes_are_and_a_small_one_does_not() {
    let mut sim = fabric(&["producer", "idle"], &["embed"]);
    // The idle peer is slightly busier than this node: without locality, it is still the cheapest.
    sim.set_load(0, 40, 40);
    sim.set_load(1, 5, 20);
    sim.beat();

    let small = sim.submit(0, "embed", &vec![7u8; 4 * 1024]).expect("placed");
    assert!(matches!(&small.decision.plan, Plan::Offer { to, .. } if to.as_str() == "idle"));

    let big = sim.submit(0, "embed", &vec![7u8; 512 * 1024]).expect("placed");
    // 512 KiB at 20 MB/s is 26 ms of transfer and the producer already holds the bytes: the locality
    // bonus (5 s) more than covers the load difference, so it wins locally.
    match &big.decision.plan {
        Plan::Local { because } => assert_eq!(*because, LocalReason::SelfBest),
        other => panic!("expected the local path for a 2 MiB payload, got {other:?}"),
    }
    let self_score = big.decision.self_score.as_ref().expect("self was scored");
    assert_eq!(self_score.part("locality"), Some(-placement::DEFAULT_LOCALITY_BONUS_MS));
    assert!(big.decision.candidates.iter().any(|candidate| candidate.node.as_str() == "idle"
        && candidate.score.part("transfer").is_some()));
}

#[test]
fn self_wins_an_exact_tie_because_local_costs_no_round_trip() {
    let mut sim = fabric(&["a", "b"], &["ocr"]);
    sim.set_load(0, 10, 10);
    sim.set_load(1, 10, 10);
    sim.beat();

    let submitted = sim.submit(0, "ocr", b"image").expect("placed");
    assert!(matches!(&submitted.decision.plan, Plan::Local { because: LocalReason::SelfBest }));
    assert_eq!(submitted.placement.unwrap().runner, 0);
    assert_eq!(sim.offers, 0, "a tie must not cost a round trip");
}

#[test]
fn a_busy_self_offers_even_when_the_peer_is_merely_less_busy() {
    let mut sim = fabric(&["a", "b"], &["ocr"]);
    sim.set_load(0, 96, 10); // above the gate: not a candidate at all
    sim.set_load(1, 80, 10);
    sim.beat();

    let submitted = sim.submit(0, "ocr", b"image").expect("placed");
    assert!(matches!(&submitted.decision.plan, Plan::Offer { to, .. } if to.as_str() == "b"));
    assert!(submitted
        .decision
        .excluded
        .iter()
        .any(|excluded| excluded.node.as_str() == "a" && excluded.why == "busy"));
}

#[test]
fn a_killed_node_stops_being_a_candidate_after_three_missed_beats() {
    let mut sim = fabric(&["a", "b"], &["stt"]);
    sim.set_load(0, 90, 10);
    sim.set_load(1, 5, 10);
    sim.beat();

    let first = sim.submit(0, "stt", b"one").expect("placed");
    assert!(matches!(&first.via_plan(), Plan::Offer { to, .. } if to.as_str() == "b"));

    sim.kill(1);
    sim.advance(8_000);
    sim.tick();
    assert!(sim.node(0).view.is_live("b", sim.now()), "two beats missed is still live");

    sim.advance(2_000);
    sim.tick();
    assert!(!sim.node(0).view.is_live("b", sim.now()), "three beats missed is stale");

    // With this node over its own safety gate too, there is nobody left: the plan says so by name.
    sim.set_load(0, 99, 10);
    sim.beat();
    let second = sim.submit(0, "stt", b"two").expect("placed");
    assert!(matches!(&second.via_plan(), Plan::Local { because: LocalReason::NoPeer }));
    assert!(second.decision.excluded.iter().any(|excluded| excluded.node.as_str() == "b" && excluded.why == "stale"));
}

// A small helper so a test reads "where did it go" without matching `Submitted` twice.
trait ViaPlan {
    fn via_plan(&self) -> Plan;
}
impl ViaPlan for crate::sim::Submitted {
    fn via_plan(&self) -> Plan {
        self.decision.plan.clone()
    }
}

// ---------------------------------------------------------------- the three failures -----------------------------------------

#[test]
fn all_peers_gone_runs_locally_without_waiting() {
    let mut sim = fabric(&["only"], &["stt"]);
    let submitted = sim.submit(0, "stt", b"audio").expect("placed");
    // A lone node is its own best candidate: the local path, with nothing waited for.
    assert!(matches!(&submitted.decision.plan, Plan::Local { because: LocalReason::SelfBest }));
    let placement = submitted.placement.unwrap();
    let lease = sim.begin(&placement).expect("took the lease");
    sim.settle(0, &lease, b"transcript").expect("settled");
    assert_eq!(sim.result(0, placement.job).unwrap().0, JobState::Done);
    assert_eq!(sim.node(0).metrics.timeouts, 0, "nothing was waited for");
}

#[test]
fn a_silent_peer_costs_exactly_the_window_and_then_the_job_runs_here() {
    let mut sim = fabric(&["a", "b"], &["stt"]);
    sim.set_load(0, 90, 10); // self is above the gate, so an offer is the plan
    sim.set_load(1, 5, 10);
    sim.beat();
    sim.node_mut(1).answer = false; // the peer is wedged: it beats, it never answers

    let started = sim.now();
    let submitted = sim.submit(0, "stt", b"audio").expect("placed");
    assert!(matches!(&submitted.decision.plan, Plan::Offer { .. }));
    assert!(submitted.placement.is_none(), "an offer is in flight");

    sim.advance(crate::DEFAULT_OFFER_WINDOW_MS - 1);
    assert!(sim.tick().is_empty(), "the window has not elapsed yet");
    sim.advance(1);
    let timed = sim.tick();
    assert_eq!(timed.len(), 1);
    assert_eq!(timed[0].job, submitted.job.0);
    assert_eq!(timed[0].step, Step::Local { because: LocalReason::OfferWindowElapsed });
    assert_eq!(sim.now() - started, crate::DEFAULT_OFFER_WINDOW_MS);

    let placement = sim.resolve(timed.into_iter().next().unwrap()).expect("resolved");
    assert_eq!(placement.runner, 0);
    assert_eq!(placement.via, Via::Local { because: LocalReason::OfferWindowElapsed });
    let lease = sim.begin(&placement).expect("took the lease");
    sim.settle(0, &lease, b"transcript").expect("settled");
    assert_eq!(sim.node(0).metrics.timeouts, 1);
    assert_eq!(sim.node(0).metrics.fallbacks.get("offer_window_elapsed"), Some(&1));
}

#[test]
fn a_refusal_falls_through_to_the_next_candidate_inside_the_same_window() {
    let mut sim = fabric(&["a", "b", "c"], &["stt"]);
    sim.set_load(0, 90, 10); // self above the gate
    sim.set_load(1, 5, 10); // best candidate, will refuse (it got busy since its beat)
    sim.set_load(2, 20, 10);
    sim.beat();
    sim.set_load(1, 99, 10); // a burst after the beat: the producer still scores it as idle

    let submitted = sim.submit(0, "stt", b"audio").expect("placed");
    let placement = submitted.placement.expect("c accepted");
    assert!(matches!(&placement.via, Via::Accepted { node, offers, .. } if node == "c" && *offers == 2));
    assert_eq!(sim.node(0).metrics.refuses.get("busy"), Some(&1));
    assert_eq!(placement.runner, 2);
}

#[test]
fn a_node_killed_mid_job_loses_its_lease_and_the_job_finishes_exactly_once() {
    let mut sim = fabric(&["producer", "worker", "spare"], &["stt"]);
    sim.set_load(0, 90, 10); // the producer is busy: it offers
    sim.set_load(1, 2, 10);
    sim.set_load(2, 40, 10);
    sim.beat();

    let submitted = sim.submit(0, "stt", b"audio").expect("placed");
    let placement = submitted.placement.expect("the worker accepted");
    assert_eq!(placement.runner, 1);

    // The worker takes the lease and starts; then the machine powers off.
    let lease = sim.begin(&placement).expect("took the lease");
    assert_eq!(sim.stats(0, "stt").leased, 1);
    sim.kill(1);
    sim.advance(lease.lease_ms + 1);

    // The lease lapses: the producer's own recovery puts the job back to ready.
    assert_eq!(sim.recover(0, "stt"), 1);
    assert_eq!(sim.stats(0, "stt").ready, 1);
    assert_eq!(sim.stats(0, "stt").leased, 0);

    // Whoever is best now runs it: the spare accepted, so the job finishes elsewhere.
    sim.advance(9_000);
    sim.tick();
    assert!(!sim.node(0).view.is_live("worker", sim.now()));
    let second = sim.place_existing(0, "stt", submitted.job, 5).expect("re-placed");
    let placement = second.placement.expect("resolved");
    assert!(matches!(&placement.via, Via::Accepted { node, .. } if node == "spare"));
    assert_eq!(placement.runner, 2);
    let lease2 = sim.begin(&placement).expect("re-took the lease");
    sim.settle(0, &lease2, b"transcript-2").expect("settled");

    // The dead node wakes up and tries to settle: the queue refuses it, and the result is the one
    // that was written - exactly once.
    let late = sim.settle(0, &lease, b"transcript-1");
    assert_eq!(late, Err("lease_lost".to_string()));
    assert_eq!(sim.node(0).metrics.lost_settles, 1);
    let (state, result) = sim.result(0, submitted.job).unwrap();
    assert_eq!(state, JobState::Done);
    assert_eq!(result.as_deref(), Some(&b"transcript-2"[..]));
    assert_eq!(sim.node(0).metrics.settled, 1);
    assert_eq!(sim.node(0).metrics.lease_expiries, 1);
}

#[test]
fn the_fabric_off_is_the_local_path() {
    let config = Config { enabled: false, ..Config::default() };
    let mut sim = SimFabric::new(config, &["a", "b"], &["stt"]);
    sim.beat();
    sim.set_load(0, 99, 99);
    sim.set_load(1, 1, 1);
    sim.beat();

    let submitted = sim.submit(0, "stt", b"audio").expect("placed");
    assert_eq!(submitted.decision.plan, Plan::Local { because: LocalReason::Disabled });
    assert_eq!(submitted.placement.unwrap().runner, 0);
    assert_eq!(sim.offers, 0, "the flag off sends nothing");
    assert_eq!(sim.node(0).metrics.fallbacks.get("disabled"), Some(&1));
}

// ---------------------------------------------------------------- lease ----------------------------------------------------

#[test]
fn a_heartbeat_extends_a_lease_and_an_offer_refused_for_the_wrong_target_is_ignored() {
    let mut sim = fabric(&["a", "b"], &["stt"]);
    sim.set_load(0, 90, 10);
    sim.set_load(1, 5, 10);
    sim.beat();
    let submitted = sim.submit(0, "stt", b"audio").expect("placed");
    let placement = submitted.placement.unwrap();
    let mut lease = sim.begin(&placement).expect("took the lease");

    let before = lease.until_ms;
    sim.advance(2_000);
    let after = sim.heartbeat(0, &mut lease).expect("extended");
    assert!(after > before);
    assert!(lease.still_held(&sim.node(0).queue));

    // An accept naming a node that was never offered is not an answer to this offer.
    let mut router = sim.node(0).router.clone();
    let request = Request::new("stt", 999, 5);
    let view = sim.node(0).view.clone();
    let decision = placement::choose(&view, &request, "a", sim.now(), &sim.config, &());
    let step = router.place(decision, &request, sim.now());
    let Step::Offer(offer) = step else { panic!("expected an offer") };
    let wrong = Accept { rid: offer.rid.clone(), node: node("a"), lease_ms: 5_000, at_ms: sim.now() };
    assert_eq!(router.on_reply(999, Reply::Accept(wrong), sim.now()), None);
    let stale = Refuse::new("not-this-offer", &node("b"), "busy");
    assert_eq!(router.on_reply(999, Reply::Refuse(stale), sim.now()), None);
}

#[test]
fn the_lease_refuses_a_second_worker_and_reports_the_queue_word() {
    let mut sim = fabric(&["a"], &["stt"]);
    let submitted = sim.submit(0, "stt", b"audio").expect("placed");
    let placement = submitted.placement.unwrap();
    let lease = sim.begin(&placement).expect("took the lease");
    // A second take finds nothing: the job is leased, and the queue's limit is not the reason.
    let other = FabricLease::take(&sim.node(0).queue, &queue_name("stt"), &node("a"), 2, 5_000, sim.now());
    assert_eq!(other, Ok(None));
    assert_eq!(worker_id(&node("a"), 1), "a:1");
    sim.settle(0, &lease, b"ok").expect("settled");
    // Settling twice is the same lease: the queue refuses the second settle, not silently accepts it.
    assert_eq!(sim.settle(0, &lease, b"again"), Err("lease_lost".to_string()));
    assert_eq!(lease.done(&sim.node(0).queue, b"x"), Err(LeaseError::Lost));
}

// ---------------------------------------------------------------- admin ----------------------------------------------------

#[test]
fn the_admin_view_shows_the_live_view_recent_placements_fallbacks_and_lease_expiries() {
    let mut sim = fabric(&["producer", "worker"], &["stt"]);
    sim.set_load(0, 90, 10);
    sim.set_load(1, 5, 10);
    sim.beat();
    let submitted = sim.submit(0, "stt", b"audio").expect("placed");
    let placement = submitted.placement.unwrap();
    let lease = sim.begin(&placement).expect("took the lease");
    sim.kill(1);
    sim.advance(lease.lease_ms + 1);

    // Before recovery the admin view shows the lapsed lease, still outstanding and already past its
    // expiry: that is what an operator sees in the second before the sweeper runs.
    let before = sim.admin(0, "stt");
    assert_eq!(before["leases"][0]["outstanding"][0]["job"], json!(submitted.job.0));
    assert_eq!(before["leases"][0]["expired_in_waiting"], json!(1));

    assert_eq!(sim.recover(0, "stt"), 1);
    let view = sim.admin(0, "stt");
    assert_eq!(view["ok"], json!(true));
    assert_eq!(view["enabled"], json!(true));
    assert_eq!(view["self"], json!("producer"));
    assert_eq!(view["stale_after_ms"], json!(9_000));
    let nodes = view["nodes"].as_array().expect("nodes");
    assert_eq!(nodes.len(), 2);
    assert!(nodes.iter().any(|n| n["node"] == json!("worker") && n["self"] == json!(false)));
    assert!(nodes.iter().any(|n| n["node"] == json!("producer") && n["self"] == json!(true)));

    let recent = view["recent"].as_array().expect("recent");
    assert!(!recent.is_empty());
    let first = &recent[0];
    assert_eq!(first["kind"], json!("stt"));
    assert_eq!(first["outcome"], json!("accepted"));
    assert!(first["score_parts"]["queue_depth"].is_number(), "the score's parts are printed, not just the total");
    assert_eq!(view["counters"]["accepts"], json!(1));
    assert_eq!(view["counters"]["lease_expiries"], json!(1));
    assert_eq!(view["leases"][0]["expired_in_waiting"], json!(0), "recovery already ran");
    assert!(view["leases"][0]["outstanding"].as_array().unwrap().is_empty());
    // Nothing that could carry a payload: the record's keys are ids, numbers and words.
    for record in recent {
        let keys: Vec<&str> = record.as_object().unwrap().keys().map(String::as_str).collect();
        assert!(!keys.iter().any(|key| matches!(*key, "payload" | "text" | "result" | "audio")));
    }
}

// ---------------------------------------------------------------- latency ---------------------------------------------------

/// One node, one real loopback peer: how long the placement decision takes, and what one offer round
/// trip costs on a socket. The target from the brief is "one RTT + < 5 ms"; the part this crate
/// controls is the decision, so that is what the assertion bounds, and the measured numbers are
/// printed for the report (`cargo test -p wa-fabric -- --nocapture`).
#[test]
fn placement_latency_is_one_round_trip_plus_under_five_ms() {
    use std::io::{Read, Write};
    use std::net::{TcpListener, TcpStream};

    // `WA_FABRIC_ROUNDS` moves the sample count for `scripts/bench-fabric.sh`; the default is the
    // number the report quotes. Clamped, so a typo cannot make the test run for an hour.
    let rounds = std::env::var("WA_FABRIC_ROUNDS")
        .ok()
        .and_then(|raw| raw.trim().parse::<usize>().ok())
        .unwrap_or(200)
        .clamp(20, 20_000);
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let address = listener.local_addr().expect("addr");
    let peer = std::thread::spawn(move || {
        let (mut socket, _) = listener.accept().expect("accept");
        socket.set_nodelay(true).ok();
        loop {
            let mut header = [0u8; 4];
            if socket.read_exact(&mut header).is_err() {
                return;
            }
            let mut body = vec![0u8; u32::from_be_bytes(header) as usize];
            socket.read_exact(&mut body).expect("body");
            let offer = Offer::decode(&body).expect("a valid offer");
            let accept = Accept { rid: offer.rid.clone(), node: offer.to.clone(), lease_ms: offer.lease_ms, at_ms: 0 };
            let reply = accept.encode();
            socket.write_all(&(reply.len() as u32).to_be_bytes()).expect("write header");
            socket.write_all(&reply).expect("write body");
        }
    });
    let mut socket = TcpStream::connect(address).expect("connect");
    socket.set_nodelay(true).ok();

    let config = Config::default();
    let mut view = PresenceView::new(&config);
    view.observe(Heartbeat::new("self", ["stt"], Load::new(0, 90, 10), "0.1.0", 0), 1_000);
    view.observe(Heartbeat::new("peer", ["stt"], Load::new(0, 2, 10), "0.1.0", 0), 1_000);
    let self_id = node("self");
    let mut router = crate::offer::Router::new(self_id.clone(), &config);

    let mut decide_us = Vec::with_capacity(rounds);
    let mut rtt_us = Vec::with_capacity(rounds);
    let mut rtt_by_peer: BTreeMap<String, i64> = BTreeMap::new();
    for round in 0..rounds {
        let request = Request::new("stt", round as u64, 8 * 1024);
        let started = Instant::now();
        let decision = placement::choose(&view, &request, self_id.as_str(), 1_000, &config, &());
        decide_us.push(started.elapsed().as_micros() as i64);
        let step = router.place(decision, &request, 1_000);
        let Step::Offer(offer) = step else { panic!("expected an offer, got {step:?}") };

        let body = offer.encode();
        let started = Instant::now();
        socket.write_all(&(body.len() as u32).to_be_bytes()).expect("write header");
        socket.write_all(&body).expect("write body");
        let mut header = [0u8; 4];
        socket.read_exact(&mut header).expect("read header");
        let mut reply = vec![0u8; u32::from_be_bytes(header) as usize];
        socket.read_exact(&mut reply).expect("read reply");
        let accept = Accept::decode(&reply).expect("accept");
        let took = started.elapsed().as_micros() as i64;
        rtt_us.push(took);
        rtt_by_peer.insert(accept.node.as_str().to_string(), took);
        assert!(matches!(router.on_reply(round as u64, Reply::Accept(accept), 1_001), Some(Step::Placed { .. })));
    }

    let percentile = |mut samples: Vec<i64>, percent: usize| -> i64 {
        samples.sort_unstable();
        samples[((samples.len() * percent).div_ceil(100)).clamp(1, samples.len()) - 1]
    };
    let decide_p50 = percentile(decide_us.clone(), 50);
    let decide_p95 = percentile(decide_us.clone(), 95);
    let rtt_p50 = percentile(rtt_us.clone(), 50);
    let rtt_p95 = percentile(rtt_us.clone(), 95);
    eprintln!(
        "fabric latency: placement decision p50={decide_p50}us p95={decide_p95}us; one offer round trip on loopback p50={rtt_p50}us p95={rtt_p95}us (n={rounds})"
    );
    assert!(decide_p95 < 5_000, "the placement decision must cost well under 5 ms, got {decide_p95}us");
    assert!(rtt_p95 < 50_000, "one loopback round trip must be milliseconds, got {rtt_p95}us");

    // The same numbers through the metrics: a placement's own p50/p95, which is what the admin view
    // reports.
    let mut metrics = crate::metrics::FabricMetrics::new();
    for (index, took) in rtt_us.iter().enumerate() {
        metrics.accepted(1_001, index as u64, "peer", *took);
    }
    let (p50, p95, samples) = metrics.percentiles();
    assert_eq!(samples, rounds);
    eprintln!("fabric latency (metrics): p50={p50:?}us p95={p95:?}us samples={samples}");
    assert!(p95.unwrap() >= p50.unwrap());
    drop(socket);
    let _ = peer.join();
}

// ---------------------------------------------------------------- wire -----------------------------------------------------

#[test]
fn an_offer_round_trips_and_an_expired_offer_is_refused_by_the_peer() {
    let config = Config::default();
    let mut view = PresenceView::new(&config);
    view.observe(Heartbeat::new("self", ["stt"], Load::new(0, 5, 10), "0.1.0", 0), 1_000);
    let request = Request::new("stt", 7, 1_024);
    let decision = placement::choose(&view, &request, "peer", 1_000, &config, &());
    let mut router = crate::offer::Router::new(node("peer"), &config);
    let Step::Offer(offer) = router.place(decision, &request, 1_000) else { panic!("expected an offer") };
    let decoded = Offer::decode(&offer.encode()).expect("decodes");
    assert_eq!(&decoded, &*offer);

    let caps = Capabilities::of(["stt"]);
    let accept = offer::answer(&decoded, &caps, &Load::new(0, 5, 10), "self", 1_100, &config).expect("accepted");
    assert_eq!(accept.node.as_str(), "self");
    let late = offer::answer(&decoded, &caps, &Load::new(0, 5, 10), "self", 1_201, &config).unwrap_err();
    assert_eq!(late.reason, "late");
    let wrong = offer::answer(&decoded, &caps, &Load::new(0, 5, 10), "other", 1_100, &config).unwrap_err();
    assert_eq!(wrong.reason, "wrong_target");
    let busy = offer::answer(&decoded, &caps, &Load::new(0, 99, 10), "self", 1_100, &config).unwrap_err();
    assert_eq!(busy.reason, "busy");
    let incapable = offer::answer(&decoded, &Capabilities::of(["ocr"]), &Load::new(0, 5, 10), "self", 1_100, &config).unwrap_err();
    assert_eq!(incapable.reason, "incapable");
}

#[test]
fn config_from_settings_keeps_the_defaults_for_an_unreadable_knob() {
    let default = Config::default();
    assert_eq!(Config::from_settings(None, None, None, None), default);
    assert!(!Config::from_settings(Some("0"), None, None, None).enabled);
    assert!(!Config::from_settings(Some("false"), None, None, None).enabled);
    assert!(Config::from_settings(Some("nonsense"), None, None, None).enabled, "an unknown word is not consent to turn it off");
    assert_eq!(Config::from_settings(None, Some(0), Some(0), Some(0)), default, "a zero is not a value");
    let tuned = Config::from_settings(None, Some(2_000), Some(150), Some(50_000));
    assert_eq!(tuned.heartbeat_ms, 2_000);
    assert_eq!(tuned.offer_window_ms, 150);
    assert_eq!(tuned.knobs.transfer_bytes_per_ms, 50_000);
}

#[test]
fn a_fabric_record_never_carries_a_payload_field() {
    // The records are the whole vocabulary of the fabric; none of them names the work's content.
    let config = Config::default();
    let mut view = PresenceView::new(&config);
    view.observe(Heartbeat::new("a", ["stt"], Load::new(0, 1, 1), "v", 0), 1_000);
    view.observe(Heartbeat::new("b", ["stt"], Load::new(0, 1, 1), "v", 0), 1_000);
    let request = Request::new("stt", 1, 10);
    let decision = placement::choose(&view, &request, "a", 1_000, &config, &());
    let encoded = decision.to_json().to_string();
    for word in ["payload", "audio", "text", "transcript"] {
        assert!(!encoded.contains(word), "the decision must not name {word}: {encoded}");
    }
    assert_eq!(RecordOutcome::Offered.as_str(), "offered");
    assert_eq!(JobId(1).to_string(), "job-1");
}
