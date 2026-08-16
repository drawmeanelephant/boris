#!/usr/bin/env python3
"""Boris conformance mock relay over TLS (wss://), used by the #496 matrix.

A deliberately small RFC-6455 server bound to 127.0.0.1: it accepts the
publish handshake over TLS, answers every EVENT with an honest OK, answers
Ping with Pong, and exits after serving one connection (the publish client
opens exactly one). Test-only scaffolding; never run against real traffic.

Usage: nostr-mock-relay-tls.py PORT CERTFILE KEYFILE PORTFILE

The bound port is written to PORTFILE right after bind so the Zig test can
learn it without racing the accept. TLS handshake failures (e.g. the
hostname-mismatch negative test, where the client aborts with an alert) are
swallowed and the relay keeps accepting until killed.
"""

import base64
import hashlib
import json
import socket
import ssl
import struct
import sys

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def recv_exact(conn, n):
    data = b""
    while len(data) < n:
        chunk = conn.recv(n - len(data))
        if not chunk:
            raise EOFError("eof")
        data += chunk
    return data


def read_http_request(conn):
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = conn.recv(4096)
        if not chunk:
            raise EOFError("eof")
        buf += chunk
        if len(buf) > 65536:
            raise ValueError("request too large")
    return buf


def read_frame(conn):
    header = recv_exact(conn, 2)
    fin = bool(header[0] & 0x80)
    opcode = header[0] & 0x0F
    length = header[1] & 0x7F
    if length == 126:
        (length,) = struct.unpack(">H", recv_exact(conn, 2))
    elif length == 127:
        (length,) = struct.unpack(">Q", recv_exact(conn, 8))
    mask = recv_exact(conn, 4)
    payload = bytearray(recv_exact(conn, length))
    for i in range(length):
        payload[i] ^= mask[i % 4]
    return fin, opcode, bytes(payload)


def send_frame(conn, opcode, payload=b""):
    header = bytes([0x80 | opcode])
    n = len(payload)
    if n < 126:
        header += bytes([n])
    elif n < 65536:
        header += bytes([126]) + struct.pack(">H", n)
    else:
        header += bytes([127]) + struct.pack(">Q", n)
    conn.sendall(header + payload)


def serve(conn):
    request = read_http_request(conn)
    key = None
    for line in request.split(b"\r\n")[1:]:
        if b":" not in line:
            continue
        name, _, value = line.partition(b":")
        if name.strip().lower() == b"sec-websocket-key":
            key = value.strip()
    if key is None:
        raise ValueError("no sec-websocket-key")
    accept = base64.b64encode(hashlib.sha1(key + GUID.encode()).digest())
    conn.sendall(
        b"HTTP/1.1 101 Switching Protocols\r\n"
        b"Upgrade: websocket\r\n"
        b"Connection: Upgrade\r\n"
        b"Sec-WebSocket-Accept: " + accept + b"\r\n\r\n"
    )

    while True:
        fin, opcode, payload = read_frame(conn)
        if opcode == 0x8:  # close
            return
        if opcode == 0x9:  # ping
            send_frame(conn, 0xA, payload)
            continue
        if opcode == 0x1:  # text, possibly fragmented (RFC 6455 requires
            # servers to accept fragmented client messages)
            buf = bytearray(payload)
            while not fin:
                fin, opcode, chunk = read_frame(conn)
                if opcode != 0x0:  # continuation expected
                    return
                buf += chunk
            try:
                event = json.loads(bytes(buf).decode("utf-8"))
            except (ValueError, UnicodeDecodeError):
                return
            if not isinstance(event, list) or len(event) < 2:
                return
            event_obj = event[1]
            event_id = event_obj.get("id") if isinstance(event_obj, dict) else None
            if event_id:
                send_frame(conn, 0x1, json.dumps(["OK", event_id, True, ""]).encode())


def main():
    port = int(sys.argv[1])
    certfile, keyfile, portfile = sys.argv[2], sys.argv[3], sys.argv[4]

    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(certfile, keyfile)

    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as srv:
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind(("127.0.0.1", port))
        srv.listen(5)
        with open(portfile, "w") as f:
            f.write(str(srv.getsockname()[1]))

        while True:
            raw, _ = srv.accept()
            try:
                conn = ctx.wrap_socket(raw, server_side=True)
            except (ssl.SSLError, OSError):
                raw.close()
                continue  # e.g. the hostname-mismatch test: client aborts TLS
            try:
                serve(conn)
            except (EOFError, OSError, ssl.SSLError):
                pass
            finally:
                try:
                    conn.close()
                except OSError:
                    pass
            return  # one publish session, then done


if __name__ == "__main__":
    main()
