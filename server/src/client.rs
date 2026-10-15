use crate::{
    protocol::{self, ClientMessage, Hello, Request, Screen, ServerMessage, SessionInfo, Update},
    render, transport,
};
use anyhow::{Result, bail, ensure};
use crossterm::event::{
    Event, EventStream, KeyCode, KeyEvent, KeyEventKind, KeyModifiers, MouseEventKind,
};
use futures_util::StreamExt;
use std::{net::SocketAddr, path::Path, time::Duration};

enum Incoming {
    Reliable(ServerMessage),
    Datagram(Update),
}

pub struct Client {
    _endpoint: quinn::Endpoint,
    pub connection: quinn::Connection,
    send: quinn::SendStream,
    messages: tokio::sync::mpsc::Receiver<Result<ServerMessage>>,
    pub screen: Option<Screen>,
    pub id: Option<u64>,
    pub datagrams: usize,
    pub snapshots: usize,
    pub scrollback: Option<Screen>,
    scroll_request: u64,
    scrolling: bool,
}

impl Client {
    pub async fn connect(
        address: SocketAddr,
        cert: &Path,
        token: Option<&Path>,
        request: Request,
    ) -> Result<Self> {
        let token = match token {
            Some(path) => {
                let token = std::fs::read(path)?;
                ensure!(token.len() == 32, "token file must contain 32 bytes");
                token
            }
            None => Vec::new(),
        };
        let (endpoint, connection) = transport::connect(address, cert).await?;
        let (mut send, receive) = connection.open_bi().await?;
        protocol::send(
            &mut send,
            &Hello {
                version: protocol::VERSION,
                token,
                request,
            },
        )
        .await?;
        Ok(Self {
            _endpoint: endpoint,
            connection,
            send,
            messages: protocol::reader(receive),
            screen: None,
            id: None,
            datagrams: 0,
            snapshots: 0,
            scrollback: None,
            scroll_request: 0,
            scrolling: false,
        })
    }

    pub async fn send(&mut self, message: ClientMessage) -> Result<()> {
        protocol::send(&mut self.send, &message).await
    }

    // Only cancellation-safe reads belong inside select!; applying and ACKing are outside it.
    async fn next_event(&mut self) -> Result<Incoming> {
        tokio::select! {
            message = self.messages.recv() => Ok(Incoming::Reliable(message.ok_or_else(|| anyhow::anyhow!("server stream closed"))??)),
            data = self.connection.read_datagram() => Ok(Incoming::Datagram(postcard::from_bytes(&data?)?)),
        }
    }

    async fn apply_event(&mut self, incoming: Incoming) -> Result<bool> {
        let old_epoch = self.screen.as_ref().map(|s| s.epoch);
        match incoming {
            Incoming::Reliable(ServerMessage::Attached(id)) => {
                self.id = Some(id);
                return Ok(false);
            }
            Incoming::Reliable(ServerMessage::Snapshot(screen)) => {
                screen.validate()?;
                self.snapshots += 1;
                if self
                    .screen
                    .as_ref()
                    .is_none_or(|s| s.revision < screen.revision)
                {
                    self.screen = Some(screen);
                }
            }
            Incoming::Reliable(ServerMessage::Error(error)) => bail!("{error}"),
            Incoming::Reliable(ServerMessage::Sessions(_)) => bail!("unexpected session list"),
            Incoming::Reliable(ServerMessage::Detached) => bail!("unexpected detach response"),
            Incoming::Reliable(ServerMessage::Scrollback {
                request,
                offset,
                screen,
            }) => {
                screen.validate()?;
                if request != self.scroll_request
                    || !self.scrolling
                    || self.screen.as_ref().is_none_or(|s| s.epoch != screen.epoch)
                {
                    return Ok(false);
                }
                self.scrolling = offset != 0;
                self.scrollback = (offset != 0).then_some(screen);
                return Ok(true);
            }
            Incoming::Datagram(update) => {
                self.datagrams += 1;
                if let Some(screen) = &mut self.screen {
                    if !screen.apply(update)? {
                        let revision = screen.revision;
                        self.send(ClientMessage::Ack(revision)).await?;
                        return Ok(false);
                    }
                } else {
                    return Ok(false);
                }
            }
        }
        if old_epoch != self.screen.as_ref().map(|s| s.epoch) && self.scrolling {
            self.scroll(0).await?;
        }
        let revision = self.screen.as_ref().unwrap().revision;
        self.send(ClientMessage::Ack(revision)).await?;
        Ok(true)
    }

    // Returns false for stale/inapplicable updates, true after visible state changes.
    pub async fn next(&mut self) -> Result<bool> {
        let incoming = self.next_event().await?;
        self.apply_event(incoming).await
    }

    /// The historical view is separate from the continuously acknowledged live screen.
    pub fn view(&self) -> Option<&Screen> {
        self.scrollback.as_ref().or(self.screen.as_ref())
    }

    pub async fn scroll(&mut self, lines: i32) -> Result<()> {
        let Some(screen) = &self.screen else {
            return Ok(());
        };
        if lines != 0 && screen.alternate_screen {
            return Ok(());
        }
        if lines < 0 && !self.scrolling {
            return Ok(());
        }
        let epoch = screen.epoch;
        self.scroll_request += 1;
        self.scrolling = lines != 0;
        if lines == 0 {
            self.scrollback = None;
        }
        self.send(ClientMessage::Scroll {
            request: self.scroll_request,
            epoch,
            lines,
        })
        .await
    }

    pub async fn list(&mut self) -> Result<Vec<SessionInfo>> {
        match self
            .messages
            .recv()
            .await
            .ok_or_else(|| anyhow::anyhow!("server stream closed"))??
        {
            ServerMessage::Sessions(sessions) => Ok(sessions),
            ServerMessage::Error(error) => bail!("{error}"),
            _ => bail!("unexpected response"),
        }
    }

    pub async fn detach(&mut self) -> Result<()> {
        self.send(ClientMessage::Detach).await?;
        tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                match self
                    .messages
                    .recv()
                    .await
                    .ok_or_else(|| anyhow::anyhow!("server stream closed"))??
                {
                    ServerMessage::Detached => return Ok(()),
                    ServerMessage::Error(error) => bail!("{error}"),
                    _ => {}
                }
            }
        })
        .await?
    }

    pub async fn headless(
        &mut self,
        input: Option<&str>,
        expect: Option<&str>,
        duration: Duration,
    ) -> Result<()> {
        let deadline = tokio::time::Instant::now() + duration;
        let mut sent = input.is_none();
        loop {
            let result = tokio::time::timeout_at(deadline, self.next_event()).await;
            match result {
                Ok(incoming) => {
                    self.apply_event(incoming?).await?;
                }
                Err(_) => break,
            }
            if self.screen.is_some() && !sent {
                self.send(ClientMessage::Input(input.unwrap().as_bytes().to_vec()))
                    .await?;
                sent = true;
            }
            if let Some(screen) = &self.screen
                && (expect.is_some_and(|text| screen.text().contains(text)) || screen.exited)
            {
                break;
            }
        }
        let screen = self
            .screen
            .as_ref()
            .ok_or_else(|| anyhow::anyhow!("no screen received"))?;
        println!("{}", screen.text());
        eprintln!(
            "session={} revision={} datagrams={} snapshots={}",
            self.id.unwrap_or(0),
            screen.revision,
            self.datagrams,
            self.snapshots
        );
        let matched = expect.is_none_or(|text| screen.text().contains(text));
        self.detach().await?;
        if let Some(text) = expect {
            ensure!(matched, "expected text not found: {text}");
        }
        Ok(())
    }

    pub async fn interactive(&mut self) -> Result<()> {
        let _guard = render::TerminalGuard::enter()?;
        let mut events = EventStream::new();
        let mut previous = None;
        loop {
            tokio::select! {
                result = self.next_event() => {
                    if self.apply_event(result?).await? {
                        let screen = self.view().unwrap();
                        render::draw(&mut std::io::stdout(), screen, previous.as_ref())?;
                        previous = Some(screen.clone());
                        if screen.exited { break; }
                    }
                }
                event = events.next() => {
                    let Some(event) = event else { break; };
                    match event? {
                        Event::Key(key) if key.kind != KeyEventKind::Release => {
                            // Legacy Ctrl+] is byte 0x1d, which Crossterm reports as Ctrl+5.
                            if matches!(key.code, KeyCode::Char(']' | '5')) && key.modifiers.contains(KeyModifiers::CONTROL) { break; }
                            if key.modifiers.contains(KeyModifiers::SHIFT) && matches!(key.code, KeyCode::PageUp | KeyCode::PageDown) {
                                let page = self.screen.as_ref().map_or(1, |s| i32::from(s.size.rows.saturating_sub(1).max(1)));
                                self.scroll(if key.code == KeyCode::PageUp { page } else { -page }).await?;
                                continue;
                            }
                            if self.scrolling {
                                self.scroll(0).await?;
                                let screen = self.view().unwrap();
                                render::draw(&mut std::io::stdout(), screen, previous.as_ref())?;
                                previous = Some(screen.clone());
                                if key.code == KeyCode::Esc { continue; }
                            }
                            let app = self.screen.as_ref().is_some_and(|s| s.application_cursor);
                            if let Some(bytes) = encode_key(key, app) { self.send(ClientMessage::Input(bytes)).await?; }
                        }
                        Event::Mouse(mouse) => match mouse.kind {
                            MouseEventKind::ScrollUp => self.scroll(3).await?,
                            MouseEventKind::ScrollDown => self.scroll(-3).await?,
                            _ => {}
                        },
                        Event::Resize(cols, rows) => {
                            self.scroll(0).await?;
                            self.send(ClientMessage::Resize(protocol::Size { cols, rows })).await?;
                        }
                        Event::Paste(text) => {
                            if self.scrolling {
                                self.scroll(0).await?;
                                let screen = self.view().unwrap();
                                render::draw(&mut std::io::stdout(), screen, previous.as_ref())?;
                                previous = Some(screen.clone());
                            }
                            let bytes = if self.screen.as_ref().is_some_and(|s| s.bracketed_paste) { format!("\x1b[200~{text}\x1b[201~").into_bytes() } else { text.into_bytes() };
                            self.send(ClientMessage::Input(bytes)).await?;
                        }
                        _ => {}
                    }
                }
            }
        }
        self.detach().await
    }
}

impl Drop for Client {
    fn drop(&mut self) {
        self.connection.close(0u32.into(), b"detached");
    }
}

fn encode_key(key: KeyEvent, application_cursor: bool) -> Option<Vec<u8>> {
    let bytes = match key.code {
        KeyCode::Char(ch) if key.modifiers.contains(KeyModifiers::CONTROL) => {
            let code = ch as u32;
            if (64..=127).contains(&code) {
                vec![(code as u8) & 0x1f]
            } else if ch == ' ' {
                vec![0]
            } else {
                return None;
            }
        }
        KeyCode::Char(ch) => ch.to_string().into_bytes(),
        KeyCode::Enter => vec![b'\r'],
        KeyCode::Tab => vec![b'\t'],
        KeyCode::Backspace => vec![127],
        KeyCode::Esc => vec![27],
        KeyCode::Up
        | KeyCode::Down
        | KeyCode::Right
        | KeyCode::Left
        | KeyCode::Home
        | KeyCode::End => {
            let code = match key.code {
                KeyCode::Up => 'A',
                KeyCode::Down => 'B',
                KeyCode::Right => 'C',
                KeyCode::Left => 'D',
                KeyCode::Home => 'H',
                _ => 'F',
            };
            format!("\x1b{}{code}", if application_cursor { 'O' } else { '[' }).into_bytes()
        }
        KeyCode::Delete => b"\x1b[3~".to_vec(),
        KeyCode::Insert => b"\x1b[2~".to_vec(),
        KeyCode::PageUp => b"\x1b[5~".to_vec(),
        KeyCode::PageDown => b"\x1b[6~".to_vec(),
        _ => return None,
    };
    if key.modifiers.contains(KeyModifiers::ALT) {
        Some([vec![27], bytes].concat())
    } else {
        Some(bytes)
    }
}
