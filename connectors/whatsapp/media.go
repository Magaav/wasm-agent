package main

import (
	"context"
	"errors"
	"go.mau.fi/whatsmeow"
	"io"
	"net/http"
	"os"
	"time"
)

const maxAudioBytes int64 = 20 * 1024 * 1024
const maxEncryptedAudioBytes int64 = maxAudioBytes + 16 + 10 // PKCS#7 full AES block + upstream truncated MAC
type cappedBody struct {
	io.ReadCloser
	left int64
}

func (b *cappedBody) Read(p []byte) (int, error) {
	if len(p) == 0 {
		return 0, nil
	}
	if b.left == 0 {
		var probe [1]byte
		n, err := b.ReadCloser.Read(probe[:])
		if n > 0 {
			return 0, permanentError("audio_too_large")
		}
		return 0, err
	}
	if int64(len(p)) > b.left {
		p = p[:b.left]
	}
	n, err := b.ReadCloser.Read(p)
	b.left -= int64(n)
	return n, err
}

type mediaTransport struct {
	base http.RoundTripper
	max  int64
}

func (t mediaTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	response, err := t.base.RoundTrip(r)
	if err != nil {
		return nil, err
	}
	if response.ContentLength > t.max {
		response.Body.Close()
		return nil, permanentError("audio_too_large")
	}
	response.Body = &cappedBody{ReadCloser: response.Body, left: t.max}
	return response, nil
}
func mediaHTTPClient(timeout time.Duration, max int64) *http.Client {
	return &http.Client{Timeout: timeout, Transport: mediaTransport{base: http.DefaultTransport, max: max}, CheckRedirect: func(*http.Request, []*http.Request) error { return errors.New("media_redirect_refused") }}
}

const mediaDeadline = 90 * time.Second

// Deliberately NOT embedding os.File: promoted ReaderFrom would bypass the bounded Write.
type boundedFile struct {
	f   *os.File
	max int64
}

func (b *boundedFile) Read(p []byte) (int, error)              { return b.f.Read(p) }
func (b *boundedFile) ReadAt(p []byte, off int64) (int, error) { return b.f.ReadAt(p, off) }
func (b *boundedFile) Stat() (os.FileInfo, error)              { return b.f.Stat() }
func (b *boundedFile) Seek(off int64, whence int) (int64, error) {
	current, err := b.f.Seek(0, io.SeekCurrent)
	if err != nil {
		return 0, err
	}
	target := off
	if whence == io.SeekCurrent {
		target = current + off
	} else if whence == io.SeekEnd {
		stat, e := b.f.Stat()
		if e != nil {
			return 0, e
		}
		target = stat.Size() + off
	} else if whence != io.SeekStart {
		return 0, errors.New("invalid_media_seek")
	}
	if target < 0 || target > b.max {
		return 0, permanentError("audio_too_large")
	}
	return b.f.Seek(target, io.SeekStart)
}
func (b *boundedFile) Write(p []byte) (int, error) {
	off, err := b.f.Seek(0, io.SeekCurrent)
	if err != nil {
		return 0, err
	}
	if off < 0 || off > b.max || int64(len(p)) > b.max-off {
		return 0, permanentError("audio_too_large")
	}
	return b.f.Write(p)
}
func (b *boundedFile) WriteAt(p []byte, off int64) (int, error) {
	if off < 0 || off > b.max || int64(len(p)) > b.max-off {
		return 0, permanentError("audio_too_large")
	}
	return b.f.WriteAt(p, off)
}
func (b *boundedFile) Truncate(n int64) error {
	if n < 0 || n > b.max {
		return permanentError("audio_too_large")
	}
	return b.f.Truncate(n)
}

type sizedMedia interface {
	whatsmeow.DownloadableMessage
	GetFileLength() uint64
}

func boundedMedia(ctx context.Context, dir string, msg sizedMedia, download func(context.Context, whatsmeow.DownloadableMessage, whatsmeow.File) error, timeout time.Duration) ([]byte, error) {
	if msg.GetFileLength() > uint64(maxAudioBytes) {
		return nil, permanentError("audio_too_large")
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	file, err := os.CreateTemp(dir, "media-private-*")
	if err != nil {
		return nil, err
	}
	defer os.Remove(file.Name())
	defer file.Close()
	if err = file.Chmod(0600); err != nil {
		return nil, err
	}
	bounded := &boundedFile{f: file, max: maxEncryptedAudioBytes}
	// Upstream performs encrypted SHA256, MAC, streaming AES-CBC, and plaintext SHA256 checks.
	if err = download(ctx, msg, bounded); err != nil {
		return nil, err
	}
	if err = ctx.Err(); err != nil {
		return nil, err
	}
	stat, err := file.Stat()
	if err != nil {
		return nil, err
	}
	if stat.Size() > maxAudioBytes {
		return nil, permanentError("audio_too_large")
	}
	if declared := msg.GetFileLength(); declared > 0 && uint64(stat.Size()) != declared {
		return nil, permanentError("audio_declared_size_mismatch")
	}
	if _, err = file.Seek(0, io.SeekStart); err != nil {
		return nil, err
	}
	data := make([]byte, int(stat.Size()))
	_, err = io.ReadFull(file, data)
	return data, err
}
