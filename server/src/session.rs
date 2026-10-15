use crate::protocol::{Cell, Screen, Size};
use anyhow::{Result, bail, ensure};
use libghostty_vt::{
    RenderState, Terminal,
    render::{CellIterator, Dirty, RowIterator},
    screen::{CellContentTag, CellWide, TrackedGridRef},
    style::{RgbColor, Style, StyleColor},
    terminal::{Mode, ModeKind, Point, PointCoordinate, PointSpace},
};
use portable_pty::{CommandBuilder, PtySize, native_pty_system};
use std::{
    collections::HashMap,
    io::{self, Read, Write},
    sync::{
        Arc, Weak,
        atomic::{AtomicBool, Ordering},
        mpsc as std_mpsc,
    },
    thread,
    time::Duration,
};
use tokio::sync::{mpsc, oneshot, watch};

enum Event {
    Output(Vec<u8>),
    Input(Vec<u8>),
    Resize(Size),
    Scroll {
        owner: Weak<()>,
        epoch: u64,
        lines: i32,
        reply: oneshot::Sender<Result<(u32, Screen)>>,
    },
    Eof,
    Stop,
}

pub struct Session {
    tx: mpsc::Sender<Event>,
    shutdown: Shutdown,
    pub screen: watch::Receiver<Arc<Screen>>,
}

/// A connection's history anchor is released when this lease is dropped.
#[derive(Default)]
pub struct Scrollback(Arc<()>);

#[derive(Clone)]
struct Shutdown {
    stopped: Arc<AtomicBool>,
    tx: std_mpsc::Sender<()>,
}

impl Drop for Shutdown {
    fn drop(&mut self) {
        self.stopped.store(true, Ordering::Release);
        let _ = self.tx.send(());
    }
}

impl Session {
    pub async fn spawn(shell: String, size: Size) -> Result<Self> {
        size.validate()?;
        let (tx, rx) = mpsc::channel(64);
        let (stop_tx, stop_rx) = std_mpsc::channel();
        let shutdown = Shutdown {
            stopped: Arc::new(AtomicBool::new(false)),
            tx: stop_tx,
        };
        let worker_shutdown = shutdown.clone();
        let (ready_tx, ready_rx) = oneshot::channel();
        let reader_tx = tx.clone();
        thread::spawn(move || {
            let result = run(
                shell,
                size,
                rx,
                reader_tx,
                ready_tx,
                &worker_shutdown,
                stop_rx,
            );
            if let Err(error) = result {
                eprintln!("session: {error:#}");
            }
        });
        let screen = ready_rx.await??;
        Ok(Self {
            tx,
            shutdown,
            screen,
        })
    }

    pub async fn input(&self, data: Vec<u8>) -> Result<()> {
        if data.len() > 65536 {
            bail!("input too large");
        }
        self.tx.send(Event::Input(data)).await?;
        Ok(())
    }

    pub async fn resize(&self, size: Size) -> Result<()> {
        size.validate()?;
        self.tx.send(Event::Resize(size)).await?;
        Ok(())
    }

    pub async fn scroll(
        &self,
        owner: &Scrollback,
        epoch: u64,
        lines: i32,
    ) -> Result<(u32, Screen)> {
        ensure!((-150..=150).contains(&lines), "scroll exceeds one screen");
        let (reply, result) = oneshot::channel();
        self.tx
            .send(Event::Scroll {
                owner: Arc::downgrade(&owner.0),
                epoch,
                lines,
                reply,
            })
            .await?;
        result.await?
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        // The flag and independent reaper do not depend on event queue capacity.
        self.shutdown.stopped.store(true, Ordering::Release);
        let _ = self.tx.try_send(Event::Stop);
    }
}

fn pty_size(size: Size) -> PtySize {
    PtySize {
        rows: size.rows,
        cols: size.cols,
        pixel_width: 0,
        pixel_height: 0,
    }
}

fn write_pty(writer: &mut dyn Write, mut bytes: &[u8], stopped: &AtomicBool) -> io::Result<()> {
    while !bytes.is_empty() {
        if stopped.load(Ordering::Acquire) {
            return Err(io::Error::new(io::ErrorKind::BrokenPipe, "session stopped"));
        }
        match writer.write(bytes) {
            Ok(0) => return Err(io::ErrorKind::WriteZero.into()),
            Ok(count) => bytes = &bytes[count..],
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                thread::sleep(Duration::from_millis(5));
            }
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            Err(error) => return Err(error),
        }
    }
    Ok(())
}

fn run(
    shell: String,
    size: Size,
    mut rx: mpsc::Receiver<Event>,
    reader_tx: mpsc::Sender<Event>,
    ready: oneshot::Sender<Result<watch::Receiver<Arc<Screen>>>>,
    shutdown: &Shutdown,
    stop_rx: std_mpsc::Receiver<()>,
) -> Result<()> {
    let setup = (|| -> Result<_> {
        let pair = native_pty_system().openpty(pty_size(size))?;
        let mut command = CommandBuilder::new(shell);
        command.env("TERM", "xterm-256color");
        command.env_remove("PS1");
        command.env_remove("PS2");
        let mut child = pair.slave.spawn_command(command)?;
        // Own the real child handle, not clone_killer(): on Unix only the real
        // handle escalates to SIGKILL when a child ignores SIGHUP.
        thread::spawn(move || {
            while matches!(
                stop_rx.recv_timeout(Duration::from_millis(100)),
                Err(std_mpsc::RecvTimeoutError::Timeout)
            ) {
                if let Ok(Some(_)) = child.try_wait() {
                    return;
                }
            }
            let _ = child.kill();
            let _ = child.wait();
        });
        drop(pair.slave);
        #[cfg(unix)]
        {
            let fd = pair.master.as_raw_fd().expect("native Unix PTY has an fd");
            // SAFETY: master owns this live descriptor. Its reader/writer clones
            // share O_NONBLOCK, so both paths below handle WouldBlock.
            let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
            if flags == -1
                || unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } == -1
            {
                return Err(io::Error::last_os_error().into());
            }
        }
        let reader = pair.master.try_clone_reader()?;
        let writer = pair.master.take_writer()?;
        let mut terminal = Terminal::new(size.cols, size.rows)?;
        terminal.set_scrollback_max_bytes(Some(8 * 1024 * 1024))?;
        terminal.set_scrollback_max_lines(Some(10_000))?;
        let writer = std::rc::Rc::new(std::cell::RefCell::new(writer));
        let reply_writer = writer.clone();
        let stopped = shutdown.stopped.clone();
        terminal.on_pty_write(move |_, bytes| {
            let _ = write_pty(&mut **reply_writer.borrow_mut(), bytes, &stopped);
        })?;
        let render = RenderState::new()?;
        Ok((pair.master, reader, writer, terminal, render))
    })();
    let (master, mut reader, writer, terminal, mut render) = match setup {
        Ok(value) => value,
        Err(error) => {
            let _ = ready.send(Err(error));
            return Ok(());
        }
    };
    // Both Ghostty objects are created and exclusively used on this thread.
    let mut terminal = terminal;
    let mut screen = capture(&terminal, &mut render, None, 1, false)?;
    let (published, receiver) = watch::channel(Arc::new(screen.clone()));
    let stopped = shutdown.stopped.clone();
    #[cfg(unix)]
    let read_ready = {
        use std::os::fd::{FromRawFd, OwnedFd};
        // Keep a descriptor alive in the reader even if the session owner exits.
        // SAFETY: master owns the source fd; fcntl returns a new owned fd.
        let fd = unsafe {
            libc::fcntl(
                master.as_raw_fd().expect("native Unix PTY has an fd"),
                libc::F_DUPFD_CLOEXEC,
                0,
            )
        };
        if fd == -1 {
            return Err(io::Error::last_os_error().into());
        }
        // SAFETY: fcntl created this descriptor and no other owner holds it.
        unsafe { OwnedFd::from_raw_fd(fd) }
    };
    let _ = ready.send(Ok(receiver));
    thread::spawn(move || {
        let mut buf = [0; 8192];
        while !stopped.load(Ordering::Acquire) {
            let count = match reader.read(&mut buf) {
                Ok(0) => break,
                Ok(count) => count,
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                    #[cfg(unix)]
                    {
                        use std::os::fd::AsRawFd;
                        let mut fd = libc::pollfd {
                            fd: read_ready.as_raw_fd(),
                            events: libc::POLLIN,
                            revents: 0,
                        };
                        // Output wakes us immediately. The timeout only bounds
                        // shutdown when a descendant keeps the slave open.
                        // SAFETY: fd references the live descriptor owned above.
                        if unsafe { libc::poll(&mut fd, 1, 100) } < 0
                            && io::Error::last_os_error().kind() != io::ErrorKind::Interrupted
                        {
                            break;
                        }
                    }
                    #[cfg(not(unix))]
                    thread::sleep(Duration::from_millis(20));
                    continue;
                }
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                Err(_) => break,
            };
            if reader_tx
                .blocking_send(Event::Output(buf[..count].to_vec()))
                .is_err()
            {
                return;
            }
        }
        let _ = reader_tx.blocking_send(Event::Eof);
    });
    (|| -> Result<()> {
        let mut exited = false;
        let mut epoch = 1;
        let mut anchors: HashMap<usize, (Weak<()>, TrackedGridRef)> = HashMap::new();
        while let Some(event) = rx.blocking_recv() {
            if shutdown.stopped.load(Ordering::Acquire) {
                break;
            }
            anchors.retain(|_, (owner, _)| owner.strong_count() != 0);
            match event {
                Event::Output(data) => terminal.vt_write(&data),
                Event::Scroll {
                    owner,
                    epoch: requested_epoch,
                    lines,
                    reply,
                } => {
                    let result = (|| -> Result<_> {
                        if requested_epoch != epoch || screen.alternate_screen || lines == 0 {
                            return Ok((0, screen.clone()));
                        }
                        let key = owner.as_ptr() as usize;
                        let anchor = match anchors.entry(key) {
                            std::collections::hash_map::Entry::Occupied(entry) => {
                                &mut entry.into_mut().1
                            }
                            std::collections::hash_map::Entry::Vacant(entry) => {
                                &mut entry
                                    .insert((
                                        owner,
                                        terminal.track_grid_ref(Point::Active(
                                            PointCoordinate { x: 0, y: 0 },
                                        ))?,
                                    ))
                                    .1
                            }
                        };
                        let history = terminal.scrollback_rows()? as u32;
                        // A pruned anchor resumes at the oldest retained row.
                        let current = anchor.point(PointSpace::Screen)?.map_or(0, |p| p.y);
                        let top = (i64::from(current) - i64::from(lines))
                            .clamp(0, i64::from(history)) as u32;
                        anchor.set(
                            &mut terminal,
                            Point::Screen(PointCoordinate { x: 0, y: top }),
                        )?;
                        let page = capture_history(&terminal, &screen, top)?;
                        Ok((history - top, page))
                    })();
                    let _ = reply.send(result);
                    continue;
                }
                Event::Input(data) if !exited => {
                    if let Err(error) =
                        write_pty(&mut **writer.borrow_mut(), &data, &shutdown.stopped)
                    {
                        if shutdown.stopped.load(Ordering::Acquire) {
                            break;
                        }
                        return Err(error.into());
                    }
                    continue;
                }
                Event::Resize(size) => {
                    if screen.size == size {
                        continue;
                    }
                    terminal.resize(size.cols, size.rows, 0, 0)?;
                    master.resize(pty_size(size))?;
                    epoch += 1;
                }
                Event::Eof => {
                    exited = true;
                }
                Event::Stop => break,
                Event::Input(_) => continue,
            }
            let mut next = capture(&terminal, &mut render, Some(&screen), epoch, exited)?;
            if next.alternate_screen != screen.alternate_screen {
                epoch += 1;
                next.epoch = epoch;
            }
            if epoch != screen.epoch {
                anchors.clear();
            }
            // Revision tracks observable state, not PTY read boundaries.
            next.revision = screen.revision;
            if next != screen {
                next.revision += 1;
                screen = next;
                published.send_replace(Arc::new(screen.clone()));
            }
        }
        Ok(())
    })()
}

pub fn capture<'alloc>(
    terminal: &Terminal<'alloc, '_>,
    render: &mut RenderState<'alloc>,
    previous: Option<&Screen>,
    epoch: u64,
    exited: bool,
) -> Result<Screen> {
    let snapshot = render.update(terminal)?;
    let size = Size {
        cols: snapshot.cols()?,
        rows: snapshot.rows()?,
    };
    let full = snapshot.dirty()? == Dirty::Full || previous.is_none_or(|p| p.size != size);
    let colors = snapshot.colors()?;
    let mut rows = previous
        .filter(|p| p.size == size)
        .map(|p| p.rows.clone())
        .unwrap_or_else(|| vec![Vec::new(); size.rows as usize]);
    let mut row_iterator = RowIterator::new()?;
    let mut cell_iterator = CellIterator::new()?;
    let mut iterator = row_iterator.update(&snapshot)?;
    let mut y = 0;
    while let Some(row) = iterator.next() {
        if full || row.dirty()? {
            let mut cells = cell_iterator.update(row)?;
            let mut output = Vec::new();
            while let Some(cell) = cells.next() {
                let style = cell.style()?;
                let fg = cell.fg_color()?.unwrap_or(colors.foreground);
                let bg = cell.bg_color()?.unwrap_or(colors.background);
                output.push(owned_cell(
                    cell.graphemes()?.into_iter().collect(),
                    cell.raw_cell()?.wide()?,
                    style,
                    fg,
                    bg,
                ));
            }
            rows[y] = output;
        }
        row.set_dirty(false)?;
        y += 1;
    }
    snapshot.set_dirty(Dirty::Clean)?;
    Ok(Screen {
        revision: 1,
        epoch,
        size,
        rows,
        cursor: if snapshot.cursor_visible()? {
            snapshot.cursor_viewport()?.map(|c| (c.x, c.y))
        } else {
            None
        },
        application_cursor: terminal.mode(Mode::new(1, ModeKind::Dec))?,
        bracketed_paste: terminal.mode(Mode::new(2004, ModeKind::Dec))?,
        alternate_screen: terminal.active_screen()? == libghostty_vt::screen::Screen::Alternate,
        exited,
    })
}

fn owned_cell(mut text: String, wide: CellWide, style: Style, fg: RgbColor, bg: RgbColor) -> Cell {
    if text.is_empty() {
        text.push(' ');
    }
    let flags = [
        style.bold,
        style.italic,
        style.faint,
        style.blink,
        style.inverse,
        style.invisible,
        style.strikethrough,
        style.overline,
    ];
    Cell {
        text,
        width: match wide {
            CellWide::Wide => 2,
            CellWide::SpacerTail => 0,
            _ => 1,
        },
        fg: [fg.r, fg.g, fg.b],
        bg: [bg.r, bg.g, bg.b],
        attributes: flags
            .iter()
            .enumerate()
            .fold(0, |bits, (i, flag)| bits | ((*flag as u16) << i)),
        underline: style.underline as u8,
    }
}

fn capture_history(terminal: &Terminal<'_, '_>, live: &Screen, top: u32) -> Result<Screen> {
    let mut render = RenderState::new()?;
    let colors = render.update(terminal)?.colors()?;
    let resolve = |color, default| match color {
        StyleColor::None => default,
        StyleColor::Rgb(rgb) => rgb,
        StyleColor::Palette(index) => colors.palette[index.0 as usize],
    };
    let mut page = live.clone();
    page.cursor = None;
    let mut graphemes = vec!['\0'; 16];
    for (y, row) in page.rows.iter_mut().enumerate() {
        for (x, output) in row.iter_mut().enumerate() {
            let grid = terminal.grid_ref(Point::Screen(PointCoordinate {
                x: x as u16,
                y: top + y as u32,
            }))?;
            let raw = grid.cell()?;
            let style = grid.style()?;
            let count = match grid.graphemes(&mut graphemes) {
                Err(libghostty_vt::Error::OutOfSpace { required }) => {
                    graphemes.resize(required, '\0');
                    grid.graphemes(&mut graphemes)?
                }
                result => result?,
            };
            let bg = match raw.content_tag()? {
                CellContentTag::BgColorPalette => {
                    colors.palette[raw.bg_color_palette()?.0 as usize]
                }
                CellContentTag::BgColorRgb => raw.bg_color_rgb()?,
                _ => resolve(style.bg_color, colors.background),
            };
            *output = owned_cell(
                graphemes[..count].iter().collect(),
                raw.wide()?,
                style,
                resolve(style.fg_color, colors.foreground),
                bg,
            );
        }
    }
    Ok(page)
}
