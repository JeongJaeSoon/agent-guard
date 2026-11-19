#!/usr/bin/env python3
"""A misbehaving stand-in for agent-guard-gitleaks-helper (tests/gitleaks-helper.sh).

Listens on SOCKET and answers every connection the way MODE says, so the
scan client's handling of a broken helper can be checked without patching
the real one. Modes:

  close       accept and close at once (helper died before answering)
  truncate    read the request, send half of a clean answer, close
  hang        read the request and never answer (client timeout)
  garbage     answer with bytes that are not a frame
  clean       a complete, well-formed "ok, exit 0" answer
  badexit     a complete "ok" answer with an exit code the request did not ask for
  noreport    a complete "ok" answer with no report although one was requested
  fallback    a complete "fallback" answer
  otheruid    (root only) listen as uid 65534, then answer clean

A complete "clean" answer is used by the cases that check what the client
does when it must not trust it (wrong peer). Prints "ready" once listening.
"""
import json
import os
import socket
import struct
import sys
import time

MAGIC = b"AGGL\x01"


def frame(header, *blobs):
    data = json.dumps(header).encode()
    return MAGIC + struct.pack(">I", len(data)) + data + b"".join(blobs)


def read_request(conn):
    def exact(n):
        out = b""
        while len(out) < n:
            chunk = conn.recv(n - len(out))
            if not chunk:
                raise EOFError
            out += chunk
        return out

    prefix = exact(9)
    header = json.loads(exact(struct.unpack(">I", prefix[5:])[0]))
    exact(header.get("payload_len", 0))
    return header


def clean_answer(request, exit_code=0, report=True):
    blob = b"[]\n" if request.get("report_format") == "json" and report else b""
    return frame({"status": "ok", "exit_code": exit_code, "stdout_len": 0,
                  "stderr_len": 0, "report_len": len(blob)}, blob)


def main():
    path, mode = sys.argv[1], sys.argv[2]
    if os.path.exists(path):
        os.unlink(path)
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(path)
    if mode == "otheruid":
        # Let the test user connect, so the peer uid check is what refuses.
        os.chmod(path, 0o666)
        os.setgid(65534)
        os.setuid(65534)
    server.listen(16)
    print("ready", flush=True)
    while True:
        conn, _ = server.accept()
        try:
            if mode == "close":
                conn.close()
                continue
            if mode == "garbage":
                conn.sendall(b"not a frame at all\n")
                conn.close()
                continue
            request = read_request(conn)
            if mode == "truncate":
                answer = clean_answer(request)
                conn.sendall(answer[: len(answer) // 2])
            elif mode == "hang":
                time.sleep(30)
            elif mode in ("clean", "otheruid"):
                conn.sendall(clean_answer(request))
            elif mode == "badexit":
                conn.sendall(clean_answer(request, exit_code=7))
            elif mode == "noreport":
                conn.sendall(clean_answer(request, report=False))
            elif mode == "fallback":
                conn.sendall(frame({"status": "fallback", "reason": "scan", "exit_code": 0,
                                    "stdout_len": 0, "stderr_len": 0, "report_len": 0}))
        except (EOFError, OSError, ValueError):
            pass
        finally:
            conn.close()


if __name__ == "__main__":
    main()
