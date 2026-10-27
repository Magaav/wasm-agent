// Copyright 2026 wasm-agent contributors. SPDX-License-Identifier: MIT
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"os/exec"
	"sync"
	"time"
)

// Worker owns one warm local STT process. It is killed only when it is truly
// stuck (no progress line for Stall, or past the duration-scaled Budget), on
// protocol loss, or on shutdown; a long, slow but advancing decode is never cut
// off by a fixed wall clock (that turned a 280 s voice note on a contended
// 2-core host into an endless reload/retry loop).
type Worker struct {
	Python, Script, Cache string
	// Zero values select the defaults below; tests shorten them.
	Stall, BudgetBase time.Duration
	BudgetPerAudio    float64 // budget seconds per audio second, on top of BudgetBase
	mu                sync.Mutex
	cmd               *exec.Cmd
	input             io.WriteCloser
	lines             chan []byte // closed when the current process's stdout ends
}

const (
	defaultStall          = 3 * time.Minute
	defaultBudgetBase     = 5 * time.Minute
	defaultBudgetPerAudio = 6.0
)

// workerLine is either a progress heartbeat (timings only) or the final result.
type workerLine struct {
	Progress   bool    `json:"progress"`
	Duration   float64 `json:"duration"`
	OK         bool    `json:"ok"`
	Transcript string  `json:"transcript"`
	Error      string  `json:"error"`
}

func (w *Worker) close() {
	if w.cmd != nil {
		w.input.Close()
		w.cmd.Process.Kill()
		for range w.lines {
		} // drain until the reader sees EOF; no stale line can reach the next process
		w.cmd.Wait()
		w.cmd = nil
	}
}
func (w *Worker) Close() { w.mu.Lock(); defer w.mu.Unlock(); w.close() }

// Start spawns the process so the model loads before the first audio arrives.
// Failure is not fatal here: Transcribe reports it per task, as before.
func (w *Worker) Start() error { w.mu.Lock(); defer w.mu.Unlock(); return w.start() }
func (w *Worker) start() error {
	if w.Python == "" || w.Script == "" || w.Cache == "" {
		return errors.New("local_worker_not_configured")
	}
	if info, err := os.Stat(w.Cache); err != nil || !info.IsDir() {
		return errors.New("local_model_cache_missing")
	}
	if w.cmd != nil {
		return nil
	}
	cmd := exec.Command(w.Python, w.Script, "--worker")
	cmd.Env = append(os.Environ(), "HF_HUB_OFFLINE=1", "WA_WHATSAPP_STT_MODELS="+w.Cache)
	input, err := cmd.StdinPipe()
	if err != nil {
		return err
	}
	out, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	cmd.Stderr = io.Discard
	if err = cmd.Start(); err != nil {
		return err
	}
	lines := make(chan []byte, 64)
	go func() {
		defer close(lines)
		scanner := bufio.NewScanner(out)
		scanner.Buffer(make([]byte, 4096), 128*1024)
		for scanner.Scan() {
			lines <- append([]byte(nil), scanner.Bytes()...)
		}
	}()
	w.cmd, w.input, w.lines = cmd, input, lines
	return nil
}
func (w *Worker) Transcribe(ctx context.Context, path, language string) (string, error) {
	return w.TranscribeTier(ctx, path, language, 0, 0)
}

// TranscribeTier runs one request at a decode tier (see whatsapp-stt-local.py).
// seconds is the sender-declared audio length, used for the budget until the
// worker reports the decoded duration; 0 means unknown.
func (w *Worker) TranscribeTier(ctx context.Context, path, language string, tier, seconds int) (string, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	if err := w.start(); err != nil {
		return "", err
	}
	b, _ := json.Marshal(map[string]any{"input": path, "language": language, "mode": "transcribe", "tier": tier})
	if _, err := w.input.Write(append(b, '\n')); err != nil {
		w.close()
		return "", err
	}
	stallAfter, base, per := w.Stall, w.BudgetBase, w.BudgetPerAudio
	if stallAfter <= 0 {
		stallAfter = defaultStall
	}
	if base <= 0 {
		base = defaultBudgetBase
	}
	if per <= 0 {
		per = defaultBudgetPerAudio
	}
	budgetFor := func(audio float64) time.Duration { return base + time.Duration(per*audio*float64(time.Second)) }
	started := time.Now()
	deadline := started.Add(budgetFor(float64(seconds)))
	stall := time.NewTimer(stallAfter)
	defer stall.Stop()
	budget := time.NewTimer(time.Until(deadline))
	defer budget.Stop()
	for {
		select {
		case <-ctx.Done():
			w.close()
			return "", ctx.Err()
		case <-stall.C:
			w.close()
			return "", errors.New("worker_stalled")
		case <-budget.C:
			w.close()
			return "", errors.New("worker_timeout")
		case line, ok := <-w.lines:
			if !ok {
				w.close()
				return "", errors.New("worker_eof")
			}
			var value workerLine
			if json.Unmarshal(line, &value) != nil {
				w.close()
				return "", errors.New("worker_protocol")
			}
			if value.Progress {
				// Any heartbeat proves liveness. A reported decoded duration
				// replaces the sender's claim, so the budget follows real audio.
				if !stall.Stop() {
					select {
					case <-stall.C:
					default:
					}
				}
				stall.Reset(stallAfter)
				if value.Duration > 0 {
					if d := started.Add(budgetFor(value.Duration)); !d.Equal(deadline) {
						deadline = d
						if !budget.Stop() {
							select {
							case <-budget.C:
							default:
							}
						}
						budget.Reset(time.Until(deadline))
					}
				}
				continue
			}
			if !value.OK {
				switch value.Error {
				case "no_speech_detected", "audio_too_large", "transcript_too_long":
					return "", permanentError(value.Error)
				case "WA_WHATSAPP_STT_MODELS_required", "faster_whisper_missing", "offline_model_unavailable", "fallback_model_unavailable":
					return "", errors.New(value.Error)
				}
				return "", errors.New("worker_compute_failed")
			}
			return value.Transcript, nil
		}
	}
}
