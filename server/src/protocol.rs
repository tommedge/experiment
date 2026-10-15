use anyhow::{Result, bail, ensure};
use serde::{Deserialize, Serialize};

pub const VERSION: u16 = 3;
pub const MAX_MESSAGE: usize = 4 * 1024 * 1024;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Size {
    pub cols: u16,
    pub rows: u16,
}

impl Size {
    pub fn validate(self) -> Result<()> {
        ensure!(
            (1..=300).contains(&self.cols) && (1..=150).contains(&self.rows),
            "size must be 1..300 columns by 1..150 rows"
        );
        Ok(())
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Cell {
    pub text: String,
    // Width zero marks the continuation of a wide character.
    pub width: u8,
    pub fg: [u8; 3],
    pub bg: [u8; 3],
    pub attributes: u16,
    pub underline: u8,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Screen {
    pub revision: u64,
    pub epoch: u64,
    pub size: Size,
    pub rows: Vec<Vec<Cell>>,
    pub cursor: Option<(u16, u16)>,
    pub application_cursor: bool,
    pub bracketed_paste: bool,
    pub alternate_screen: bool,
    pub exited: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Update {
    pub base: u64,
    pub revision: u64,
    pub epoch: u64,
    pub rows: Vec<(u16, Vec<Cell>)>,
    pub cursor: Option<(u16, u16)>,
    pub application_cursor: bool,
    pub bracketed_paste: bool,
    pub alternate_screen: bool,
    pub exited: bool,
}

impl Screen {
    pub fn diff(&self, base: &Self) -> Option<Update> {
        if self.epoch != base.epoch || self.size != base.size {
            return None;
        }
        Some(Update {
            base: base.revision,
            revision: self.revision,
            epoch: self.epoch,
            rows: self
                .rows
                .iter()
                .zip(&base.rows)
                .enumerate()
                .filter(|(_, (a, b))| a != b)
                .map(|(y, (row, _))| (y as u16, row.clone()))
                .collect(),
            cursor: self.cursor,
            application_cursor: self.application_cursor,
            bracketed_paste: self.bracketed_paste,
            alternate_screen: self.alternate_screen,
            exited: self.exited,
        })
    }

    pub fn apply(&mut self, update: Update) -> Result<bool> {
        if update.base != self.revision
            || update.epoch != self.epoch
            || update.revision <= self.revision
        {
            return Ok(false);
        }
        // Validate the whole update before mutating anything.
        for (y, row) in &update.rows {
            ensure!(
                (*y as usize) < self.rows.len() && row.len() == self.size.cols as usize,
                "invalid update row"
            );
        }
        for (y, row) in update.rows {
            self.rows[y as usize] = row;
        }
        self.revision = update.revision;
        self.cursor = update.cursor;
        self.application_cursor = update.application_cursor;
        self.bracketed_paste = update.bracketed_paste;
        self.alternate_screen = update.alternate_screen;
        self.exited = update.exited;
        Ok(true)
    }

    pub fn validate(&self) -> Result<()> {
        self.size.validate()?;
        ensure!(
            self.rows.len() == self.size.rows as usize
                && self.rows.iter().all(|r| r.len() == self.size.cols as usize),
            "invalid snapshot dimensions"
        );
        Ok(())
    }

    pub fn text(&self) -> String {
        self.rows
            .iter()
            .map(|row| {
                row.iter()
                    .filter(|c| c.width != 0)
                    .map(|c| c.text.as_str())
                    .collect::<String>()
                    .trim_end()
                    .to_owned()
            })
            .collect::<Vec<_>>()
            .join("\n")
    }
}

#[derive(Debug, Serialize, Deserialize)]
pub enum Request {
    List,
    Create { size: Size },
    Attach { id: u64, size: Size },
}

#[derive(Debug, Serialize, Deserialize)]
pub struct Hello {
    pub version: u16,
    pub token: Vec<u8>,
    pub request: Request,
}

#[derive(Debug, Serialize, Deserialize)]
pub enum ClientMessage {
    Input(Vec<u8>),
    Resize(Size),
    Ack(u64),
    Detach,
    /// Positive lines move up; zero releases the client's history anchor.
    Scroll {
        request: u64,
        epoch: u64,
        lines: i32,
    },
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct TailscaleIdentity {
    pub login_name: String,
    pub user_id: u64,
    pub node_id: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionInfo {
    pub id: u64,
    /// The authenticated Tailscale creator; absent for token-created sessions.
    pub creator: Option<TailscaleIdentity>,
}

#[derive(Debug, Serialize, Deserialize)]
pub enum ServerMessage {
    Sessions(Vec<SessionInfo>),
    Attached(u64),
    Snapshot(Screen),
    Error(String),
    Detached,
    Scrollback {
        request: u64,
        offset: u32,
        screen: Screen,
    },
}

pub async fn send<T: Serialize>(stream: &mut quinn::SendStream, value: &T) -> Result<()> {
    let data = postcard::to_allocvec(value)?;
    ensure!(data.len() <= MAX_MESSAGE, "message too large");
    stream.write_all(&(data.len() as u32).to_be_bytes()).await?;
    stream.write_all(&data).await?;
    Ok(())
}

pub async fn receive<T: for<'de> Deserialize<'de>>(stream: &mut quinn::RecvStream) -> Result<T> {
    let mut length = [0; 4];
    stream.read_exact(&mut length).await?;
    let length = u32::from_be_bytes(length) as usize;
    if length > MAX_MESSAGE {
        bail!("message too large");
    }
    let mut data = vec![0; length];
    stream.read_exact(&mut data).await?;
    Ok(postcard::from_bytes(&data)?)
}

// Own the framing reader so select! cancellation never consumes a partial frame.
pub fn reader<T: for<'de> Deserialize<'de> + Send + 'static>(
    mut stream: quinn::RecvStream,
) -> tokio::sync::mpsc::Receiver<Result<T>> {
    let (sender, receiver) = tokio::sync::mpsc::channel(16);
    tokio::spawn(async move {
        loop {
            let message = receive(&mut stream).await;
            let failed = message.is_err();
            if sender.send(message).await.is_err() || failed {
                break;
            }
        }
    });
    receiver
}
