use multiplexer::{
    client::Client,
    protocol::{ClientMessage, Request, Screen, SessionInfo, Size},
    server::Server,
};
use std::{net::SocketAddr, path::Path, time::Duration};
use tokio::time::{sleep, timeout};

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn screen_pacing_tracks_network_rtt_and_stops_after_ack() {
    use multiplexer::protocol::Update;
    use std::sync::Arc;
    use tokio::{net::UdpSocket, task::JoinSet, time::Instant};

    // Real QUIC connections through a delayed UDP relay exercise both clamps
    // and an interior RTT. These ranges distinguish half-RTT pacing from the
    // old 50 ms tick, full-RTT pacing, and an unclamped half-RTT implementation.
    for (delay_ms, min_ms, max_ms) in [(0, 15, 40), (80, 60, 115), (300, 220, 290)] {
        let state = tempfile::tempdir().unwrap();
        let server = Server::bind(
            "127.0.0.1:0".parse().unwrap(),
            state.path(),
            "/bin/sh".into(),
        )
        .unwrap();
        let address = server.endpoint.local_addr().unwrap();
        let server_task = tokio::spawn(server.clone().run());
        let relay = Arc::new(UdpSocket::bind("127.0.0.1:0").await.unwrap());
        let relay_address = relay.local_addr().unwrap();
        let relay_task = tokio::spawn(async move {
            let mut client_address = None;
            let mut deliveries = JoinSet::new();
            let mut buffer = vec![0; 65536];
            loop {
                tokio::select! {
                    packet = relay.recv_from(&mut buffer) => {
                        let (len, source) = packet.unwrap();
                        let destination = if source == address {
                            client_address.unwrap()
                        } else {
                            client_address = Some(source);
                            address
                        };
                        let packet = buffer[..len].to_vec();
                        let socket = relay.clone();
                        deliveries.spawn(async move {
                            sleep(Duration::from_millis(delay_ms)).await;
                            socket.send_to(&packet, destination).await.unwrap();
                        });
                    }
                    Some(result) = deliveries.join_next() => { result.unwrap(); }
                }
            }
        });
        let size = Size { cols: 40, rows: 8 };
        let mut client = connect(relay_address, state.path(), Request::Create { size }).await;
        until(&mut client, |_| true).await;
        client
            .send(ClientMessage::Input(
                b"stty -echo; printf '\x1b[2J\x1b[H'; printf 'R''EADY'\n".to_vec(),
            ))
            .await
            .unwrap();
        until(&mut client, |s| s.text().starts_with("READY")).await;
        if delay_ms == 0 {
            // Fresh, acknowledged screens must not inherit the 20 ms retry
            // floor. Use a median so one scheduler delay cannot fail the check.
            let mut latencies = Vec::new();
            for i in 0..9 {
                let text = format!("FRESH{i}");
                let start = Instant::now();
                client
                    .send(ClientMessage::Input(
                        format!("printf '\x1b[H'; printf '{text}'\n").into_bytes(),
                    ))
                    .await
                    .unwrap();
                until(&mut client, |s| s.text().starts_with(&text)).await;
                latencies.push(start.elapsed());
            }
            latencies.sort();
            eprintln!("median fresh screen latency: {:?}", latencies[4]);
            assert!(latencies[4] < Duration::from_millis(15));
        }
        client
            .send(ClientMessage::Input(
                b"printf '\x1b[H'; printf 'P''ACED'\n".to_vec(),
            ))
            .await
            .unwrap();

        // Discard application updates, but allow QUIC's packet ACKs through.
        // A stable screen must keep retrying even without further PTY output.
        let (revision, median) = timeout(Duration::from_secs(10), async {
            let mut previous = None;
            let mut intervals = Vec::new();
            loop {
                let data = client.connection.read_datagram().await.unwrap();
                let update: Update = postcard::from_bytes(&data).unwrap();
                let now = Instant::now();
                let mut observed = client.screen.clone().unwrap();
                // Setup retries can still be in flight after its ACK. Like the
                // real client, ignore datagrams against an obsolete baseline.
                if !observed.apply(update).unwrap() || !observed.text().starts_with("PACED") {
                    continue;
                }
                if let Some((revision, at)) = previous {
                    if revision == observed.revision {
                        intervals.push(now - at);
                    } else {
                        intervals.clear();
                    }
                }
                previous = Some((observed.revision, now));
                if intervals.len() == 7 {
                    intervals.sort();
                    break (observed.revision, intervals[3]);
                }
            }
        })
        .await
        .expect("unacknowledged screen stopped retrying");
        eprintln!("one-way delay {delay_ms} ms: median screen interval {median:?}");
        assert!(
            (Duration::from_millis(min_ms)..=Duration::from_millis(max_ms)).contains(&median),
            "unexpected pacing at one-way delay {delay_ms} ms: {median:?}"
        );

        client.send(ClientMessage::Ack(revision)).await.unwrap();
        // Drain retries already in flight while the application ACK traverses
        // the relay, then require a full quiet window (longer than any interval).
        let quiet = Duration::from_millis(2 * delay_ms + 350);
        timeout(Duration::from_secs(5), async {
            while timeout(quiet, client.connection.read_datagram())
                .await
                .is_ok()
            {}
        })
        .await
        .expect("screen updates continued after application ACK");
        assert!(
            timeout(
                Duration::from_millis(350),
                client.connection.read_datagram()
            )
            .await
            .is_err()
        );
        drop(client);
        server.endpoint.close(0u32.into(), b"test complete");
        server_task.await.unwrap();
        relay_task.abort();
        let _ = relay_task.await;
    }
}

async fn connect(address: SocketAddr, state: &Path, request: Request) -> Client {
    Client::connect(
        address,
        &state.join("cert.der"),
        Some(&state.join("token")),
        request,
    )
    .await
    .unwrap()
}

async fn until(client: &mut Client, predicate: impl Fn(&Screen) -> bool) {
    timeout(Duration::from_secs(5), async {
        loop {
            if client.screen.as_ref().is_some_and(&predicate) {
                break;
            }
            client.next().await.unwrap();
        }
    })
    .await
    .unwrap_or_else(|_| {
        panic!(
            "screen convergence timed out: {:?}",
            client.screen.as_ref().map(Screen::text)
        )
    });
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn scrollback_survives_reattach_and_tracks_each_reader_without_stopping_live_output() {
    let state = tempfile::tempdir().unwrap();
    let server = Server::bind(
        "127.0.0.1:0".parse().unwrap(),
        state.path(),
        "/bin/sh".into(),
    )
    .unwrap();
    let address = server.endpoint.local_addr().unwrap();
    let task = tokio::spawn(server.clone().run());
    let size = Size { cols: 40, rows: 6 };
    let mut writer = connect(address, state.path(), Request::Create { size }).await;
    until(&mut writer, |_| true).await;
    writer.send(ClientMessage::Input("stty -echo; PS1=''; printf '\x1b[2J\x1b[H'; i=0; while [ $i -lt 60 ]; do printf '\x1b[1;38;2;17;83;149mrow-%03d界e\u{301}\x1b[0m\\n' $i; i=$((i+1)); done\n".as_bytes().to_vec())).await.unwrap();
    until(&mut writer, |s| s.text().starts_with("row-055")).await;
    let id = writer.id.unwrap();
    writer.detach().await.unwrap();
    // Neither reader observed the intermediate screens which contain history.
    let mut a = connect(address, state.path(), Request::Attach { id, size }).await;
    let mut b = connect(address, state.path(), Request::Attach { id, size }).await;
    until(&mut a, |s| s.text().starts_with("row-055")).await;
    until(&mut b, |s| s.text().starts_with("row-055")).await;
    async fn scroll(client: &mut Client, lines: i32, first: &str) {
        client.scroll(lines).await.unwrap();
        timeout(Duration::from_secs(5), async {
            loop {
                if client
                    .scrollback
                    .as_ref()
                    .is_some_and(|s| s.text().starts_with(first))
                {
                    break;
                }
                client.next().await.unwrap();
            }
        })
        .await
        .unwrap();
    }
    scroll(&mut a, 3, "row-052").await;
    scroll(&mut b, 5, "row-050").await;
    assert_eq!(a.view().unwrap().cursor, None);
    assert_eq!(b.view().unwrap().rows[0][0].fg, [17, 83, 149]);
    assert_eq!(b.view().unwrap().rows[0][0].attributes & 1, 1);
    assert_eq!(b.view().unwrap().rows[0][7].text, "界");
    assert_eq!(b.view().unwrap().rows[0][7].width, 2);
    assert_eq!(b.view().unwrap().rows[0][8].width, 0);
    assert_eq!(b.view().unwrap().rows[0][9].text, "e\u{301}");
    b.send(ClientMessage::Input(
        b"i=60; while [ $i -lt 70 ]; do printf 'row-%03d\\n' $i; i=$((i+1)); done\n".to_vec(),
    ))
    .await
    .unwrap();
    until(&mut a, |s| s.text().starts_with("row-065")).await;
    until(&mut b, |s| s.text().starts_with("row-065")).await;
    assert!(a.view().unwrap().text().starts_with("row-052"));
    assert!(b.view().unwrap().text().starts_with("row-050"));
    // Moving relative to the anchor, not today's bottom, is essential here.
    scroll(&mut a, 2, "row-050").await;
    scroll(&mut b, -2, "row-052").await;
    // Clamp at the oldest row, then at the live edge.
    scroll(&mut a, 150, "row-000").await;
    a.scroll(-150).await.unwrap();
    timeout(Duration::from_secs(5), async {
        while a.scrollback.is_some() {
            a.next().await.unwrap();
        }
    })
    .await
    .unwrap();
    assert!(a.view().unwrap().text().starts_with("row-065"));
    // A late page response must not resurrect a view after returning live.
    a.scroll(3).await.unwrap();
    a.scroll(0).await.unwrap();
    a.send(ClientMessage::Input(b"printf 'L''IVE\\n'\n".to_vec()))
        .await
        .unwrap();
    until(&mut a, |s| s.text().contains("LIVE")).await;
    assert!(a.scrollback.is_none());
    b.send(ClientMessage::Resize(Size { cols: 50, rows: 8 }))
        .await
        .unwrap();
    until(&mut a, |s| s.size.cols == 50).await;
    until(&mut b, |s| s.size.cols == 50).await;
    assert!(
        b.scrollback.is_none(),
        "another client's resize invalidates history views"
    );
    scroll(&mut a, 3, "row-061").await;
    assert_eq!(
        &a.view().unwrap().rows[3..],
        &a.screen.as_ref().unwrap().rows[..5]
    );
    a.send(ClientMessage::Input(b"printf '\x1b[?1049hALT'\n".to_vec()))
        .await
        .unwrap();
    until(&mut a, |s| s.alternate_screen && s.text().contains("ALT")).await;
    assert!(a.scrollback.is_none());
    a.scroll(3).await.unwrap();
    assert!(
        a.scrollback.is_none(),
        "alternate-screen applications keep their own input"
    );
    a.send(ClientMessage::Input(b"printf '\x1b[?1049l'\n".to_vec()))
        .await
        .unwrap();
    until(&mut a, |s| !s.alternate_screen).await;
    scroll(&mut a, 3, "row-061").await;
    a.send(ClientMessage::Input(
        b"i=0; while [ $i -lt 12050 ]; do printf 'prune-%05d\\n' $i; i=$((i+1)); done\n".to_vec(),
    ))
    .await
    .unwrap();
    timeout(Duration::from_secs(60), async {
        while !a.screen.as_ref().unwrap().text().contains("prune-12049") {
            a.next().await.unwrap();
        }
    })
    .await
    .expect("pruning output did not drain");
    assert!(a.view().unwrap().text().starts_with("row-061"));
    scroll(&mut a, 3, "prune-").await;
    let oldest = a
        .view()
        .unwrap()
        .text()
        .lines()
        .next()
        .unwrap()
        .strip_prefix("prune-")
        .unwrap()
        .parse::<u32>()
        .unwrap();
    assert!(
        oldest > 0 && oldest < 12044,
        "a pruned anchor resumes in retained history"
    );
    a.detach().await.unwrap();
    b.detach().await.unwrap();
    server.endpoint.close(0u32.into(), b"test complete");
    task.abort();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn interactive_scrollback_handles_mouse_keyboard_paste_and_terminal_cleanup() {
    use libghostty_vt::{
        RenderState, Terminal,
        terminal::{Mode, ModeKind},
    };
    use portable_pty::{CommandBuilder, PtySize, native_pty_system};
    use std::io::{Read, Write};

    let state = tempfile::tempdir().unwrap();
    let server = Server::bind(
        "127.0.0.1:0".parse().unwrap(),
        state.path(),
        "/bin/sh".into(),
    )
    .unwrap();
    let task = tokio::spawn(server.clone().run());
    let pair = native_pty_system()
        .openpty(PtySize {
            rows: 6,
            cols: 40,
            pixel_width: 0,
            pixel_height: 0,
        })
        .unwrap();
    let mut command = CommandBuilder::new(env!("CARGO_BIN_EXE_multiplexer"));
    command.args([
        "new",
        "--server",
        &server.endpoint.local_addr().unwrap().to_string(),
        "--cert",
        state.path().join("cert.der").to_str().unwrap(),
        "--token-file",
        state.path().join("token").to_str().unwrap(),
    ]);
    command.env("TERM", "xterm-256color");
    let mut child = pair.slave.spawn_command(command).unwrap();
    drop(pair.slave);
    let mut input = pair.master.take_writer().unwrap();
    let mut reader = pair.master.try_clone_reader().unwrap();
    let (tx, mut output) = tokio::sync::mpsc::channel(64);
    std::thread::spawn(move || {
        let mut bytes = [0; 8192];
        while let Ok(count) = reader.read(&mut bytes) {
            if count == 0 || tx.blocking_send(bytes[..count].to_vec()).is_err() {
                break;
            }
        }
    });
    let mut display = Terminal::new(40, 6).unwrap();
    async fn frame(
        display: &mut Terminal<'_, '_>,
        output: &mut tokio::sync::mpsc::Receiver<Vec<u8>>,
        first: &str,
    ) -> Screen {
        timeout(Duration::from_secs(5), async {
            loop {
                display.vt_write(
                    &output
                        .recv()
                        .await
                        .expect("CLI closed before expected frame"),
                );
                let screen = multiplexer::session::capture(
                    display,
                    &mut RenderState::new().unwrap(),
                    None,
                    1,
                    false,
                )
                .unwrap();
                if screen.text().starts_with(first) {
                    return screen;
                }
            }
        })
        .await
        .unwrap_or_else(|_| {
            let screen = multiplexer::session::capture(
                display,
                &mut RenderState::new().unwrap(),
                None,
                1,
                false,
            )
            .unwrap();
            panic!(
                "CLI frame timed out waiting for {first:?}: {}",
                screen.text()
            );
        })
    }
    frame(&mut display, &mut output, "").await;
    input.write_all(b"stty -echo; PS1=''; printf '\x1b[2J\x1b[H'; i=0; while [ $i -lt 30 ]; do printf 'row-%03d\\n' $i; i=$((i+1)); done\n").unwrap();
    frame(&mut display, &mut output, "row-025").await;
    assert!(display.mode(Mode::new(1006, ModeKind::Dec)).unwrap());
    input.write_all(b"\x1b[<64;10;3M").unwrap();
    let history = frame(&mut display, &mut output, "row-022").await;
    assert_eq!(history.cursor, None);
    assert_eq!(
        history.text(),
        "row-022\nrow-023\nrow-024\nrow-025\nrow-026\nrow-027"
    );
    input.write_all(b"\x1b[5;2~").unwrap();
    frame(&mut display, &mut output, "row-017").await;
    input.write_all(b"\x1b[6;2~").unwrap();
    frame(&mut display, &mut output, "row-022").await;
    input.write_all(b"\x1b[<65;10;3M").unwrap();
    assert!(
        frame(&mut display, &mut output, "row-025")
            .await
            .cursor
            .is_some()
    );
    input.write_all(b"\x1b[<64;10;3M").unwrap();
    frame(&mut display, &mut output, "row-022").await;
    input.write_all(b"\x1b").unwrap();
    frame(&mut display, &mut output, "row-025").await;
    input.write_all(b"\x1b[<64;10;3M").unwrap();
    frame(&mut display, &mut output, "row-022").await;
    input.write_all(b"p").unwrap();
    frame(&mut display, &mut output, "row-025").await;
    input.write_all(b"rintf 'TYPED\\n'\n").unwrap();
    frame(
        &mut display,
        &mut output,
        "row-026\nrow-027\nrow-028\nrow-029\nTYPED",
    )
    .await;
    input.write_all(b"\x1b[<64;10;3M").unwrap();
    frame(&mut display, &mut output, "row-023").await;
    input
        .write_all(b"\x1b[200~printf 'PASTED\\n'\n\x1b[201~")
        .unwrap();
    let pasted = frame(
        &mut display,
        &mut output,
        "row-027\nrow-028\nrow-029\nTYPED\nPASTED",
    )
    .await;
    assert!(
        pasted.text().contains("PASTED"),
        "paste must reach the shell after returning live"
    );
    input.write_all(b"\x1d").unwrap();
    timeout(Duration::from_secs(5), async {
        while let Some(bytes) = output.recv().await {
            display.vt_write(&bytes);
        }
    })
    .await
    .unwrap();
    assert!(child.wait().unwrap().success());
    assert!(!display.mode(Mode::new(1006, ModeKind::Dec)).unwrap());
    assert!(!display.mode(Mode::new(1000, ModeKind::Dec)).unwrap());
    assert!(!display.mode(Mode::new(1049, ModeKind::Dec)).unwrap());
    server.endpoint.close(0u32.into(), b"test complete");
    task.abort();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn encrypted_udp_sessions_survive_detach_loss_resize_and_process_exit() {
    let state = tempfile::tempdir().unwrap();
    let server = Server::bind(
        "127.0.0.1:0".parse().unwrap(),
        state.path(),
        "/bin/sh".into(),
    )
    .unwrap();
    let address = server.endpoint.local_addr().unwrap();
    let task = tokio::spawn(server.clone().run());
    let size = Size { cols: 40, rows: 8 };
    let mut client = connect(address, state.path(), Request::Create { size }).await;
    until(&mut client, |_| true).await;
    client
        .send(ClientMessage::Input(
            b"stty -echo; printf '\x1b[2J\x1b[H'; printf 'A''LPHA'\n".to_vec(),
        ))
        .await
        .unwrap();
    until(&mut client, |s| s.text().starts_with("ALPHA")).await;
    let id = client.id.unwrap();
    assert!(
        client.datagrams > 0,
        "small screen updates must use datagrams"
    );

    // Receive but deliberately discard the next terminal datagram without ACKing.
    client
        .send(ClientMessage::Input(b"printf '\\r\\nB''ETA'\n".to_vec()))
        .await
        .unwrap();
    let _lost = timeout(Duration::from_secs(5), client.connection.read_datagram())
        .await
        .unwrap()
        .unwrap();
    client
        .send(ClientMessage::Input(b"printf '\\r\\nG''AMMA'\n".to_vec()))
        .await
        .unwrap();
    until(&mut client, |s| {
        s.text().contains("BETA") && s.text().contains("GAMMA")
    })
    .await;
    assert!(client.screen.as_ref().unwrap().text().starts_with("ALPHA"));
    let saved = client.screen.as_ref().unwrap().text();
    drop(client);
    sleep(Duration::from_millis(150)).await;
    // Exercise the shipped CLI too, not just its library API.
    let output = tokio::process::Command::new(env!("CARGO_BIN_EXE_multiplexer"))
        .args([
            "attach",
            &id.to_string(),
            "--server",
            &address.to_string(),
            "--headless",
            "--cols",
            "40",
            "--rows",
            "8",
            "--expect",
            "GAMMA",
        ])
        .arg("--cert")
        .arg(state.path().join("cert.der"))
        .arg("--token-file")
        .arg(state.path().join("token"))
        .output()
        .await
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(String::from_utf8_lossy(&output.stdout).starts_with("ALPHA"));
    // A completed CLI detach must allow immediate reattachment.
    let cert = state.path().join("cert.der");
    let token = state.path().join("token");
    tokio::task::spawn_blocking(move || {
        use portable_pty::{CommandBuilder, PtySize, native_pty_system};
        use std::io::{Read, Write};
        let pair = native_pty_system()
            .openpty(PtySize {
                rows: 8,
                cols: 40,
                pixel_width: 0,
                pixel_height: 0,
            })
            .unwrap();
        let mut command = CommandBuilder::new(env!("CARGO_BIN_EXE_multiplexer"));
        command.args([
            "attach",
            &id.to_string(),
            "--server",
            &address.to_string(),
            "--cert",
        ]);
        command.arg(cert);
        command.arg("--token-file");
        command.arg(token);
        command.env("TERM", "xterm-256color");
        let mut child = pair.slave.spawn_command(command).unwrap();
        drop(pair.slave);
        let mut reader = pair.master.try_clone_reader().unwrap();
        let mut writer = pair.master.take_writer().unwrap();
        let (ready, rendered) = std::sync::mpsc::channel();
        let reader = std::thread::spawn(move || {
            let mut bytes = Vec::new();
            let mut buf = [0; 8192];
            while let Ok(count) = reader.read(&mut buf) {
                if count == 0 {
                    break;
                }
                bytes.extend_from_slice(&buf[..count]);
                if bytes.windows(6).any(|s| s == b"\x1b[?25h") {
                    let _ = ready.send(());
                }
            }
            bytes
        });
        let ready = rendered.recv_timeout(Duration::from_secs(5));
        if ready.is_err() {
            child.kill().unwrap();
        }
        ready.expect("interactive screen did not render");
        writer.write_all(&[0x1d]).unwrap(); // Actual legacy Ctrl+] terminal input.
        let deadline = std::time::Instant::now() + Duration::from_secs(5);
        let status = loop {
            if let Some(status) = child.try_wait().unwrap() {
                break status;
            }
            if std::time::Instant::now() >= deadline {
                child.kill().unwrap();
                panic!("Ctrl+] did not detach the interactive CLI");
            }
            std::thread::sleep(Duration::from_millis(10));
        };
        assert!(status.success());
        let mut display = libghostty_vt::Terminal::new(40, 8).unwrap();
        display.set_scrollback_max_bytes(Some(0)).unwrap();
        display.vt_write(b"original terminal");
        display.vt_write(&reader.join().unwrap());
        assert_eq!(
            display.active_screen().unwrap(),
            libghostty_vt::screen::Screen::Primary
        );
        assert_eq!(
            multiplexer::session::capture(
                &display,
                &mut libghostty_vt::RenderState::new().unwrap(),
                None,
                1,
                false
            )
            .unwrap()
            .text(),
            "original terminal\n\n\n\n\n\n\n",
            "detach must preserve the original terminal contents"
        );
    })
    .await
    .unwrap();
    let mut client = connect(address, state.path(), Request::Attach { id, size }).await;
    until(&mut client, |s| s.text() == saved).await;

    let resized = Size { cols: 53, rows: 11 };
    client.send(ClientMessage::Resize(resized)).await.unwrap();
    until(&mut client, |s| s.size == resized).await;
    client
        .send(ClientMessage::Input(b"stty size\n".to_vec()))
        .await
        .unwrap();
    until(&mut client, |s| s.text().contains("11 53")).await;
    assert!(client.snapshots >= 2, "resize requires a new snapshot");

    // Force an update too large for a datagram and check reliable fallback.
    let snapshots = client.snapshots;
    client.send(ClientMessage::Input(b"printf '\x1b[2J\x1b[H'; i=0; while [ $i -lt 7 ]; do printf 'abcdefghijklmnopqrstuvwxyz0123456789\\r\\n'; i=$((i+1)); done\n".to_vec())).await.unwrap();
    until(&mut client, |s| {
        s.text()
            .matches("abcdefghijklmnopqrstuvwxyz0123456789")
            .count()
            == 7
    })
    .await;
    assert!(client.snapshots > snapshots);

    let mut other = connect(address, state.path(), Request::Create { size }).await;
    until(&mut other, |_| true).await;
    assert_ne!(other.id, client.id);
    assert!(!other.screen.as_ref().unwrap().text().contains("ALPHA"));
    let mut list = connect(address, state.path(), Request::List).await;
    assert_eq!(
        list.list().await.unwrap(),
        vec![
            SessionInfo { id, creator: None },
            SessionInfo {
                id: other.id.unwrap(),
                creator: None,
            },
        ]
    );

    client
        .send(ClientMessage::Input(b"exit\n".to_vec()))
        .await
        .unwrap();
    until(&mut client, |s| s.exited).await;
    drop(client);
    drop(other);
    drop(list);
    server.endpoint.close(0u32.into(), b"test complete");
    task.await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn clients_share_input_output_and_size_but_detach_independently() {
    let state = tempfile::tempdir().unwrap();
    let server = Server::bind(
        "127.0.0.1:0".parse().unwrap(),
        state.path(),
        "/bin/sh".into(),
    )
    .unwrap();
    let address = server.endpoint.local_addr().unwrap();
    let task = tokio::spawn(server.clone().run());
    let size = Size { cols: 40, rows: 8 };
    let mut first = connect(address, state.path(), Request::Create { size }).await;
    until(&mut first, |_| true).await;
    first
        .send(ClientMessage::Input(
            b"stty -echo; printf '\x1b[2J\x1b[H'; printf 'F''IRST\\n'\n".to_vec(),
        ))
        .await
        .unwrap();
    until(&mut first, |s| s.text().starts_with("FIRST")).await;
    let id = first.id.unwrap();
    let mut second = connect(address, state.path(), Request::Attach { id, size }).await;
    second.next().await.unwrap();
    assert_eq!(second.id, Some(id));

    // Do not read or ACK the second client's initial snapshot yet. It must not
    // hold up the first client's replication or advance its baseline.
    first
        .send(ClientMessage::Input(b"printf 'S''ECOND\\n'\n".to_vec()))
        .await
        .unwrap();
    until(&mut first, |s| s.text().contains("SECOND")).await;
    until(&mut second, |s| s.text().contains("SECOND")).await;

    second
        .send(ClientMessage::Input(b"printf 'T''HIRD\\n'\n".to_vec()))
        .await
        .unwrap();
    until(&mut first, |s| s.text().contains("THIRD")).await;
    until(&mut second, |s| s.text().contains("THIRD")).await;

    let resized = Size { cols: 53, rows: 11 };
    second.send(ClientMessage::Resize(resized)).await.unwrap();
    until(&mut first, |s| s.size == resized).await;
    until(&mut second, |s| s.size == resized).await;
    first
        .send(ClientMessage::Input(b"stty size\n".to_vec()))
        .await
        .unwrap();
    until(&mut first, |s| s.text().contains("11 53")).await;
    until(&mut second, |s| s.text().contains("11 53")).await;

    first.detach().await.unwrap();
    drop(first);
    second
        .send(ClientMessage::Input(b"printf 'D''ETACHED\\n'\n".to_vec()))
        .await
        .unwrap();
    until(&mut second, |s| s.text().contains("DETACHED")).await;

    // Attaching with a different size resizes the shared session too.
    let mut third = connect(address, state.path(), Request::Attach { id, size }).await;
    until(&mut third, |s| {
        s.size == size && s.text().contains("DETACHED")
    })
    .await;
    until(&mut second, |s| s.size == size).await;
    drop(second); // An abrupt disconnect must not detach the remaining client.
    third
        .send(ClientMessage::Input(b"printf 'C''ONNECTED\\n'\n".to_vec()))
        .await
        .unwrap();
    until(&mut third, |s| s.text().contains("CONNECTED")).await;

    let mut fourth = connect(address, state.path(), Request::Attach { id, size }).await;
    until(&mut fourth, |s| s.text().contains("CONNECTED")).await;
    third
        .send(ClientMessage::Input(b"exit\n".to_vec()))
        .await
        .unwrap();
    until(&mut third, |s| s.exited).await;
    until(&mut fourth, |s| s.exited).await;
    assert_eq!(third.screen, fourth.screen);
    drop(third);
    drop(fourth);
    server.endpoint.close(0u32.into(), b"test complete");
    task.await.unwrap();
}

#[tokio::test]
async fn wrong_token_and_untrusted_certificate_are_rejected() {
    let state = tempfile::tempdir().unwrap();
    let other_state = tempfile::tempdir().unwrap();
    let server = Server::bind(
        "127.0.0.1:0".parse().unwrap(),
        state.path(),
        "/bin/sh".into(),
    )
    .unwrap();
    let other = Server::bind(
        "127.0.0.1:0".parse().unwrap(),
        other_state.path(),
        "/bin/sh".into(),
    )
    .unwrap();
    let address = server.endpoint.local_addr().unwrap();
    let task = tokio::spawn(server.clone().run());
    let mut wrong_token = Client::connect(
        address,
        &state.path().join("cert.der"),
        Some(&other_state.path().join("token")),
        Request::List,
    )
    .await
    .unwrap();
    assert!(
        wrong_token
            .list()
            .await
            .unwrap_err()
            .to_string()
            .contains("authentication")
    );
    assert!(
        Client::connect(
            address,
            &other_state.path().join("cert.der"),
            Some(&state.path().join("token")),
            Request::List
        )
        .await
        .is_err()
    );
    let mut no_token =
        Client::connect(address, &state.path().join("cert.der"), None, Request::List)
            .await
            .unwrap();
    assert!(
        no_token
            .list()
            .await
            .unwrap_err()
            .to_string()
            .contains("authentication")
    );
    // Version 1 clients expect bare session IDs and cannot decode creator metadata.
    let (_endpoint, connection) =
        multiplexer::transport::connect(address, &state.path().join("cert.der"))
            .await
            .unwrap();
    let (mut send, mut receive) = connection.open_bi().await.unwrap();
    multiplexer::protocol::send(
        &mut send,
        &multiplexer::protocol::Hello {
            version: 1,
            token: std::fs::read(state.path().join("token")).unwrap(),
            request: Request::List,
        },
    )
    .await
    .unwrap();
    assert!(matches!(
        multiplexer::protocol::receive::<multiplexer::protocol::ServerMessage>(&mut receive)
            .await
            .unwrap(),
        multiplexer::protocol::ServerMessage::Error(_)
    ));
    server.endpoint.close(0u32.into(), b"test complete");
    other.endpoint.close(0u32.into(), b"test complete");
    task.await.unwrap();
}

#[cfg(target_os = "linux")]
async fn saturated_session() -> (multiplexer::session::Session, tempfile::TempDir, u32) {
    use std::os::unix::fs::PermissionsExt;
    let state = tempfile::tempdir().unwrap();
    let shell = state.path().join("shell");
    std::fs::write(
        &shell,
        format!(
            "#!/bin/sh\ntrap '' HUP\nstty raw -echo\necho $$ > '{0}/pid'\nkill -STOP $$\nhead -c \"$(cat '{0}/bytes')\" >/dev/null\nhead -c 11\nprintf '\\r\\n'\nexec /bin/sh\n",
            state.path().display()
        ),
    )
    .unwrap();
    std::fs::set_permissions(&shell, std::fs::Permissions::from_mode(0o700)).unwrap();
    let session = multiplexer::session::Session::spawn(
        shell.to_str().unwrap().into(),
        Size { cols: 40, rows: 8 },
    )
    .await
    .unwrap();
    let pid = timeout(Duration::from_secs(5), async {
        loop {
            if let Ok(pid) = std::fs::read_to_string(state.path().join("pid")) {
                let pid: u32 = pid.trim().parse().unwrap();
                let status = std::fs::read_to_string(format!("/proc/{pid}/status")).unwrap();
                if status.lines().any(|line| line.starts_with("State:\tT")) {
                    break pid;
                }
            }
            sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .expect("fixture did not stop");
    // A stopped, raw-mode child cannot drain input. Fill the PTY and then the
    // event queue, rather than hoping an output flood happens to saturate it.
    let mut bytes = 0;
    while let Ok(result) =
        timeout(Duration::from_millis(50), session.input(vec![b'x'; 65536])).await
    {
        result.expect("queue pressure must not reject reliable input");
        bytes += 65536;
        assert!(bytes < 128 * 65536, "fixture did not saturate");
    }
    std::fs::write(state.path().join("bytes"), bytes.to_string()).unwrap();
    (session, state, pid)
}

#[cfg(target_os = "linux")]
#[tokio::test]
async fn full_queue_preserves_input_and_resize_when_child_resumes() {
    let (session, _state, pid) = saturated_session().await;
    let size = Size { cols: 53, rows: 11 };
    let mut screen = session.screen.clone();
    let commands = async {
        session.input(b"FIRST".to_vec()).await.unwrap();
        session.resize(size).await.unwrap();
        session.input(b"SECOND".to_vec()).await.unwrap();
    };
    tokio::pin!(commands);
    assert!(
        timeout(Duration::from_millis(50), &mut commands)
            .await
            .is_err()
    );
    assert!(
        tokio::process::Command::new("kill")
            .args(["-CONT", &pid.to_string()])
            .status()
            .await
            .unwrap()
            .success()
    );
    timeout(Duration::from_secs(5), commands).await.unwrap();
    timeout(Duration::from_secs(5), async {
        loop {
            if screen.borrow().size == size && screen.borrow().text().contains("FIRSTSECOND") {
                break;
            }
            screen.changed().await.unwrap();
        }
    })
    .await
    .expect("queued commands did not reach the PTY in order");
}

#[cfg(target_os = "linux")]
#[tokio::test]
async fn shutdown_does_not_wait_for_full_queue_or_hup_ignoring_child() {
    let (session, _state, pid) = saturated_session().await;
    let mut screen = session.screen.clone();
    timeout(
        Duration::from_secs(1),
        tokio::task::spawn_blocking(move || drop(session)),
    )
    .await
    .expect("session destructor blocked")
    .unwrap();
    timeout(Duration::from_secs(5), async {
        while std::path::Path::new(&format!("/proc/{pid}")).exists() {
            sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .expect("shutdown did not reap the child");
    timeout(Duration::from_secs(5), async {
        while screen.changed().await.is_ok() {}
    })
    .await
    .expect("shutdown did not unblock the worker");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn output_flood_accepts_interrupt_resize_and_reattach() {
    let state = tempfile::tempdir().unwrap();
    let server = Server::bind(
        "127.0.0.1:0".parse().unwrap(),
        state.path(),
        "/bin/sh".into(),
    )
    .unwrap();
    let address = server.endpoint.local_addr().unwrap();
    let task = tokio::spawn(server.clone().run());
    let size = Size { cols: 40, rows: 8 };
    let mut client = connect(address, state.path(), Request::Create { size }).await;
    until(&mut client, |_| true).await;
    // Repaint rather than scroll: exercise sustained PTY output without making
    // this a benchmark of Ghostty's scrollback throughput.
    client
        .send(ClientMessage::Input(
            b"stty -echo; yes \"$(printf '\\033[H')FLOOD\"\n".to_vec(),
        ))
        .await
        .unwrap();
    until(&mut client, |s| s.text().contains("FLOOD")).await;
    let id = client.id.unwrap();
    drop(client);
    sleep(Duration::from_millis(150)).await;
    let size = Size { cols: 53, rows: 11 };
    let mut client = connect(address, state.path(), Request::Attach { id, size }).await;
    until(&mut client, |s| s.size == size).await;
    client.send(ClientMessage::Input(vec![3])).await.unwrap();
    client
        .send(ClientMessage::Input(
            b"printf 'I''NTERRUPTED\\n'; stty size\n".to_vec(),
        ))
        .await
        .unwrap();
    until(&mut client, |s| {
        s.text().contains("INTERRUPTED") && s.text().contains("11 53")
    })
    .await;
    client
        .send(ClientMessage::Input(b"exit\n".to_vec()))
        .await
        .unwrap();
    until(&mut client, |s| s.exited).await;
    drop(client);
    server.endpoint.close(0u32.into(), b"test complete");
    task.await.unwrap();
}
