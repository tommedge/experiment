use crate::{
    protocol::{
        self, ClientMessage, Hello, Request, Screen, ServerMessage, SessionInfo, TailscaleIdentity,
    },
    session::{Scrollback, Session},
    tailscale::Tailscale,
    transport,
};
use anyhow::{Result, ensure};
use std::{
    collections::{BTreeMap, VecDeque},
    net::SocketAddr,
    path::Path,
    sync::Arc,
    time::Duration,
};
use subtle::ConstantTimeEq;
use tokio::sync::Mutex;
use tokio::time::Instant;

pub struct Server {
    pub endpoint: quinn::Endpoint,
    auth: Authentication,
    shell: String,
    sessions: Mutex<BTreeMap<u64, SessionEntry>>,
}

struct SessionEntry {
    session: Arc<Session>,
    creator: Option<TailscaleIdentity>,
}

enum Authentication {
    Token(Vec<u8>),
    Tailscale(Tailscale),
}

impl Server {
    pub fn bind(address: SocketAddr, state: &Path, shell: String) -> Result<Arc<Self>> {
        let (endpoint, token) = transport::server(address, state, true)?;
        Ok(Arc::new(Self {
            endpoint,
            auth: Authentication::Token(token),
            shell,
            sessions: Mutex::new(BTreeMap::new()),
        }))
    }

    pub async fn bind_tailscale(
        address: SocketAddr,
        state: &Path,
        shell: String,
        allowed_users: Vec<String>,
    ) -> Result<Arc<Self>> {
        let auth = Tailscale::new(address, allowed_users).await?;
        let (endpoint, _) = transport::server(address, state, false)?;
        Ok(Arc::new(Self {
            endpoint,
            auth: Authentication::Tailscale(auth),
            shell,
            sessions: Mutex::new(BTreeMap::new()),
        }))
    }

    pub async fn run(self: Arc<Self>) {
        while let Some(incoming) = self.endpoint.accept().await {
            let server = self.clone();
            tokio::spawn(async move {
                if let Ok(connection) = incoming.await {
                    if let Err(error) = server.handle(&connection).await {
                        eprintln!("connection: {error:#}");
                    }
                    connection.close(0u32.into(), b"finished");
                }
            });
        }
    }

    async fn handle(&self, connection: &quinn::Connection) -> Result<()> {
        let (mut send, mut receive) =
            tokio::time::timeout(Duration::from_secs(10), connection.accept_bi()).await??;
        let hello: Hello =
            tokio::time::timeout(Duration::from_secs(10), protocol::receive(&mut receive))
                .await??;
        let (authorized, creator) = match &self.auth {
            Authentication::Token(token) => (bool::from(hello.token.ct_eq(token)), None),
            Authentication::Tailscale(tailscale) => {
                // Empty token explicitly selects Tailscale authentication on the wire.
                if hello.token.is_empty() && hello.version == protocol::VERSION {
                    match tailscale.authorize(connection.remote_address()).await {
                        Ok(identity) => (true, Some(identity)),
                        Err(error) => {
                            eprintln!("Tailscale authentication: {error:#}");
                            (false, None)
                        }
                    }
                } else {
                    (false, None)
                }
            }
        };
        if !authorized || hello.version != protocol::VERSION {
            protocol::send(
                &mut send,
                &ServerMessage::Error("authentication failed or incompatible protocol".into()),
            )
            .await?;
            send.finish()?;
            let _ = send.stopped().await;
            return Ok(());
        }
        let result = self
            .request(connection, &mut send, receive, hello.request, creator)
            .await;
        if let Err(error) = result {
            protocol::send(&mut send, &ServerMessage::Error(error.to_string())).await?;
        }
        send.finish()?;
        let _ = send.stopped().await;
        Ok(())
    }

    async fn request(
        &self,
        connection: &quinn::Connection,
        send: &mut quinn::SendStream,
        receive: quinn::RecvStream,
        request: Request,
        creator: Option<TailscaleIdentity>,
    ) -> Result<()> {
        let (id, session, size) = match request {
            Request::List => {
                let sessions = self
                    .sessions
                    .lock()
                    .await
                    .iter()
                    .map(|(&id, entry)| SessionInfo {
                        id,
                        creator: entry.creator.clone(),
                    })
                    .collect();
                protocol::send(send, &ServerMessage::Sessions(sessions)).await?;
                return Ok(());
            }
            Request::Create { size } => {
                size.validate()?;
                let mut sessions = self.sessions.lock().await;
                ensure!(sessions.len() < 64, "session limit reached (64)");
                let id = sessions.keys().next_back().map_or(1, |id| id + 1);
                let session = Arc::new(Session::spawn(self.shell.clone(), size).await?);
                sessions.insert(
                    id,
                    SessionEntry {
                        session: session.clone(),
                        creator,
                    },
                );
                (id, session, size)
            }
            Request::Attach { id, size } => {
                let session = self
                    .sessions
                    .lock()
                    .await
                    .get(&id)
                    .map(|entry| entry.session.clone())
                    .ok_or_else(|| anyhow::anyhow!("unknown session {id}"))?;
                (id, session, size)
            }
        };
        tokio::select! {
            _ = connection.closed() => return Ok(()),
            result = session.resize(size) => result?,
        }
        protocol::send(send, &ServerMessage::Attached(id)).await?;
        let mut screens = session.screen.clone();
        let first = screens.borrow_and_update().clone();
        protocol::send(send, &ServerMessage::Snapshot((*first).clone())).await?;
        let mut sent = VecDeque::from([first]);
        let mut baseline: Option<Arc<Screen>> = None;
        let mut snapshot_pending = Some(sent[0].revision);
        let mut messages = protocol::reader::<ClientMessage>(receive);
        let mut last_sent = Instant::now();
        let mut pending_since = None;
        let mut screen_open = true;
        let mut scrollback = Scrollback::default();
        loop {
            let current = screens.borrow_and_update().clone();
            if sent
                .back()
                .or(baseline.as_ref())
                .is_none_or(|s| s.revision != current.revision)
            {
                // Start the coalescing window only once. Resetting it for every
                // PTY change would starve replication under continuous output.
                pending_since.get_or_insert_with(Instant::now);
            } else {
                pending_since = None;
            }

            // Fresh screens can arrive at low latency without making lost
            // datagrams retry at that rate. Both still track half the QUIC RTT.
            let minimum = Duration::from_millis(if pending_since.is_some() { 1 } else { 20 });
            let interval = (connection.rtt() / 2).clamp(minimum, Duration::from_millis(250));
            let deadline = if snapshot_pending.is_none()
                && baseline
                    .as_ref()
                    .is_none_or(|b| b.revision != current.revision)
            {
                // Fresh output gets a 1 ms batching window; retries only need
                // the rate limit. Anchor both to events, not this loop's wakeups,
                // so incoming input/ACKs cannot keep postponing a due frame.
                Some(pending_since.map_or(last_sent + interval, |since| {
                    (since + Duration::from_millis(1)).max(last_sent + interval)
                }))
            } else {
                // An applied screen needs no retries. A reliable snapshot is
                // already retried by QUIC; wait for its application ACK before
                // producing diffs. Neither case needs a periodic screen timer.
                None
            };
            tokio::select! {
                _ = connection.closed() => return Ok(()),
                // Once fresh output is pending, its deadline is enough to wake
                // us. Don't wake for every intermediate PTY revision in a flood;
                // the send branch reads the newest screen when the frame is due.
                changed = screens.changed(), if screen_open && pending_since.is_none() => {
                    // The final screen remains useful after PTY exit. Disable
                    // this branch on closure to avoid spinning on changed().
                    screen_open = changed.is_ok();
                }
                message = messages.recv() => {
                    let Some(message) = message else { return Ok(()); };
                    match message? {
                        ClientMessage::Input(bytes) => tokio::select! {
                            _ = connection.closed() => return Ok(()),
                            result = session.input(bytes) => result?,
                        },
                        ClientMessage::Resize(size) => tokio::select! {
                            _ = connection.closed() => return Ok(()),
                            result = session.resize(size) => result?,
                        },
                        ClientMessage::Detach => {
                            protocol::send(send, &ServerMessage::Detached).await?;
                            return Ok(());
                        }
                        ClientMessage::Scroll { request, epoch, lines } => {
                            if lines == 0 {
                                scrollback = Scrollback::default();
                                continue;
                            }
                            let (offset, screen) = tokio::select! {
                                _ = connection.closed() => return Ok(()),
                                result = session.scroll(&scrollback, epoch, lines) => result?,
                            };
                            if offset == 0 { scrollback = Scrollback::default(); }
                            protocol::send(send, &ServerMessage::Scrollback { request, offset, screen }).await?;
                        }
                        ClientMessage::Ack(revision) => {
                            if baseline.as_ref().is_some_and(|b| revision <= b.revision) { continue; }
                            if let Some(index) = sent.iter().position(|s| s.revision == revision) {
                                baseline = sent.get(index).cloned();
                                sent.drain(..=index);
                                if snapshot_pending.is_some_and(|pending| revision >= pending) {
                                    snapshot_pending = None;
                                }
                            }
                        }
                    }
                }
                _ = tokio::time::sleep_until(deadline.unwrap_or(last_sent)), if deadline.is_some() => {
                    let current = screens.borrow_and_update().clone();
                    let update = baseline.as_ref().and_then(|b| current.diff(b));
                    let bytes = update.map(|u| postcard::to_allocvec(&u)).transpose()?;
                    if let Some(bytes) = bytes.filter(|b| connection.max_datagram_size().is_some_and(|limit| b.len() <= limit) && sent.len() < 32) {
                        connection.send_datagram(bytes.into())?;
                    } else {
                        protocol::send(send, &ServerMessage::Snapshot((*current).clone())).await?;
                        snapshot_pending = Some(current.revision);
                    }
                    // Schedule from this transmission, never from an expired
                    // deadline: a delayed task must not burst to "catch up".
                    last_sent = Instant::now();
                    pending_since = None;
                    if !sent.iter().any(|s| s.revision == current.revision) {
                        if sent.len() == 32 { sent.pop_front(); }
                        sent.push_back(current);
                    }
                }
            }
        }
    }
}
