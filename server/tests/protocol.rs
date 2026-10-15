use libghostty_vt::{RenderState, Terminal};
use multiplexer::{protocol::Screen, render, session::capture};

fn states() -> (Screen, Screen, Screen) {
    let mut terminal = Terminal::new(12, 3).unwrap();
    terminal.set_scrollback_max_bytes(Some(0)).unwrap();
    let mut render = RenderState::new().unwrap();
    terminal.vt_write(b"one\r\ntwo");
    let first = capture(&terminal, &mut render, None, 1, false).unwrap();
    terminal.vt_write(b"\x1b[1;1H\x1b[38;2;17;83;149mNEW");
    let mut second = capture(&terminal, &mut render, Some(&first), 1, false).unwrap();
    second.revision = 2;
    terminal.vt_write("\x1b[3;2H界e\u{301}".as_bytes());
    let mut third = capture(&terminal, &mut render, Some(&second), 1, false).unwrap();
    third.revision = 3;
    (first, second, third)
}

#[test]
fn cumulative_diff_recovers_loss_and_rejects_stale_or_wrong_baselines() {
    let (first, second, third) = states();
    // Lose revision 2, then deliver a cumulative revision 3 based on the last ACK.
    let mut client = first.clone();
    let wire = postcard::to_allocvec(&third.diff(&first).unwrap()).unwrap();
    assert!(client.apply(postcard::from_bytes(&wire).unwrap()).unwrap());
    assert_eq!(client.text(), "NEW\ntwo\n 界é");
    assert_eq!(client.rows[2][1].width, 2);
    assert_eq!(client.rows[2][2].width, 0);
    assert_eq!(client.rows[2][3].text, "é");
    assert_eq!(client.rows[0][0].fg, [17, 83, 149]);
    assert_eq!(client, third);
    assert!(!client.apply(second.diff(&first).unwrap()).unwrap());
    assert!(!first.clone().apply(third.diff(&second).unwrap()).unwrap());
    let mut resized = third.clone();
    resized.epoch += 1;
    assert!(resized.diff(&third).is_none());
    let mut invalid = third.diff(&first).unwrap();
    invalid.rows.push((99, third.rows[0].clone()));
    let mut client = first.clone();
    assert!(client.apply(invalid).is_err());
    assert_eq!(client, first, "invalid updates must be atomic");
}

#[test]
fn rendered_cells_preserve_wide_graphemes_and_incremental_changes() {
    let (first, _, third) = states();
    let mut bytes = b"\x1b[?7l".to_vec();
    render::draw(&mut bytes, &first, None).unwrap();
    render::draw(&mut bytes, &third, Some(&first)).unwrap();
    let mut display = Terminal::new(12, 3).unwrap();
    display.set_scrollback_max_bytes(Some(0)).unwrap();
    display.vt_write(&bytes);
    let actual = capture(&display, &mut RenderState::new().unwrap(), None, 1, false).unwrap();
    assert_eq!(actual.text(), "NEW\ntwo\n 界é");
    assert_eq!(actual.rows, third.rows);
    assert_eq!(actual.cursor, third.cursor);
}

#[test]
fn rendered_style_runs_preserve_resets_and_right_edge_graphemes() {
    let mut terminal = Terminal::new(40, 3).unwrap();
    terminal.vt_write(
        "\x1b[1;3;4:3;38;2;31;97;163;48;2;19;53;87mstyled界e\u{301}\x1b[0mplain\r\n\x1b[7mreverse\x1b[0mnormal\x1b[3;38H界Z\x1b[?25l".as_bytes(),
    );
    let expected = capture(&terminal, &mut RenderState::new().unwrap(), None, 1, false).unwrap();
    let mut bytes = b"\x1b[?7l".to_vec();
    render::draw(&mut bytes, &expected, None).unwrap();
    assert!(
        bytes.len() < 1500,
        "homogeneous cells must not each emit cursor/style escapes"
    );
    let mut display = Terminal::new(40, 3).unwrap();
    display.vt_write(&bytes);
    let actual = capture(&display, &mut RenderState::new().unwrap(), None, 1, false).unwrap();
    assert_eq!(actual.rows, expected.rows);
    assert_eq!(actual.cursor, None);
}
