use crate::protocol::{Cell, Screen};
use anyhow::Result;
use crossterm::{
    event::{DisableMouseCapture, EnableMouseCapture},
    execute,
    terminal::{EnterAlternateScreen, LeaveAlternateScreen, disable_raw_mode, enable_raw_mode},
};
use std::io::Write;

pub struct TerminalGuard;

impl TerminalGuard {
    pub fn enter() -> Result<Self> {
        enable_raw_mode()?;
        let guard = Self;
        execute!(std::io::stdout(), EnterAlternateScreen, EnableMouseCapture)?;
        write!(std::io::stdout(), "\x1b[?7l\x1b[?2004h")?;
        std::io::stdout().flush()?;
        Ok(guard)
    }
}

impl Drop for TerminalGuard {
    fn drop(&mut self) {
        let _ = write!(std::io::stdout(), "\x1b[0m\x1b[?25h\x1b[?7h\x1b[?2004l");
        let _ = execute!(std::io::stdout(), DisableMouseCapture, LeaveAlternateScreen);
        let _ = disable_raw_mode();
    }
}

// Render only cells, never terminal-provided escape sequences or OSC effects.
pub fn draw(writer: &mut impl Write, screen: &Screen, previous: Option<&Screen>) -> Result<()> {
    let mut out = Vec::new();
    let mut style: Option<&Cell> = None;
    let full = previous.is_none_or(|p| p.epoch != screen.epoch || p.size != screen.size);
    write!(out, "\x1b[?25l")?;
    if full {
        write!(out, "\x1b[0m\x1b[2J")?;
    }
    for (y, row) in screen.rows.iter().enumerate() {
        if !full && previous.is_some_and(|p| p.rows[y] == *row) {
            continue;
        }
        let mut next_x = None;
        for (x, cell) in row.iter().enumerate() {
            if cell.width == 0 {
                continue;
            }
            if next_x != Some(x) {
                write!(out, "\x1b[{};{}H", y + 1, x + 1)?;
            }
            if style.is_none_or(|s| {
                s.fg != cell.fg
                    || s.bg != cell.bg
                    || s.attributes != cell.attributes
                    || s.underline != cell.underline
            }) {
                write!(
                    out,
                    "\x1b[0;38;2;{};{};{};48;2;{};{};{}m",
                    cell.fg[0], cell.fg[1], cell.fg[2], cell.bg[0], cell.bg[1], cell.bg[2]
                )?;
                for (bit, sgr) in [1, 3, 2, 5, 7, 8, 9, 53].iter().enumerate() {
                    if cell.attributes & (1 << bit) != 0 {
                        write!(out, "\x1b[{sgr}m")?;
                    }
                }
                if cell.underline != 0 {
                    write!(out, "\x1b[4:{}m", cell.underline)?;
                }
                style = Some(cell);
            }
            // Wide graphemes advance over their continuation. If sanitizing
            // text may change its width, explicitly position the next cell.
            next_x = if cell.text.is_empty() || cell.text.chars().any(|ch| ch.is_control()) {
                None
            } else {
                Some(x + cell.width as usize)
            };
            for ch in cell.text.chars().filter(|ch| !ch.is_control()) {
                write!(out, "{ch}")?;
            }
        }
    }
    write!(out, "\x1b[0m")?;
    if let Some((x, y)) = screen.cursor {
        write!(out, "\x1b[{};{}H\x1b[?25h", y + 1, x + 1)?;
    }
    writer.write_all(&out)?;
    writer.flush()?;
    Ok(())
}
