# Rust terminal multiplexer

An independent server and CLI client for persistent PTY sessions, Ghostty terminal
state, and encrypted QUIC screen replication. The native Zig implementation lives
in [`../src/multiplexer/`](../src/multiplexer/); both speak protocol v3.

## Build and test

Requires the Rust toolchain pinned in `rust-toolchain.toml`, Zig 0.16.0, Git and a
C toolchain. Put Zig on PATH. Cargo builds the pinned libghostty-vt dependency on
the first build, which needs Internet access. From this directory:

```sh
cargo build --locked
cargo test --locked
cargo clippy --locked --all-targets -- -D warnings
```

The Cargo lockfile and Ghostty binding revision are unchanged from the source
project. Runtime tests use real Unix PTYs and loopback QUIC connections.
The Linux prerequisite installer is preserved at `.agents/setup`, with its
profile regression checks in `tests/orb_setup.sh`. It can be invoked manually
from this directory; it is not a root-level experiment orb setup hook.

## Run

In separate terminals, from this directory:

```sh
cargo run --locked -- serve
cargo run --locked -- new
cargo run --locked -- list
cargo run --locked -- attach 1
```

The default server listens on loopback UDP port 4433 and launches `/bin/sh`.
Use `serve --bind IP:PORT --shell PATH --state DIR` to override these defaults.
Ctrl+] detaches without killing the shell; Ctrl+C goes to the remote PTY.
Sessions survive client disconnects, not server restarts. Multiple clients can
attach to one session; they share input and the latest terminal dimensions.
There are no panes, splits, automatic reconnect, or per-user session isolation.

The mouse wheel and Shift+PageUp/PageDown browse server-side scrollback. Esc,
typing or pasting returns to live output. Each client's history position is
independent. Resize and screen-buffer switches return to live output. Mouse
forwarding to remote applications is not implemented; use Shift+drag for local
selection while mouse capture is active.

Headless clients support `--send`, `--expect`, `--timeout`, `--cols`, and `--rows`:

```bash
cargo run --locked -- new --headless --timeout 5 \
  --send $'printf "protocol %s\\n" works\n' --expect 'protocol works'
```

## Credentials and trust

By default, the server creates `.multiplexer/cert.der`, `key.der`, and a binary
32-byte `token`. The directory is private (0700) and new files are 0600 on Unix.
For a remote client, securely copy **only the certificate and token**, never the
server's private key. Explicitly bind a non-loopback address to accept remote
traffic. Clients select `--server IP:PORT --cert FILE --token-file FILE`.

Every token holder can access all sessions and execute commands as the server's
OS user. This is a development prototype, not a production-hardened daemon.
Rust validates the trusted certificate through rustls; Zig pins its exact DER
hash and requires the `multiplexer` DNS name and proof of private-key possession.
There is no insecure-certificate mode.

Tailscale mode uses `serve --tailscale --bind TAILSCALE_IP:PORT --allow-user LOGIN`
and clients use `--tailscale --server TAILSCALE_IP:PORT --cert FILE`. It requires
the local Tailscale daemon, kernel networking, and explicit allowed login names.
Tagged devices, unknown identities and failed lookups are rejected, with no token
fallback. Creator identities appear in session listings but do not restrict
access: all allowed users still share all sessions. Same-machine connections
trust the machine's Tailscale owner, not individual local OS users. Restrict the
port with Tailscale policy and the host firewall; WhoIs is an address lookup,
not proof of packet ingress. Identity is checked at connection time, so disconnect
existing clients when immediate revocation is required.

## Zig interoperability

Both implementations use protocol v3: reliable framed Postcard messages carry
requests, snapshots and history; QUIC datagrams carry cumulative screen diffs
against acknowledged revisions. They can reuse credentials, but do **not** share
running sessions. Use separate ports when running both servers.

From the experiment repository root:

```sh
zig build -Dmultiplexer=true -Doptimize=ReleaseSafe
(cd server && cargo build --locked)
python3 tests/zig_end_to_end.py --rust server/target/debug/multiplexer
```
