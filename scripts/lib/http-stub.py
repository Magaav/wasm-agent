#!/usr/bin/env python3
"""A local stub HTTP server for the asset-download rows (scripts/test-node-download.sh).

    python3 scripts/lib/http-stub.py <root-dir> <port-file>

It lives HERE, beside release-fixture-sign.py, and not under tests/: a fixture that a runner can execute is a
TEST to scripts/test-discriminates.sh (anything under tests/ with a runner extension), and this file has no
verdict of its own - it would be run against the base with no arguments and reported unclassified, blocking a
landing over a fact about the harness. It is a fixture: one test starts it and talks to it.

No network: it binds 127.0.0.1:0 and writes the chosen port into a file. It serves whatever files the caller
put in its root directory, and the BEHAVIOUR OF ONE FILE is chosen by SIDECAR FILES beside it, so one base
URL serves every row at once and the rows go through the real downloader (there is no mode in the URL):

  <name>.rate      the body is paced to that many bytes per second (the 55 MB / 300 kB/s row)
  <name>.drop      the connection is closed after that fraction of the body ONCE: a request that carries a
                   Range header then gets the rest, which is what makes the resume row measurable
  <name>.stall     that many bytes are sent and then nothing for ten minutes - the stall row
  <name>.corrupt   one byte in the last 40% of the body is flipped in what is SENT (the file on disk, and so
                   its sha256, is untouched) - the row where a resumed body does not match the manifest

Every request is appended to <root>/requests.log as `<path> <Range header or ->`, so "a 404 is requested
once" and "a dropped transfer is resumed with -C -" are counted rather than assumed.
"""
import http.server
import os
import socket
import sys
import time
from urllib.parse import urlparse

ROOT = sys.argv[1]
PORT_FILE = sys.argv[2]
LOG = os.path.join(ROOT, "requests.log")
CHUNK = 65536


def log(line):
    with open(LOG, "a", encoding="utf-8") as handle:
        handle.write(line + "\n")


def sidecar(path, suffix):
    name = path + suffix
    if not os.path.isfile(name):
        return None
    with open(name, encoding="utf-8") as handle:
        return handle.read().strip()


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"

    def log_message(self, *args):
        pass

    def fail(self, code, body=b"stub refusal\n"):
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self):
        parts = [p for p in urlparse(self.path).path.split("/") if p]
        name = "/".join(parts)
        rng = self.headers.get("Range")
        log("%s %s" % (name or "-", rng or "-"))
        path = os.path.join(ROOT, name)
        if not name or not os.path.isfile(path):
            return self.fail(404)
        total = os.path.getsize(path)
        start = 0
        if rng and rng.startswith("bytes="):
            try:
                start = int(rng[6:].split("-")[0] or 0)
            except ValueError:
                return self.fail(400)
        if start >= total:
            return self.fail(416)
        drop = None if rng else sidecar(path, ".drop")
        stall = sidecar(path, ".stall")
        corrupt = sidecar(path, ".corrupt") is not None
        rate = sidecar(path, ".rate")
        # THE WHOLE REMAINING BODY IS ANNOUNCED, always: a dropped connection and a stall both send less
        # than this, which is exactly what makes curl report a short read (exit 18) or a speed-window
        # timeout (exit 28) instead of a body that ended where its header said it would.
        length = total - start
        send = length
        if drop is not None:
            send = max(1, int(total * float(drop)))
        if stall is not None:
            send = min(send, int(stall))
        if start:
            self.send_response(206)
            self.send_header("Content-Range", "bytes %d-%d/%d" % (start, total - 1, total))
        else:
            self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(length))
        self.end_headers()
        flip_at = start + max(0, int(total * 0.6) - start) if corrupt else None
        sent = 0
        try:
            with open(path, "rb") as handle:
                handle.seek(start)
                while sent < send:
                    piece = handle.read(min(CHUNK, send - sent))
                    if not piece:
                        break
                    if flip_at is not None and start + sent <= flip_at < start + sent + len(piece):
                        offset = flip_at - (start + sent)
                        flipped = bytearray(piece)
                        flipped[offset] = (flipped[offset] + 1) % 256
                        piece = bytes(flipped)
                    self.wfile.write(piece)
                    self.wfile.flush()
                    sent += len(piece)
                    if rate:
                        time.sleep(len(piece) / float(rate))
        except (BrokenPipeError, ConnectionResetError):
            return
        if stall is not None:
            # NOTHING FOR TEN MINUTES: the downloader's --speed-time is what must end this.
            time.sleep(600)
        elif drop is not None:
            self.close_connection = True
            try:
                self.connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    with open(LOG, "a", encoding="utf-8"):
        pass
    server = Server(("127.0.0.1", 0), Handler)
    with open(PORT_FILE, "w", encoding="utf-8") as handle:
        handle.write(str(server.server_address[1]))
    try:
        server.serve_forever(poll_interval=0.1)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
