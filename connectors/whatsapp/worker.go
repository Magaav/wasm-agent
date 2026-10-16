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

type Worker struct {
	Python, Script, Cache string
	mu                    sync.Mutex
	cmd                   *exec.Cmd
	input                 io.WriteCloser
	output                *bufio.Scanner
}

func (w *Worker) close() {
	if w.cmd != nil {
		w.input.Close()
		w.cmd.Process.Kill()
		w.cmd.Wait()
		w.cmd = nil
	}
}
func (w *Worker) Close() { w.mu.Lock(); defer w.mu.Unlock(); w.close() }
func (w *Worker) Transcribe(ctx context.Context, path, language string) (string, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.Python == "" || w.Script == "" || w.Cache == "" {
		return "", errors.New("local_worker_not_configured")
	}
	if info, err := os.Stat(w.Cache); err != nil || !info.IsDir() {
		return "", errors.New("local_model_cache_missing")
	}
	if w.cmd == nil {
		w.cmd = exec.Command(w.Python, w.Script, "--worker")
		w.cmd.Env = append(os.Environ(), "HF_HUB_OFFLINE=1", "WA_WHATSAPP_STT_MODELS="+w.Cache)
		var err error
		w.input, err = w.cmd.StdinPipe()
		if err != nil {
			w.cmd = nil
			return "", err
		}
		out, err := w.cmd.StdoutPipe()
		if err != nil {
			w.cmd = nil
			return "", err
		}
		w.cmd.Stderr = io.Discard
		if err = w.cmd.Start(); err != nil {
			w.cmd = nil
			return "", err
		}
		w.output = bufio.NewScanner(out)
		w.output.Buffer(make([]byte, 4096), 128*1024)
	}
	b, _ := json.Marshal(map[string]string{"input": path, "language": language, "mode": "transcribe"})
	if _, err := w.input.Write(append(b, '\n')); err != nil {
		w.close()
		return "", err
	}
	type result struct {
		line []byte
		ok   bool
	}
	done := make(chan result, 1)
	go func() { ok := w.output.Scan(); done <- result{append([]byte(nil), w.output.Bytes()...), ok} }()
	select {
	case <-ctx.Done():
		w.close()
		<-done
		return "", ctx.Err()
	case <-time.After(5 * time.Minute):
		w.close()
		<-done
		return "", errors.New("worker_timeout")
	case res := <-done:
		if !res.ok {
			w.close()
			return "", errors.New("worker_eof")
		}
		var value struct {
			OK         bool   `json:"ok"`
			Transcript string `json:"transcript"`
			Error      string `json:"error"`
		}
		if json.Unmarshal(res.line, &value) != nil {
			w.close()
			return "", errors.New("worker_protocol")
		}
		if !value.OK {
			if value.Error == "no_speech_detected" || value.Error == "audio_too_large" || value.Error == "transcript_too_long" {
				return "", permanentError(value.Error)
			}
			switch value.Error {
			case "WA_WHATSAPP_STT_MODELS_required", "faster_whisper_missing", "offline_model_unavailable":
				return "", errors.New(value.Error)
			}
			return "", errors.New("worker_compute_failed")
		}
		return value.Transcript, nil
	}
}
