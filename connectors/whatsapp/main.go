// Copyright 2026 wasm-agent contributors. SPDX-License-Identifier: MIT
package main

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/skip2/go-qrcode"
	"golang.org/x/term"
)

func api(j *Journal, token string) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "no-store")
		fail := func(status int, reason string) {
			w.WriteHeader(status)
			json.NewEncoder(w).Encode(map[string]any{"ok": false, "error": reason})
		}
		if r.Method != "POST" {
			fail(405, "post_required")
			return
		}
		if subtle.ConstantTimeCompare([]byte(r.Header.Get("Authorization")), []byte("Bearer "+token)) != 1 {
			fail(401, "authentication_required")
			return
		}
		var req readRequest
		decoder := json.NewDecoder(io.LimitReader(r.Body, 131073))
		decoder.DisallowUnknownFields()
		if decoder.Decode(&req) != nil || decoder.Decode(new(any)) != io.EOF {
			fail(400, "invalid_request")
			return
		}
		if req.RefreshNames && r.URL.Path != "/list_chats" {
			fail(400, "refresh_names_requires_list_chats")
			return
		}
		c, err := j.scope(req.Account, req.Generation, req.Chat)
		if err != nil {
			fail(403, "scope_mismatch")
			return
		}
		switch r.URL.Path {
		case "/status":
			status, err := j.status()
			if err != nil {
				fail(503, "journal_unavailable")
				return
			}
			json.NewEncoder(w).Encode(status)
		case "/lookup_self":
			j.identityMu.Lock()
			defer j.identityMu.Unlock()
			if _, err := j.scope(req.Account, req.Generation, req.Chat); err != nil {
				fail(403, "scope_mismatch")
				return
			}
			j.mu.Lock()
			verified, authenticated := j.verified, j.authenticated
			j.mu.Unlock()
			if !verified {
				fail(409, "paired_identity_unproven")
				return
			}
			json.NewEncoder(w).Encode(map[string]any{"ok": true, "account": c.Account, "self_chat": c.Account, "generation": c.Generation, "identity_basis": "local_sdk_store_match_not_live_authentication", "authenticated_event_observed": authenticated})
		case "/inspect_chat":
			if req.Chat == "" {
				fail(400, "chat_required")
				return
			}
			var hold string
			if err := j.db.QueryRow("SELECT reason FROM chat_holds WHERE account=? AND generation=? AND chat=?", c.Account, c.Generation, req.Chat).Scan(&hold); err != nil && !errors.Is(err, sql.ErrNoRows) {
				fail(503, "journal_unavailable")
				return
			}
			diagnosis, err := j.mutationCoverage(c, req.Chat)
			if err != nil {
				fail(503, "journal_unavailable")
				return
			}
			json.NewEncoder(w).Encode(map[string]any{"mutation_coverage": diagnosis, "ok": true, "transcript_posting_hold": hold, "account": c.Account, "conversation_id": req.Chat, "generation": c.Generation, "draft_visibility": "unsupported", "draft": nil, "general_send_supported": false})
		case "/read_snapshot", "/list_chats", "/posting_status":
			if req.Limit < 0 || req.Limit > 10000 || req.Since < 0 || req.Before < 0 || req.SentSince < 0 || req.Until < 0 || (req.Until > 0 && req.SentSince > req.Until) || len(req.Query) > 256 {
				fail(400, "invalid_window")
				return
			}
			if _, _, err := j.readScope(c, req, ""); err != nil {
				fail(403, "read_scope_not_approved")
				return
			}
			var refresh *NameRefresh
			if req.RefreshNames {
				if req.Limit == 0 {
					req.Limit = nameRefreshRows
				}
				if req.Limit > nameRefreshRows || req.Query != "" {
					fail(400, "refresh_requires_unfiltered_page_max32")
					return
				}
				value, e := j.refreshNames(r.Context(), c, req)
				if e != nil {
					fail(503, "metadata_refresh_unavailable")
					return
				}
				refresh = &value
				current, scopeErr := j.scope(req.Account, req.Generation, req.Chat)
				if scopeErr != nil {
					fail(403, "scope_mismatch")
					return
				}
				if _, _, scopeErr = j.readScope(current, req, ""); scopeErr != nil {
					fail(403, "read_scope_not_approved")
					return
				}
				c = current
			}
			data, err := j.readPage(c, req, strings.TrimPrefix(r.URL.Path, "/"))
			if err != nil {
				if errors.Is(err, errPageNoProgress) {
					fail(503, "page_no_progress")
					return
				}
				fail(503, "journal_unavailable")
				return
			}
			if refresh != nil {
				data["name_refresh"] = refresh
			}
			encoded, err := marshalBytePage(data)
			if err != nil {
				fail(503, "page_no_progress")
				return
			}
			w.Write(encoded)
		case "/read_field":
			if _, _, err := j.readScope(c, req, ""); err != nil {
				fail(403, "read_scope_not_approved")
				return
			}
			data, err := j.readField(c, req)
			if err != nil {
				var fieldErr *fieldReadError
				if errors.As(err, &fieldErr) {
					w.WriteHeader(fieldErr.status)
					json.NewEncoder(w).Encode(map[string]any{"ok": false, "error": fieldErr.name, "field_version": fieldErr.version, "byte_length": fieldErr.size})
					return
				}
				if errors.Is(err, errPageNoProgress) {
					fail(503, "page_no_progress")
					return
				}
				fail(503, "journal_unavailable")
				return
			}
			encoded, err := json.Marshal(data)
			if err != nil || len(encoded)+1 > 64*1024 {
				fail(503, "field_no_progress")
				return
			}
			w.Write(append(encoded, '\n'))
		case "/send_message":
			fail(403, "general_send_refused_draft_visibility_unsupported")
		case "/download_audio":
			fail(403, "media_is_private_to_deterministic_worker")
		default:
			fail(404, "unknown_operation")
		}
	})
}
func privateTTY() bool {
	return term.IsTerminal(int(os.Stdin.Fd())) && term.IsTerminal(int(os.Stdout.Fd())) && term.IsTerminal(int(os.Stderr.Fd()))
}
func pair(ctx context.Context, a *Adapter) error {
	if !privateTTY() {
		return errors.New("pairing_requires_private_interactive_tty_no_capture")
	}
	if a.client.Store.ID != nil {
		return errors.New("already_paired")
	}
	c, err := a.journal.Config()
	if err != nil {
		return errors.New("pairing_configuration_unavailable")
	}
	ch, err := a.client.GetQRChannel(ctx)
	if err != nil {
		return errors.New("pairing_unavailable")
	}
	if err = a.client.ConnectContext(ctx); err != nil {
		return errors.New("pairing_connection_failed")
	}
	defer fmt.Fprint(os.Stdout, "\033[2J\033[H")
	for {
		select {
		case <-ctx.Done():
			return errors.New("pairing_cancelled")
		case item, ok := <-ch:
			if !ok {
				if ctx.Err() != nil {
					return errors.New("pairing_cancelled")
				}
				return errors.New("pairing_not_confirmed")
			}
			switch item.Event {
			case "code":
				code, err := qrcode.New(item.Code, qrcode.Medium)
				if err != nil {
					return errors.New("qr_render_failed")
				}
				fmt.Fprint(os.Stdout, "\033[2J\033[HScan privately in WhatsApp → Linked devices. Do not record this terminal.\n", code.ToSmallString(false))
			case "success":
				if err := a.completePair(c.Generation); err != nil {
					return a.journal.safePairCompletionError(err)
				}
				return nil // Local pairing only; subsequent OFF serve must prove authenticated login.
			case "timeout", "error", "err-client-outdated", "err-scanned-without-multidevice", "err-unexpected-state":
				return pairingTerminalError(item.Event)
			}
		}
	}
}
func run() error {
	if len(os.Args) < 2 {
		return errors.New("usage: wa-whatsapp init|pair|serve|status|activate|pause|language|scope|release-hold|requeue-held-audio|operator-enable|operator-inspect|reindex --state PRIVATE_DIRECTORY [options]")
	}
	action := os.Args[1]
	f := flag.NewFlagSet(action, flag.ContinueOnError)
	dir := f.String("state", "", "private persistent state directory")
	account := f.String("account", "", "exact PN account JID from operator")
	chats := f.String("chats", "", "comma-separated exact approved chat JIDs")
	allChats := f.Bool("all-chats", false, "explicit owner approval for current and future supported account chats")
	lang := f.String("language", "en", "recognition language en/pt/auto; not translation")
	listen := f.String("listen", "127.0.0.1:8787", "loopback API")
	owners := f.String("owners", "", "shared per-user account fencing directory (default OS user config/wa-whatsapp-owners)")
	python := f.String("python", "", "absolute private Python executable")
	worker := f.String("worker", "", "absolute whatsapp-stt-local.py")
	cache := f.String("models", "", "private preprovisioned model cache")
	ocrPython := f.String("ocr-python", "", "absolute private OCR Python executable (defaults to --python)")
	ocrWorker := f.String("ocr-worker", "", "absolute whatsapp-ocr-local.py (defaults next to the executable)")
	ocrModels := f.String("ocr-models", "", "optional private OCR model cache")
	posting := f.String("set", "", "posting toggle: enable|disable")
	holdChat := f.String("chat", "", "exact chat whose reviewed hold is released")
	holdReason := f.String("reason", "", "operator review reason for the hold release")
	holdConfirm := f.Bool("confirm", false, "confirm the reviewed hold release")
	apply := f.Bool("apply", false, "requeue-held-audio: write the changes (default is a dry run)")
	requeueLimit := f.Int("limit", 0, "requeue-held-audio: requeue at most N newest rows (0 = all)")
	includeLegacy := f.Bool("include-legacy-holds", false, "requeue-held-audio: also requeue audio that arrived after a legacy hold with no recorded target")
	confirm := f.Bool("approve-transcript-posting", false, "explicit original-chat transcript policy approval after retirement check")
	retired := f.String("retirement-receipt", "", "verified operator cutover receipt path")
	intentID := f.String("intent-id", "", "exact durable operator intent ID for offline owner inspection")
	operatorApproved := f.Bool("approve-operator-management", false, "offline owner provisioning of separate selected-chat approval/dispatch credentials")
	if err := f.Parse(os.Args[2:]); err != nil {
		return err
	}
	if *dir == "" || !filepath.IsAbs(*dir) {
		return errors.New("absolute_private_state_required")
	}
	if action == "pair" && !privateTTY() {
		return errors.New("pairing_requires_private_interactive_tty_no_capture")
	}
	j, err := openJournal(*dir)
	if err != nil {
		return err
	}
	defer j.Close()
	if action == "init" {
		if _, err = j.Config(); err == nil {
			return errors.New("already_initialized")
		} else if !errors.Is(err, sql.ErrNoRows) {
			return errors.New("existing_config_unreadable_preserve_state")
		}
		c := Config{Account: *account, Generation: 1, Language: *lang, Chats: splitChats(*chats), AllChats: *allChats, Mode: "transcribe"}
		if err = validConfig(c); err != nil {
			return err
		}
		if !strings.HasSuffix(c.Account, "@s.whatsapp.net") || !validChat(c.Account) {
			return errors.New("exact_account_pn_jid_required")
		}
		token := make([]byte, 32)
		if _, err = rand.Read(token); err != nil {
			return err
		}
		if err = writeNewSecret(filepath.Join(*dir, "api.token"), []byte(hex.EncodeToString(token))); err != nil {
			return err
		}
		return j.save(c)
	}
	c, err := j.Config()
	if err != nil {
		return errors.New("init_required")
	}
	switch action {
	case "operator-inspect":
		if len(*intentID) != 64 {
			return errors.New("operator_exact_intent_id_required")
		}
		i, err := readOperator(j.db, *intentID)
		if err != nil || i.Account != c.Account {
			return errors.New("operator_intent_not_found")
		}
		return json.NewEncoder(os.Stdout).Encode(map[string]any{"ok": true, "intent": i, "offline_owner_inspection": true, "current_generation": c.Generation, "historical": i.Generation != c.Generation, "draft_visibility": "unsupported"})
	case "operator-enable":
		return provisionOperator(j, c, splitChats(*chats), *operatorApproved)
	case "status":
		value, err := j.status()
		if err != nil {
			return err
		}
		return json.NewEncoder(os.Stdout).Encode(value)
	case "scope":
		if !*allChats {
			return errors.New("explicit_all_chats_owner_approval_required")
		}
		c.AllChats = true
		c.Chats = nil
		c.Requested = false
		c.Activated = 0
		return j.save(c)
	case "posting":
		if *posting != "enable" && *posting != "disable" {
			return errors.New("posting_set_enable_or_disable_required")
		}
		c.TranscriptPosting = *posting == "enable"
		return j.save(c)
	case "requeue-held-audio":
		// Offline (the journal owner lock refuses a running service). Dry run unless
		// --apply; counts only, no chat/message IDs. See WHATSAPP-TRANSCRIPTION.md.
		if *requeueLimit < 0 {
			return errors.New("requeue_limit_must_be_non_negative")
		}
		report, err := j.requeueHeldAudio(c, *requeueLimit, *includeLegacy, *apply)
		if err != nil {
			return err
		}
		return json.NewEncoder(os.Stdout).Encode(map[string]any{"ok": true, "report": report, "holds_released": false, "posts_replayed": false})
	case "release-hold":
		if !*holdConfirm {
			return errors.New("explicit_reviewed_hold_release_confirmation_required")
		}
		if err = j.releaseHold(c, *holdChat, *holdReason); err != nil {
			return err
		}
		return json.NewEncoder(os.Stdout).Encode(map[string]any{"ok": true, "chat": *holdChat, "released": true, "replayed": false})
	case "reindex":
		// Re-derive local work a chat hold had fenced: transcripts and OCR text are
		// derives, not effects. The hold, the outbox and every proven per-message
		// fence are untouched, and posting stays refused where it is dispatched.
		if !*holdConfirm {
			return errors.New("explicit_hold_rederive_confirmation_required")
		}
		counts, err := j.rederiveHeldSources(c, *holdChat)
		if err != nil {
			return err
		}
		return json.NewEncoder(os.Stdout).Encode(map[string]any{"ok": true, "rederived": counts, "posted": false, "replayed": false})
	case "pause":
		c.Requested = false
		return j.save(c)
	case "language":
		c.Language = *lang
		return j.save(c)
	case "activate":
		if j.hasGap() {
			return errors.New("persistence_gap_requires_reconciliation")
		}
		if !*confirm || *retired == "" {
			return errors.New("explicit_transcript_approval_and_retirement_receipt_required")
		}
		if err = validateRetirement(*retired, c.Account); err != nil {
			return err
		}
		paired, err := newAdapter(context.Background(), j)
		if err != nil {
			return errors.New("device_store_unavailable")
		}
		identityErr := paired.identity()
		paired.Close()
		if identityErr != nil {
			return identityErr
		}
		// Activation never changes the first cutover. Pauses retain backlog and uncertainty.
		if c.Activated == 0 {
			c.Activated = time.Now().Unix() + 1
		}
		c.Requested = true
		return j.save(c)
	case "pair", "serve":
		ownerRoot, err := os.UserConfigDir()
		if err != nil {
			return errors.New("private_owner_root_unavailable")
		}
		ownerRoot = filepath.Join(ownerRoot, "wa-whatsapp-owners")
		if *owners != "" {
			if !filepath.IsAbs(*owners) {
				return errors.New("absolute_owner_root_required")
			}
			ownerRoot = *owners
		}
		if err = j.fence(ownerRoot, c.Account); err != nil {
			return err
		}
	default:
		return errors.New("unknown_command")
	}
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	a, err := newAdapter(ctx, j)
	if err != nil {
		return errors.New("device_store_unavailable")
	}
	defer a.Close()
	if action == "pair" {
		if c.Requested {
			return errors.New("pause_before_pairing")
		}
		if a.client.Store.ID == nil && c.Activated > 0 {
			c.Generation++
			c.Activated = 0
			if err = j.save(c); err != nil {
				return errors.New("pairing_generation_persistence_failed")
			}
		}
		return pair(ctx, a)
	}
	if err = a.identity(); err != nil {
		j.setState("needs_pairing")
	}
	host, port, err := net.SplitHostPort(*listen)
	if err != nil {
		return errors.New("invalid_listen")
	}
	ip := net.ParseIP(host)
	if ip == nil || !ip.IsLoopback() {
		return errors.New("loopback_only_use_authenticated_https_proxy_for_remote")
	}
	if _, err = strconv.Atoi(port); err != nil {
		return err
	}
	token, err := os.ReadFile(filepath.Join(*dir, "api.token"))
	if err != nil || len(token) != 64 {
		return errors.New("private_api_token_missing")
	}
	listener, err := net.Listen("tcp", *listen)
	if err != nil {
		return err
	}
	authority, err := loadOperatorAuthority(j)
	if err != nil {
		return err
	}
	server := &http.Server{Handler: operatorAPI(j, api(j, string(token)), authority, a), ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 10 * time.Second, WriteTimeout: 30 * time.Second, MaxHeaderBytes: 8192}
	defer server.Close()
	serverErrors := make(chan error, 1)
	go serveAPI(server, listener, ctx, cancel, serverErrors)
	// Warm STT: the main worker loads its model now, not on the first voice note.
	stall := time.Duration(envInt("WA_WHATSAPP_STT_STALL_SECONDS", 0, 10, 3600)) * time.Second
	w := &Worker{Python: *python, Script: *worker, Cache: *cache, Stall: stall}
	defer w.Close()
	go w.Start()
	// Express lane (default on; WA_WHATSAPP_STT_LANES=1 disables): a second warm
	// worker that runs only while the main one decodes long audio, and only takes
	// audio declared <= 90 s. On a 2-core host the two decodes share the CPU while
	// they overlap (the long one slows for that time), and a short voice note lands
	// in seconds instead of after the long one. Costs one more model in RAM.
	var express *Worker
	if envInt("WA_WHATSAPP_STT_LANES", 2, 1, 2) == 2 {
		express = &Worker{Python: *python, Script: *worker, Cache: *cache, Stall: stall}
		defer express.Close()
		go express.Start()
	}
	ocrExe := *ocrPython
	if ocrExe == "" {
		ocrExe = *python
	}
	ocrScript := *ocrWorker
	if ocrScript == "" {
		if exe, e := os.Executable(); e == nil {
			ocrScript = filepath.Join(filepath.Dir(exe), "whatsapp-ocr-local.py")
		}
	}
	o := &OCRWorker{Python: ocrExe, Script: ocrScript, Cache: *ocrModels}
	defer o.Close()
	var workers sync.WaitGroup
	workers.Add(3)
	defer func() { cancel(); workers.Wait() }()
	// Audio lanes are event-driven: ingest wakes them the moment a pending task
	// commits, and each drains its queue before sleeping. The 10 s tick is only a
	// safety net (backoff expiry, reconnect, a missed wake).
	audioLoop := func(lane audioLane, rec Recognizer) {
		defer workers.Done()
		wake := j.audioSignal()
		ticker := time.NewTicker(10 * time.Second)
		defer ticker.Stop()
		for {
			for ctx.Err() == nil && a.client.IsConnected() {
				worked, err := j.processAudioLane(ctx, a, rec, lane)
				if err != nil {
					j.setState("degraded_compute_journal")
				}
				if err != nil || !worked {
					break
				}
			}
			select {
			case <-ctx.Done():
				return
			case <-wake:
			case <-ticker.C:
			}
		}
	}
	go audioLoop(mainLane, w)
	if express != nil {
		workers.Add(1)
		go audioLoop(audioLane{Express: true, MaxSeconds: expressSeconds, Work: "audio-work-express"}, express)
	}
	go func() {
		defer workers.Done()
		wake := j.postSignal()
		ticker := time.NewTicker(time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-wake:
			case <-ticker.C:
			}
			if a.client.IsConnected() {
				if err := j.post(ctx, a); err != nil {
					j.setState("degraded_post_journal")
				}
			}
		}
	}()
	go func() {
		defer workers.Done()
		ticker := time.NewTicker(time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				if a.client.IsConnected() {
					if err := j.processMedia(ctx, a, o); err != nil {
						j.setState("degraded_media_journal")
					}
				}
			}
		}
	}()
	if a.client.Store.ID == nil {
		j.setState("needs_pairing")
	} else if !a.eventIdentity() {
		// identityResult retains needs_pairing vs actual account mismatch.
	} else {
		j.setState("reconnecting")
		if err = a.client.ConnectContext(ctx); err != nil {
			j.setState("reconnecting")
			j.event("connect_failed", "will reconnect; no protocol errors logged")
		}
	}
	// Explicit reconnect handles initial connection failure too. No inference/scheduler required.
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			select {
			case err := <-j.fatal:
				return err
			default:
			}
			select {
			case err := <-serverErrors:
				return err
			default:
				return nil
			}
		case err := <-j.fatal:
			return err
		case <-ticker.C:
			if a.client.Store.ID == nil {
				j.setState("needs_pairing")
				continue
			}
			if !a.eventIdentity() {
				continue
			}
			if !a.client.IsConnected() {
				a.client.ConnectContext(ctx)
			}
		}
	}
}
func validateRetirement(path, account string) error {
	b, err := os.ReadFile(path)
	if err != nil {
		return errors.New("retirement_receipt_unreadable")
	}
	var r struct {
		Schema            int    `json:"schema"`
		Account           string `json:"account"`
		LegacyDisabled    bool   `json:"legacy_disabled"`
		UnknownsPreserved bool   `json:"unknowns_preserved"`
		IdentityVerified  bool   `json:"identity_verified"`
	}
	if json.Unmarshal(b, &r) != nil || r.Schema != 1 || r.Account != account || !r.LegacyDisabled || !r.UnknownsPreserved || !r.IdentityVerified {
		return errors.New("retirement_not_verified")
	}
	return nil
}
func writeNewSecret(path string, data []byte) error {
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return err
	}
	defer file.Close()
	if _, err = file.Write(data); err != nil {
		return err
	}
	return file.Sync()
}
func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err.Error())
		if errors.Is(err, errGapMarker) {
			os.Exit(78)
		}
		os.Exit(1)
	}
}

// envInt reads a bounded integer knob; unset or invalid keeps the default.
func envInt(name string, def, low, high int) int {
	v, err := strconv.Atoi(os.Getenv(name))
	if err != nil {
		return def
	}
	return min(max(v, low), high)
}
