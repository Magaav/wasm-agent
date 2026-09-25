#!/usr/bin/env python3
"""Summarize retained Pi and wasm-agent traces without printing prompt contents."""
import collections
import glob
import json
import pathlib
import sqlite3
import sys


def pi_trace(root):
    files = glob.glob(str(root / "pi" / "session" / "*.jsonl"))
    if len(files) != 1:
        return {"error": f"expected one Pi session, found {len(files)}"}
    entries = []
    malformed = 0
    with open(files[0], encoding="utf-8") as stream:
        for line in stream:
            try:
                entries.append(json.loads(line))
            except json.JSONDecodeError:
                malformed += 1
    assistants = [e for e in entries if e.get("type") == "message" and
                  e.get("message", {}).get("role") == "assistant"]
    results = [e for e in entries if e.get("type") == "message" and
               e.get("message", {}).get("role") == "toolResult"]
    calls = [part for e in assistants for part in e["message"].get("content", [])
             if part.get("type") == "toolCall"]
    usage = [e["message"].get("usage") or {} for e in assistants]
    tokens = {key: sum(u.get(key) or 0 for u in usage)
              for key in ("input", "cacheRead", "cacheWrite", "output", "reasoning")}
    return {"modelCalls": len(assistants), "toolCalls": len(calls),
            "tools": dict(collections.Counter(c.get("name") for c in calls)),
            "toolFailures": sum(bool(e["message"].get("isError")) for e in results),
            "tokens": tokens, "malformedJsonlLines": malformed,
            "unfinishedToolCalls": len(calls) - len(results),
            "reportedCostUsd": round(sum((u.get("cost") or {}).get("total") or 0
                                         for u in usage), 6)}


def wasm_trace(root):
    db = root / "wasm" / "wa.db"
    if not db.exists():
        return {"error": "wasm-agent session database absent"}
    connection = sqlite3.connect(f"file:{db.as_posix()}?mode=ro", uri=True)
    with connection:
        events = [json.loads(row[0]) for row in connection.execute(
            "SELECT payload FROM harness_events WHERE kind='model_call' AND phase='end'")]
        starts = connection.execute(
            "SELECT count(*) FROM harness_events WHERE kind='model_call' AND phase='start'").fetchone()[0]
        calls = [call for (raw,) in connection.execute(
            "SELECT tool_calls FROM messages WHERE role='assistant'")
            for call in json.loads(raw or "[]")]
        failures = connection.execute(
            "SELECT count(*) FROM messages WHERE role='tool' AND ok=0").fetchone()[0]
        results = connection.execute(
            "SELECT count(*) FROM messages WHERE role='tool'").fetchone()[0]
    tokens = {key: sum((e.get("normalized") or {}).get(key) or 0 for e in events)
              for key in ("input", "cacheRead", "cacheWrite", "output", "reasoning")}
    return {"modelCalls": len(events), "unfinishedModelCalls": starts - len(events),
            "toolCalls": len(calls),
            "tools": dict(collections.Counter(c.get("function", {}).get("name") for c in calls)),
            "toolFailures": failures, "unfinishedToolCalls": len(calls) - results,
            "tokens": tokens, "modelElapsedMs": sum(e.get("ms") or 0 for e in events)}


def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: agent-benchmark-report.py <trace-dir> <fixture.json>")
    root = pathlib.Path(sys.argv[1]).resolve()
    fixture = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
    run = json.loads((root / "report.json").read_text(encoding="utf-8"))
    rates = fixture.get("ratesUsdPerMillion") or {}
    arms = {"pi": pi_trace(root), "wasm": wasm_trace(root)}
    for name, arm in arms.items():
        receipt = run.get("arms", {}).get(name, {})
        arm.update({"oraclePass": receipt.get("oracle", {}).get("pass"),
                    "timedOut": receipt.get("timedOut"),
                    "elapsedMs": receipt.get("elapsedMs"),
                    "patchBytes": receipt.get("patchBytes")})
        if "tokens" in arm and all(key in rates for key in
                                   ("input", "cacheRead", "cacheWrite", "output")):
            arm["configuredRateCostUsd"] = round(sum(
                arm["tokens"][key] * rates[key] for key in
                ("input", "cacheRead", "cacheWrite", "output")) / 1_000_000, 6)
            prompt = arm["tokens"]["input"] + arm["tokens"]["cacheRead"] + arm["tokens"]["cacheWrite"]
            arm["cacheReadShare"] = round(arm["tokens"]["cacheRead"] / prompt, 4) if prompt else None
    print(json.dumps({"fixture": run["fixture"], "source": run["source"],
                      "model": run["model"], "controls": run["controls"],
                      "cleanup": run["cleanup"], "arms": arms}, indent=2))


if __name__ == "__main__":
    main()
