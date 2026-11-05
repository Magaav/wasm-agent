//go:build wasip1

// Package hostsock is a net.Conn over host-provided TCP: the guest has no sockets of its own
// (wasip1), so the host opens exactly the granted addresses and the guest reads/writes through
// imports. Reads are non-blocking on the host side; the guest yields (time.Sleep) on EAGAIN so the
// Go scheduler keeps every other goroutine (keepalives, timers) running.
package hostsock

import (
	"context"
	"errors"
	"io"
	"net"
	"time"
	"unsafe"
)

//go:wasmimport wa_sock connect
func hostConnect(addr unsafe.Pointer, addrLen uint32) int32

//go:wasmimport wa_sock read
func hostRead(h int32, buf unsafe.Pointer, n uint32) int32

//go:wasmimport wa_sock write
func hostWrite(h int32, buf unsafe.Pointer, n uint32) int32

//go:wasmimport wa_sock close
func hostClose(h int32) int32

const eagain = -11

type Conn struct {
	h        int32
	addr     string
	deadline time.Time
}

func Dial(ctx context.Context, network, addr string) (net.Conn, error) {
	b := []byte(addr)
	h := hostConnect(unsafe.Pointer(&b[0]), uint32(len(b)))
	if h < 0 {
		return nil, errors.New("hostsock_connect_refused:" + addr)
	}
	return &Conn{h: h, addr: addr}, nil
}

func (c *Conn) Read(p []byte) (int, error) {
	if len(p) == 0 {
		return 0, nil
	}
	for {
		n := hostRead(c.h, unsafe.Pointer(&p[0]), uint32(len(p)))
		switch {
		case n > 0:
			return int(n), nil
		case n == 0:
			return 0, io.EOF
		case n == eagain:
			if !c.deadline.IsZero() && time.Now().After(c.deadline) {
				return 0, timeoutError{}
			}
			time.Sleep(2 * time.Millisecond)
		default:
			return 0, errors.New("hostsock_read_failed")
		}
	}
}

func (c *Conn) Write(p []byte) (int, error) {
	done := 0
	for done < len(p) {
		n := hostWrite(c.h, unsafe.Pointer(&p[done]), uint32(len(p)-done))
		switch {
		case n > 0:
			done += int(n)
		case n == eagain:
			time.Sleep(2 * time.Millisecond)
		default:
			return done, errors.New("hostsock_write_failed")
		}
	}
	return done, nil
}

func (c *Conn) Close() error                       { hostClose(c.h); return nil }
func (c *Conn) LocalAddr() net.Addr                { return addr("guest") }
func (c *Conn) RemoteAddr() net.Addr               { return addr(c.addr) }
func (c *Conn) SetDeadline(t time.Time) error      { c.deadline = t; return nil }
func (c *Conn) SetReadDeadline(t time.Time) error  { c.deadline = t; return nil }
func (c *Conn) SetWriteDeadline(t time.Time) error { return nil }

type addr string

func (a addr) Network() string { return "tcp" }
func (a addr) String() string  { return string(a) }

type timeoutError struct{}

func (timeoutError) Error() string   { return "i/o timeout" }
func (timeoutError) Timeout() bool   { return true }
func (timeoutError) Temporary() bool { return true }
