//! Export: Prometheus text exposition and JSON. No network, no client, no HTTP: the host (or
//! `wa telemetry`) asks for a string and decides where it goes.
use crate::histogram::{bounds_of, upper_seconds};
use crate::labels::Labels;
use crate::metrics::{Metrics, SeriesState};
use crate::trace::Span;
use serde_json::{json, Map, Value};

impl Metrics {
    /// Prometheus exposition format, text. Every family keeps the name it was registered with; a
    /// histogram adds `_bucket`/`_sum`/`_count` as the format requires. Counters are exported
    /// without forcing a `_total` suffix: the name is the caller's, and rewriting it here would
    /// make the metric an operator reads different from the one a call site records.
    pub fn prometheus(&self) -> String {
        let state = self.inner.lock();
        let mut out = String::with_capacity(16 * 1024);
        let mut dropped = String::new();
        for (component, entry) in &state.components {
            for (name, family) in &entry.families {
                out.push_str(&format!("# TYPE {name} {}\n", family.kind.as_str()));
                for series in &family.series {
                    let sel = selection(component, &series.labels);
                    match &series.state {
                        SeriesState::Counter(v) => {
                            out.push_str(&format!("{name}{sel} {v}\n"));
                        }
                        SeriesState::Gauge(v) => {
                            out.push_str(&format!("{name}{sel} {v}\n"));
                        }
                        SeriesState::Histogram(h) => {
                            let mut cumulative = 0u64;
                            for (idx, &count) in h.buckets().iter().enumerate() {
                                if count == 0 {
                                    continue;
                                }
                                cumulative += count;
                                let le = upper_seconds(h.sub_bits(), idx);
                                out.push_str(&format!(
                                    "{name}_bucket{} {cumulative}\n",
                                    selection_with(component, &series.labels, "le", &format!("{le}"))
                                ));
                            }
                            out.push_str(&format!(
                                "{name}_bucket{} {}\n",
                                selection_with(component, &series.labels, "le", "+Inf"),
                                h.count()
                            ));
                            out.push_str(&format!("{name}_sum{sel} {}\n", h.sum()));
                            out.push_str(&format!("{name}_count{sel} {}\n", h.count()));
                        }
                    }
                }
                if family.dropped_sets > 0 {
                    dropped.push_str(&format!(
                        "wa_telemetry_cardinality_dropped{{component=\"{}\",name=\"{}\"}} {}\n",
                        escape(component),
                        escape(name),
                        family.dropped_sets
                    ));
                }
            }
        }
        if !dropped.is_empty() {
            out.push_str("# TYPE wa_telemetry_cardinality_dropped gauge\n");
            out.push_str(&dropped);
        }
        out.push_str(&self.node_metrics(&state));
        out
    }

    fn node_metrics(&self, state: &crate::metrics::State) -> String {
        let s = self.stats_of(state);
        let mut out = String::new();
        out.push_str("# TYPE wa_telemetry_series gauge\n");
        for (component, entry) in &state.components {
            for (name, family) in &entry.families {
                out.push_str(&format!(
                    "wa_telemetry_series{{component=\"{}\",name=\"{}\"}} {}\n",
                    escape(component),
                    escape(name),
                    family.series.len()
                ));
            }
        }
        out.push_str(&format!(
            "# TYPE wa_telemetry_kind_conflicts_total counter\nwa_telemetry_kind_conflicts_total {}\n",
            s.kind_conflicts
        ));
        out.push_str(&format!(
            "# TYPE wa_telemetry_refused_total counter\nwa_telemetry_refused_total{{reason=\"component\"}} {}\nwa_telemetry_refused_total{{reason=\"family\"}} {}\nwa_telemetry_refused_total{{reason=\"rollup\"}} {}\n",
            s.dropped_components, s.dropped_families, s.rollup_refused
        ));
        out.push_str(&format!(
            "# TYPE wa_telemetry_rollup_series gauge\nwa_telemetry_rollup_series {}\n",
            s.rollup_series
        ));
        out.push_str("# TYPE wa_telemetry_trace gauge\n");
        out.push_str(&format!("wa_telemetry_trace{{field=\"spans\"}} {}\n", s.trace.spans));
        out.push_str(&format!("wa_telemetry_trace{{field=\"bytes\"}} {}\n", s.trace.bytes));
        out.push_str(&format!(
            "wa_telemetry_trace{{field=\"max_bytes\"}} {}\n",
            s.trace.max_bytes
        ));
        out.push_str("# TYPE wa_telemetry_trace_total counter\n");
        for (field, value) in [
            ("kept", s.trace.kept),
            ("sampled_out", s.trace.sampled_out),
            ("evicted", s.trace.evicted),
            ("oversized", s.trace.oversized),
            ("attrs_dropped", s.trace.attrs_dropped),
            ("attrs_truncated", s.trace.attrs_truncated),
        ] {
            out.push_str(&format!(
                "wa_telemetry_trace_total{{field=\"{field}\"}} {value}\n"
            ));
        }
        out
    }

    /// JSON for `wa telemetry`: stats, every family, every series. Rollups and spans are separate
    /// calls because they are the two things that get big.
    pub fn to_json(&self) -> Value {
        let state = self.inner.lock();
        let mut components = Map::new();
        for (component, entry) in &state.components {
            let mut families = Vec::new();
            for (name, family) in &entry.families {
                let mut series = Vec::new();
                for s in &family.series {
                    let mut labels = Map::new();
                    for (k, v) in s.labels.pairs() {
                        labels.insert(k.clone(), json!(v));
                    }
                    let mut item = json!({
                        "labels": Value::Object(labels),
                    });
                    let obj = item.as_object_mut().expect("object");
                    match &s.state {
                        SeriesState::Counter(v) => {
                            obj.insert("kind".into(), json!("counter"));
                            obj.insert("value".into(), json!(v));
                        }
                        SeriesState::Gauge(v) => {
                            obj.insert("kind".into(), json!("gauge"));
                            obj.insert("value".into(), json!(v));
                        }
                        SeriesState::Histogram(h) => {
                            obj.insert("kind".into(), json!("histogram"));
                            obj.insert("count".into(), json!(h.count()));
                            obj.insert("sum".into(), json!(h.sum()));
                            obj.insert("min".into(), json!(h.min()));
                            obj.insert("max".into(), json!(h.max()));
                            match h.mean() {
                                Some(m) => obj.insert("mean".into(), json!(m)),
                                None => obj.insert("mean".into(), Value::Null),
                            };
                            match h.p50() {
                                Some(p) => obj.insert("p50".into(), json!(p)),
                                None => obj.insert("p50".into(), Value::Null),
                            };
                            match h.p95() {
                                Some(p) => obj.insert("p95".into(), json!(p)),
                                None => obj.insert("p95".into(), Value::Null),
                            };
                            let mut buckets = Vec::new();
                            for (idx, &count) in h.buckets().iter().enumerate() {
                                if count > 0 {
                                    let (lo, hi) = bounds_of(h.sub_bits(), idx);
                                    buckets.push(json!([lo, hi, count]));
                                }
                            }
                            obj.insert("buckets_us".into(), json!(buckets));
                        }
                    }
                    series.push(item);
                }
                families.push(json!({
                    "name": &**name,
                    "kind": family.kind.as_str(),
                    "dropped_label_sets": family.dropped_sets,
                    "series": series,
                }));
            }
            components.insert(component.to_string(), json!({ "families": families }));
        }
        let s = self.stats_of(&state);
        json!({
            "version": 1,
            "saved_at_ms": self.inner.now_ms(),
            "stats": {
                "components": s.components,
                "families": s.families,
                "series": s.series,
                "kind_conflicts": s.kind_conflicts,
                "dropped_components": s.dropped_components,
                "dropped_families": s.dropped_families,
                "rollup_series": s.rollup_series,
                "rollup_refused": s.rollup_refused,
            },
            "traces": {
                "spans": s.trace.spans,
                "bytes": s.trace.bytes,
                "max_bytes": s.trace.max_bytes,
                "kept": s.trace.kept,
                "sampled_out": s.trace.sampled_out,
                "evicted": s.trace.evicted,
                "oversized": s.trace.oversized,
                "attrs_dropped": s.trace.attrs_dropped,
                "attrs_truncated": s.trace.attrs_truncated,
            },
            "components": Value::Object(components),
        })
    }

    /// Rollup series as JSON: finished minutes/hours/days plus the open minute.
    pub fn rollups_json(&self) -> Value {
        let views = self.rollups();
        let mut out = Vec::with_capacity(views.len());
        for v in views {
            let mut labels = Map::new();
            for (k, val) in v.labels.pairs() {
                labels.insert(k.clone(), json!(val));
            }
            let point = |p: &crate::rollup::RollupPoint| {
                json!({
                    "start_ms": p.start_ms,
                    "observations": p.observations,
                    "errors": p.errors,
                    "sum": p.sum,
                    "min": p.min,
                    "max": p.max,
                    "last": p.last,
                })
            };
            out.push(json!({
                "component": v.component,
                "name": v.name,
                "labels": Value::Object(labels),
                "minutes": v.minutes.iter().map(point).collect::<Vec<_>>(),
                "hours": v.hours.iter().map(point).collect::<Vec<_>>(),
                "days": v.days.iter().map(point).collect::<Vec<_>>(),
                "current_minute": point(&v.current),
            }));
        }
        json!({ "version": 1, "rollups": out })
    }

    /// The retained spans, oldest first. Text-free by construction: a span carries op names and
    /// capped attributes, never message bodies.
    pub fn traces_json(&self) -> Value {
        let spans = self.spans();
        let items: Vec<Value> = spans.iter().map(span_json).collect();
        json!({ "version": 1, "spans": items })
    }

}

fn span_json(span: &Span) -> Value {
    let mut labels = Map::new();
    for (k, v) in &span.attrs {
        labels.insert(k.clone(), json!(v));
    }
    json!({
        "trace_id": span.trace_id,
        "component": &*span.component,
        "op": &*span.op,
        "start_ms": span.start_ms,
        "duration_us": span.duration_us,
        "status": span.status.as_str(),
        "attrs": Value::Object(labels),
    })
}

/// `{component="c",k="v"}` — the component label is always first so a scrape is readable.
fn selection(component: &str, labels: &Labels) -> String {
    selection_with(component, labels, "", "")
}

fn selection_with(component: &str, labels: &Labels, extra_key: &str, extra_value: &str) -> String {
    let mut out = format!("{{component=\"{}\"", escape(component));
    for (k, v) in labels.pairs() {
        out.push_str(&format!(",{}=\"{}\"", escape(k), escape(v)));
    }
    if !extra_key.is_empty() {
        out.push_str(&format!(",{}=\"{}\"", escape(extra_key), escape(extra_value)));
    }
    out.push('}');
    out
}

fn escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for ch in s.chars() {
        match ch {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            '\n' => out.push_str("\\n"),
            other => out.push(other),
        }
    }
    out
}
