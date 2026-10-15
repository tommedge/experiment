#!/usr/bin/env python3
"""Real QUIC/PTY checks; optionally include both Rust/Zig interoperability directions."""

import argparse
import contextlib
import fcntl
import json
import os
from pathlib import Path
import pty
import re
import select
import signal
import socket
import struct
import subprocess
import tempfile
import termios
import time

ROOT = Path(__file__).resolve().parents[1]


@contextlib.contextmanager
def server(binary, directory, extra=(), env=None):
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.bind(("127.0.0.1", 0))
        address = f"127.0.0.1:{sock.getsockname()[1]}"
    state = Path(directory) / "state"
    with (Path(directory) / "server.log").open("w+") as log:
        process = subprocess.Popen(
            [str(binary), "serve", "--bind", address, "--state", str(state), *extra],
            stdout=log, stderr=log, env=env,
        )
        try:
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                log.seek(0)
                if "listening on" in log.read():
                    break
                assert process.poll() is None, "server failed to start"
                time.sleep(0.02)
            else:
                raise AssertionError("server startup timed out")
            yield address, state
        finally:
            process.send_signal(signal.SIGINT)
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
                raise
            log.seek(0)
            output = log.read()
            assert process.returncode == 0, output
            assert "memory address" not in output and "leaked" not in output, output


def connection(binary, address, state, tailscale=False):
    return [str(binary), "--server", address, "--cert", str(state / "cert.der"),
            *(["--tailscale"] if tailscale else ["--token-file", str(state / "token")])]


def command(base, name, *args, success=True):
    result = subprocess.run([base[0], name, *base[1:], *args], capture_output=True, timeout=16)
    assert (result.returncode == 0) == success, result.stderr.decode(errors="replace")
    assert b"leaked" not in result.stderr, result.stderr
    return result


def session_id(result):
    return re.search(rb"session=(\d+)", result.stderr)[1].decode()


def matrix(server_binary, client_binary):
    with tempfile.TemporaryDirectory(prefix="multiplexer-e2e-") as directory:
        with server(server_binary, directory) as (address, state):
            base = connection(client_binary, address, state)
            assert command(base, "list").stdout == b""
            first = command(base, "new", "--headless", "--cols", "25", "--rows", "6",
                            "--timeout", "5", "--send", "stty -echo; printf 'native %s\\n' works\n",
                            "--expect", "native works")
            assert int(re.search(rb"datagrams=(\d+)", first.stderr)[1]) > 0, first.stderr
            sid = session_id(first)
            assert command(base, "list").stdout == (sid + "\n").encode()
            again = command(base, "attach", sid, "--headless", "--cols", "25", "--rows", "6",
                            "--expect", "native works", "--timeout", "3")
            assert session_id(again) == sid
            resized = command(base, "attach", sid, "--headless", "--cols", "103", "--rows", "31",
                              "--send", "stty size; printf 'resize %s\\n' works\n",
                              "--expect", "resize works", "--timeout", "4")
            assert b"31 103" in resized.stdout, resized.stdout
            assert b"snapshots=" in resized.stderr
            # One reader observes the other client's input; neither detach kills the PTY.
            reader = subprocess.Popen([base[0], "attach", sid, *base[1:], "--headless", "--timeout", "6",
                                       "--expect", "shared output"], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                writer = command(base, "attach", sid, "--headless", "--timeout", "5",
                                 "--send", "printf 'shared %s\\n' output\n", "--expect", "shared output")
                out, err = reader.communicate(timeout=10)
                assert reader.returncode == 0 and b"shared output" in out, err
                assert session_id(writer) == sid
            finally:
                if reader.poll() is None:
                    reader.kill()
                    reader.wait()
            other = command(base, "new", "--headless", "--timeout", "4", "--send",
                            "printf 'isolated %s\\n' shell\n", "--expect", "isolated shell")
            assert session_id(other) != sid
            assert b"native works" not in other.stdout
            command(base, "attach", "999", "--headless", success=False)
            command(base, "attach", sid, "--headless", "--timeout", "0", "--expect", "NEVER_PRESENT", success=False)
            wrong = Path(directory) / "wrong-token"
            wrong.write_bytes(b"x" * 32)
            bad_base = [*base[:-1], str(wrong)]
            command(bad_base, "list", success=False)
            exited = command(base, "attach", sid, "--headless", "--timeout", "4",
                             "--send", "printf 'process %s\\n' exited; exit\n", "--expect", "process exited")
            assert b"process exited" in exited.stdout
            command(base, "attach", sid, "--headless", "--timeout", "2", "--expect", "process exited")
        # A different generated certificate is not a valid trust anchor for this server.
        with tempfile.TemporaryDirectory(prefix="multiplexer-other-") as other_dir:
            with server(server_binary, other_dir) as (_, other_state):
                wrong_cert = Path(directory) / "other.der"
                wrong_cert.write_bytes((other_state / "cert.der").read_bytes())
        with server(server_binary, directory) as (address, state):
            base = connection(client_binary, address, state)
            base[base.index("--cert") + 1] = str(wrong_cert)
            command(base, "list", success=False)
    print(f"PASS QUIC/PTY matrix: {server_binary.name} server / {client_binary.name} client", flush=True)


def interactive(zig):
    with tempfile.TemporaryDirectory(prefix="multiplexer-interactive-") as directory:
        with server(zig, directory) as (address, state):
            base = connection(zig, address, state)
            created = command(base, "new", "--headless", "--cols", "40", "--rows", "8", "--timeout", "5",
                              "--send", "stty -echo; i=1; while [ $i -le 60 ]; do printf 'history %03d\\n' $i; i=$((i+1)); done\n",
                              "--expect", "history 060")
            master, slave = pty.openpty()
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 8, 40, 0, 0))
            before = termios.tcgetattr(slave)
            proc = subprocess.Popen([base[0], "attach", session_id(created), *base[1:]], stdin=slave, stdout=slave, stderr=slave)
            def read_until(needle):
                data = bytearray()
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline:
                    if select.select([master], [], [], 0.05)[0]:
                        data.extend(os.read(master, 65536))
                        if needle in data:
                            return bytes(data)
                    assert proc.poll() is None, data.decode(errors="replace")
                raise AssertionError(f"interactive output missing {needle!r}: {data[-1000:]!r}")
            try:
                read_until(b"history 060")
                os.write(master, b"\x1b[<64;1;1M")
                # Seven output rows plus the prompt: live top is 054,
                # and the wheel moves three physical lines to 051.
                history = read_until(b"history 051")
                assert b"\x1b[?25l" in history
                os.write(master, b"\x1b")
                read_until(b"history 060")
                os.write(master, b"\x1b[5;2~")
                read_until(b"history 047")
                os.write(master, b"\x1b[200~printf 'paste %s\\n' works\n\x1b[201~")
                read_until(b"paste works")
                fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 10, 55, 0, 0))
                os.write(master, b"stty size\r")
                read_until(b"10 55")
                os.write(master, b"\x1d")
                proc.wait(timeout=6)
                cleanup = bytearray()
                while select.select([master], [], [], 0.05)[0]:
                    cleanup.extend(os.read(master, 65536))
                assert proc.returncode == 0, cleanup
                assert b"\x1b[?1006l" in cleanup and b"\x1b[?1049l" in cleanup, cleanup
                after = termios.tcgetattr(slave)
                if os.uname().sysname == "Darwin":
                    # macOS sets this transient state bit when restoring ICANON,
                    # even with no pending input; it is not a terminal setting.
                    before[3] &= ~termios.PENDIN
                    after[3] &= ~termios.PENDIN
                assert after == before, "raw mode not restored"
            finally:
                if proc.poll() is None:
                    proc.kill()
                    proc.wait()
                os.close(master)
                os.close(slave)
    print("PASS interactive PTY: wheel/page history, Esc, paste-to-live, resize, detach and raw-mode cleanup", flush=True)


def tailscale(zig):
    # Substitute only the local-daemon CLI boundary; connections are real QUIC.
    with tempfile.TemporaryDirectory(prefix="multiplexer-tailscale-") as directory:
        path = Path(directory)
        fixture = path / "whois.json"
        identity = {"Node": {"StableID": "node-test", "User": 42, "Tags": []},
                    "UserProfile": {"ID": 42, "LoginName": "allowed@example.com"}}
        fixture.write_text(json.dumps(identity))
        cli = path / "tailscale"
        cli.write_text("#!/usr/bin/env python3\nimport json,sys\nfrom pathlib import Path\n"
                       "if sys.argv[1:] == ['status','--json','--peers=false']:\n"
                       " print(json.dumps({'BackendState':'Running','TUN':True,'Self':{'TailscaleIPs':['127.0.0.1']}}))\n"
                       "elif sys.argv[1:4] == ['whois','--json','--proto=udp']:\n"
                       " print(Path(__file__).with_name('whois.json').read_text())\n"
                       "else: sys.exit(1)\n")
        cli.chmod(0o700)
        env = {**os.environ, "PATH": str(path) + os.pathsep + os.environ.get("PATH", "")}
        with server(zig, directory, ["--tailscale", "--allow-user", "allowed@example.com"], env) as (address, state):
            base = connection(zig, address, state, tailscale=True)
            assert not (state / "token").exists()
            created = command(base, "new", "--headless", "--timeout", "4", "--send",
                              "printf 'identity %s\\n' works\n", "--expect", "identity works")
            sid = session_id(created)
            expected = f"{sid}\tallowed@example.com\tnode-test\n".encode()
            assert command(base, "list").stdout == expected
            # Creator metadata must not change after another allowed node attaches.
            identity["Node"]["StableID"] = "node-second"
            fixture.write_text(json.dumps(identity))
            command(base, "attach", sid, "--headless", "--expect", "identity works")
            assert command(base, "list").stdout == expected
            identity["Node"]["Tags"] = ["tag:server"]
            fixture.write_text(json.dumps(identity))
            command(base, "list", success=False)
            identity["Node"]["Tags"] = []
            identity["UserProfile"]["LoginName"] = "denied@example.com"
            fixture.write_text(json.dumps(identity))
            command(base, "list", success=False)
            fixture.write_text("not json")
            command(base, "list", success=False)
            # Old token files are ignored in identity mode; token clients cannot fall back.
            (state / "token").write_bytes(b"x" * 32)
            identity["UserProfile"]["LoginName"] = "allowed@example.com"
            fixture.write_text(json.dumps(identity))
            assert command(base, "list").stdout == expected
            command(connection(zig, address, state), "list", success=False)
    print("PASS Tailscale QUIC: creator metadata, reattach, tagged/unknown/malformed rejection, no token fallback", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--zig", type=Path, default=ROOT / "zig-out/bin/multiplexer-zig")
    parser.add_argument("--rust", type=Path, help="Built Rust executable for cross-language tests")
    args = parser.parse_args()
    zig = args.zig.resolve()
    matrix(zig, zig)
    interactive(zig)
    tailscale(zig)
    if args.rust:
        rust = args.rust.resolve()
        matrix(zig, rust)
        matrix(rust, zig)
