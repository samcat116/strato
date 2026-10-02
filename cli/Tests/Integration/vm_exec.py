#!/usr/bin/env python3
"""Exercise the built CLI against a loopback HTTP/WebSocket fixture (no VM).

Run after swift test: python3 cli/Tests/Integration/vm_exec.py cli/.build/debug/strato
Only Python's standard library is required. Credentials are inert test fixtures.
"""
import base64
import fcntl
import hashlib
import http.server
import json
import os
import pathlib
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time


class Fixture(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, mode="pipe", refusal=None, resource="vm"):
        self.resource = resource
        self.resource_path = "vms/vm-test" if resource == "vm" else "sandboxes/vm-test"
        super().__init__(("127.0.0.1", 0), Handler)
        self.mode, self.refusal = mode, refusal
        self.minted = None
        self.frames = []
        self.ready = threading.Event()
        self.closed = threading.Event()
        self.resized = threading.Event()
        self.errors = []
        threading.Thread(target=self.serve_forever, daemon=True).start()


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def do_POST(self):
        try:
            assert self.path == f"/api/{self.server.resource_path}/exec", self.path
            assert self.headers["Authorization"] == "Bearer fixture-token"
            self.server.minted = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            if self.server.refusal:
                status, reason = self.server.refusal
                body = {"error": True, "reason": reason}
            else:
                status = 201
                body = {"sessionId": "test", "websocketPath": f"/api/{self.server.resource_path}/exec/test/attach",
                        "expiresAt": "2099-01-01T00:00:00Z", "outputMode": self.server.minted["outputMode"]}
            data = json.dumps(body).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        except Exception as exc:
            self.server.errors.append(exc)
            raise

    def send_frame(self, data, opcode=1):
        if isinstance(data, str):
            data = data.encode()
        assert len(data) < 126
        self.connection.sendall(bytes([0x80 | opcode, len(data)]) + data)

    def read_exact(self, count):
        result = b""
        while len(result) < count:
            data = self.rfile.read(count - len(result))
            if not data:
                raise EOFError()
            result += data
        return result

    def read_frame(self):
        header = self.read_exact(2)
        length = header[1] & 127
        if length == 126:
            length = struct.unpack("!H", self.read_exact(2))[0]
        elif length == 127:
            length = struct.unpack("!Q", self.read_exact(8))[0]
        mask = self.read_exact(4) if header[1] & 128 else None
        data = self.read_exact(length)
        if mask:
            data = bytes(value ^ mask[i % 4] for i, value in enumerate(data))
        return header[0] & 15, data

    def do_GET(self):
        try:
            assert self.path == f"/api/{self.server.resource_path}/exec/test/attach"
            assert self.headers["Authorization"] == "Bearer fixture-token"
            key = self.headers["Sec-WebSocket-Key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
            self.send_response(101)
            self.send_header("Upgrade", "websocket")
            self.send_header("Connection", "Upgrade")
            self.send_header("Sec-WebSocket-Accept", base64.b64encode(hashlib.sha1(key.encode()).digest()).decode())
            self.end_headers()
            self.send_frame('{"type":"ready"}')
            self.server.ready.set()
            if self.server.mode == "disconnect":
                self.send_frame(b"", 8)
                return
            if self.server.mode == "guest-error":
                self.send_frame('{"type":"error","message":"VM guest agent unreachable"}')
            while True:
                opcode, data = self.read_frame()
                if opcode == 8:
                    self.send_frame(data, 8)
                    break
                self.server.frames.append((opcode, data))
                if opcode == 1:
                    control = json.loads(data)
                    if control["type"] == "resize":
                        self.server.resized.set()
                    if control["type"] == "stdin_eof" and self.server.mode == "pipe":
                        self.send_frame(b"\x01out\n", 2)
                        self.send_frame(b"\x02err\n", 2)
                        self.send_frame('{"type":"exit","exitCode":37}')
        except (EOFError, BrokenPipeError, ConnectionResetError):
            pass
        except Exception as exc:
            self.server.errors.append(exc)
        finally:
            self.close_connection = True
            self.server.closed.set()


def launch(binary, fixture, directory, args, **kwargs):
    config = pathlib.Path(directory) / "strato"
    config.mkdir(exist_ok=True)
    (config / "credentials.json").write_text(json.dumps({"default": {
        "accessToken": "fixture-token", "refreshToken": "fixture-refresh"}}))
    env = dict(os.environ, XDG_CONFIG_HOME=directory)
    return subprocess.Popen([binary, fixture.resource, "exec", "vm-test", "--server",
                             f"http://127.0.0.1:{fixture.server_port}", *args], env=env, **kwargs)


def check(binary):
    with tempfile.TemporaryDirectory(prefix="strato-vm-exec-") as directory:
        for resource in ["vm", "sandbox"]:
            for attempt in range(2):
                fixture = Fixture(resource=resource)
                process = launch(binary, fixture, directory, ["--env", "A=one=two", "--workdir", "/tmp", "--", "sh", "-c", "cat | wc -c"],
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                out, err = process.communicate(b"piped input", timeout=10)
                assert (process.returncode, out, err) == (37, b"out\n", b"err\n"), (process.returncode, out, err)
                assert fixture.minted["command"] == ["sh", "-c", "cat | wc -c"]
                assert fixture.minted["env"] == {"A": "one=two"}
                assert fixture.minted["workingDir"] == "/tmp"
                assert fixture.minted["tty"] is False
                assert b"".join(data for opcode, data in fixture.frames if opcode == 2) == b"piped input"
                assert fixture.closed.wait(3) and not fixture.errors
                fixture.shutdown()
                print(f"PASS: {resource} session {attempt + 1}: immediate ready, pipe I/O, exit, close")

        fixture = Fixture("terminal")
        master, slave = os.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
        before = termios.tcgetattr(slave)
        process = launch(binary, fixture, directory, [], stdin=slave, stdout=slave, stderr=subprocess.PIPE)
        assert fixture.ready.wait(10)
        assert fixture.minted["command"] == ["/bin/sh"] and fixture.minted["tty"] is True
        assert (fixture.minted["rows"], fixture.minted["cols"]) == (24, 80)
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
        process.send_signal(signal.SIGWINCH)
        assert fixture.resized.wait(3)
        assert any(op == 1 and json.loads(data) == {"type": "resize", "rows": 40, "cols": 120}
                   for op, data in fixture.frames)
        os.write(master, b"\x03")
        time.sleep(0.1)
        assert process.poll() is None  # Ctrl-C must remain guest input in raw mode.
        process.terminate()
        process.communicate(timeout=30)
        assert process.returncode in (-signal.SIGTERM, 128 + signal.SIGTERM), (process.returncode, fixture.errors)
        assert termios.tcgetattr(slave) == before
        assert fixture.closed.wait(3) and not fixture.errors
        os.close(master)
        os.close(slave)
        fixture.shutdown()
        print("PASS: default shell, PTY dimensions/resize, guest Ctrl-C, SIGTERM cleanup/restoration")

        for resource in ["vm", "sandbox"]:
            for mode in (["disconnect", "guest-error", "interrupt"] if resource == "vm"
                         else ["disconnect", "guest-error"]):
                fixture = Fixture(mode, resource=resource)
                process = launch(binary, fixture, directory, ["--", "sleep", "30"],
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                assert fixture.ready.wait(10)
                if mode == "interrupt":
                    process.send_signal(signal.SIGINT)
                out, err = process.communicate(timeout=30)
                if mode == "interrupt":
                    assert process.returncode in (-signal.SIGINT, 128 + signal.SIGINT), (process.returncode, err)
                else:
                    assert process.returncode != 0
                    if mode == "disconnect":
                        assert b"Guest exec WebSocket" in err and any(
                            message in err for message in [b"without an exit status", b"closed", b"send failed"]), err
                    else:
                        assert b"VM guest agent unreachable" in err, err
                assert fixture.closed.wait(3) and not fixture.errors
                fixture.shutdown()
                print(f"PASS: {resource} {mode} failure/cleanup")

        for status, reason in [(400, "VM must be running to exec. Current state: Stopped"),
                               (400, "VM exec requires a VM created with the Strato guest agent enabled"),
                               (403, "Forbidden: vm:exec")]:
            fixture = Fixture(refusal=(status, reason))
            process = launch(binary, fixture, directory, ["--", "true"], stdin=subprocess.DEVNULL,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            out, err = process.communicate(timeout=30)
            assert process.returncode != 0 and reason.encode() in err and not fixture.ready.is_set(), err
            assert not fixture.errors
            fixture.shutdown()
        print("PASS: stopped VM, disabled guest agent, and authorization refusal messages")


if __name__ == "__main__":
    check(str(pathlib.Path(sys.argv[1]).resolve()))
