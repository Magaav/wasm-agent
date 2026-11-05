//go:build wasip1

// Spike: TLS + websocket to WhatsApp's real endpoint from a wasip1 guest, through host sockets,
// with the exact dial path whatsmeow uses (coder/websocket over an http.Client).
package main

import (
	"context"
	"fmt"
	"net/http"
	"time"

	"github.com/coder/websocket"
	_ "golang.org/x/crypto/x509roots/fallback" // wasip1 has no system roots: bundled Mozilla roots, verification stays on
	"wmprobe/hostsock"
)

func main() {
	client := &http.Client{Transport: &http.Transport{DialContext: hostsock.Dial, ForceAttemptHTTP2: false}}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	started := time.Now()
	conn, resp, err := websocket.Dial(ctx, "wss://web.whatsapp.com/ws/chat", &websocket.DialOptions{
		HTTPClient: client,
		HTTPHeader: http.Header{"Origin": []string{"https://web.whatsapp.com"}},
	})
	if err != nil {
		status := 0
		if resp != nil {
			status = resp.StatusCode
		}
		fmt.Printf("DIAL_FAILED status=%d err=%v ms=%d\n", status, err, time.Since(started).Milliseconds())
		return
	}
	fmt.Printf("WEBSOCKET_OPEN status=%d proto=%s ms=%d\n", resp.StatusCode, resp.Proto, time.Since(started).Milliseconds())
	conn.Close(websocket.StatusNormalClosure, "spike")
}
