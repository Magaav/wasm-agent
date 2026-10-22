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

type OCRWorker struct {
	Python, Script, Cache string
	mu                    sync.Mutex
	cmd                   *exec.Cmd
	input                 io.WriteCloser
	output                *bufio.Scanner
}

func (w *OCRWorker) close() {
	if w.cmd != nil {
		w.input.Close()
		w.cmd.Process.Kill()
		w.cmd.Wait()
		w.cmd = nil
	}
}
func (w *OCRWorker) Close() { w.mu.Lock(); defer w.mu.Unlock(); w.close() }
func (w *OCRWorker) Recognize(ctx context.Context, path, language string) (string, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.Python == "" || w.Script == "" {
		return "", errors.New("local_worker_not_configured")
	}
	if w.cmd == nil {
		w.cmd = exec.Command(w.Python, w.Script, "--worker")
		w.cmd.Env = append(os.Environ(), "HF_HUB_OFFLINE=1")
		if w.Cache != "" {
			w.cmd.Env = append(w.cmd.Env, "WA_WHATSAPP_OCR_MODELS="+w.Cache)
		}
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
	b, _ := json.Marshal(map[string]string{"input": path, "language": language, "mode": "ocr"})
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
	case <-time.After(2 * time.Minute):
		w.close()
		<-done
		return "", errors.New("worker_timeout")
	case res := <-done:
		if !res.ok {
			w.close()
			return "", errors.New("worker_eof")
		}
		var value struct {
			OK    bool   `json:"ok"`
			Text  string `json:"text"`
			Error string `json:"error"`
		}
		if json.Unmarshal(res.line, &value) != nil {
			w.close()
			return "", errors.New("worker_protocol")
		}
		if !value.OK {
			if value.Error == "no_text_detected" || value.Error == "image_too_large" || value.Error == "ocr_text_too_long" {
				return "", permanentError(value.Error)
			}
			switch value.Error {
			case "WA_WHATSAPP_OCR_MODELS_required", "rapidocr_missing", "offline_model_unavailable":
				return "", errors.New(value.Error)
			}
			return "", errors.New("worker_compute_failed")
		}
		return value.Text, nil
	}
}
