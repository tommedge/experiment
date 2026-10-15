#![cfg(unix)]

use multiplexer::{
    client::Client,
    protocol::{Request, SessionInfo, TailscaleIdentity},
};
use serde_json::json;
use std::{os::unix::fs::PermissionsExt, path::Path, process::Stdio, time::Duration};
use tokio::{io::AsyncBufReadExt, process::Command, time::timeout};

fn server_command(directory: &Path) -> Command {
    let mut command = Command::new(env!("CARGO_BIN_EXE_multiplexer"));
    command
        .env(
            "PATH",
            format!("{}:{}", directory.display(), std::env::var("PATH").unwrap()),
        )
        .args(["serve", "--tailscale", "--allow-user", "alice@example.com"])
        .args(["--allow-user", "bob@example.com"])
        .arg("--state")
        .arg(directory.join("state"))
        .kill_on_drop(true);
    command
}

async fn client(directory: &Path, address: &str, args: &[&str]) -> std::process::Output {
    timeout(
        Duration::from_secs(15),
        Command::new(env!("CARGO_BIN_EXE_multiplexer"))
            .args(args)
            .args(["--server", address, "--cert"])
            .arg(directory.join("state/cert.der"))
            .kill_on_drop(true)
            .output(),
    )
    .await
    .expect("client timed out")
    .unwrap()
}

// Only the local Tailscale CLI is a fixture. Server/client binaries, QUIC, TLS,
// authorization, and the PTY are real. No tailnet credentials are needed in CI.
#[tokio::test]
async fn tailscale_mode_authorizes_identity_without_a_token_and_fails_closed() {
    let directory = tempfile::tempdir().unwrap();
    let directory = directory.path();
    let executable = directory.join("tailscale");
    std::fs::write(
        &executable,
        r#"#!/bin/sh
case "$*" in
  'status --json --peers=false') cat "$0.status" ;;
  'whois --json --proto=udp '*)
    case "$4" in 127.0.0.1:*) ;; *) exit 1 ;; esac
    case "$(cat "$0.whois")" in
      fail) exit 1 ;;
      slow) exec sleep 30 ;;
      *) cat "$0.whois" ;;
    esac ;;
  *) exit 1 ;;
esac
"#,
    )
    .unwrap();
    std::fs::set_permissions(&executable, std::fs::Permissions::from_mode(0o700)).unwrap();
    // The fixture claims a loopback address so real sockets work without a TUN
    // device. A real daemon reports only its assigned Tailscale addresses.
    let status = json!({
        "BackendState": "Running", "TUN": true,
        "Self": {"TailscaleIPs": ["127.0.0.1"]}
    });
    std::fs::write(directory.join("tailscale.status"), status.to_string()).unwrap();
    let identity = json!({
        "Node": {"StableID": "n-test", "User": 42},
        "UserProfile": {"ID": 42, "LoginName": "alice@example.com"}
    });
    let whois = directory.join("tailscale.whois");
    std::fs::write(&whois, identity.to_string()).unwrap();

    // Configuration errors must fail before creating credentials or a listener.
    for bad_status in [
        json!({"BackendState": "Stopped", "TUN": true, "Self": {"TailscaleIPs": ["127.0.0.1"]}}),
        json!({"BackendState": "Running", "TUN": false, "Self": {"TailscaleIPs": ["127.0.0.1"]}}),
        json!({"BackendState": "Running", "TUN": true, "Self": {"TailscaleIPs": ["100.101.102.103"]}}),
    ] {
        std::fs::write(directory.join("tailscale.status"), bad_status.to_string()).unwrap();
        let output = server_command(directory)
            .args(["--bind", "127.0.0.1:0"])
            .output()
            .await
            .unwrap();
        assert!(!output.status.success());
        assert!(!directory.join("state").exists());
    }
    std::fs::write(directory.join("tailscale.status"), status.to_string()).unwrap();
    let output = server_command(directory)
        .args(["--bind", "0.0.0.0:0"])
        .output()
        .await
        .unwrap();
    assert!(!output.status.success());

    let mut server = server_command(directory)
        .args(["--bind", "127.0.0.1:0"])
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let mut logs = tokio::io::BufReader::new(server.stderr.take().unwrap()).lines();
    let ready = timeout(Duration::from_secs(10), logs.next_line())
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    assert!(ready.starts_with("listening on "), "{ready}");
    let address = ready.split_whitespace().nth(2).unwrap();
    assert!(!directory.join("state/token").exists());

    let output = client(
        directory,
        address,
        &[
            "new",
            "--tailscale",
            "--headless",
            "--send",
            "printf 'tail%s\\n' scale\n",
            "--expect",
            "tailscale",
        ],
    )
    .await;
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(String::from_utf8_lossy(&output.stdout).contains("tailscale"));
    let log = logs.next_line().await.unwrap().unwrap();
    assert!(log.contains("user=alice@example.com node=n-test"), "{log}");
    let output = client(directory, address, &["list", "--tailscale"]).await;
    assert!(output.status.success());
    assert_eq!(
        String::from_utf8_lossy(&output.stdout),
        "1\talice@example.com\tn-test\n"
    );
    // Reattaching and listing as another user must not replace the creator.
    let bob = json!({
        "Node": {"StableID": "n-bob", "User": 73},
        "UserProfile": {"ID": 73, "LoginName": "bob@example.com"}
    });
    std::fs::write(&whois, bob.to_string()).unwrap();
    let output = client(
        directory,
        address,
        &[
            "attach",
            "1",
            "--tailscale",
            "--headless",
            "--expect",
            "tailscale",
        ],
    )
    .await;
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );

    let output = client(
        directory,
        address,
        &[
            "new",
            "--tailscale",
            "--headless",
            "--send",
            "printf 'second%s\\n' session\n",
            "--expect",
            "secondsession",
        ],
    )
    .await;
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let output = client(directory, address, &["list", "--tailscale"]).await;
    assert!(output.status.success());
    assert_eq!(
        String::from_utf8_lossy(&output.stdout),
        "1\talice@example.com\tn-test\n2\tbob@example.com\tn-bob\n"
    );
    let mut list = Client::connect(
        address.parse().unwrap(),
        &directory.join("state/cert.der"),
        None,
        Request::List,
    )
    .await
    .unwrap();
    assert_eq!(
        list.list().await.unwrap(),
        vec![
            SessionInfo {
                id: 1,
                creator: Some(TailscaleIdentity {
                    login_name: "alice@example.com".into(),
                    user_id: 42,
                    node_id: "n-test".into(),
                }),
            },
            SessionInfo {
                id: 2,
                creator: Some(TailscaleIdentity {
                    login_name: "bob@example.com".into(),
                    user_id: 73,
                    node_id: "n-bob".into(),
                }),
            },
        ]
    );
    drop(list);

    // Identity cannot be substituted by an allowed creator on a tagged device,
    // an unrelated profile, a token, or a failed/malformed daemon response.
    let mut denied_user = identity.clone();
    denied_user["UserProfile"]["LoginName"] = json!("mallory@example.com");
    let mut tagged = identity.clone();
    tagged["Node"]["Tags"] = json!(["tag:server"]);
    let mut mismatched = identity.clone();
    mismatched["Node"]["User"] = json!(43);
    for response in [
        denied_user.to_string(),
        tagged.to_string(),
        mismatched.to_string(),
        "{}".into(),
        "not json".into(),
        "fail".into(),
        "slow".into(),
    ] {
        std::fs::write(&whois, response).unwrap();
        let output = client(directory, address, &["list", "--tailscale"]).await;
        assert!(!output.status.success());
        assert!(String::from_utf8_lossy(&output.stderr).contains("authentication"));
    }
    std::fs::write(&whois, identity.to_string()).unwrap();
    std::fs::write(directory.join("state/token"), [7; 32]).unwrap();
    let token = directory.join("state/token");
    let output = client(
        directory,
        address,
        &["list", "--token-file", token.to_str().unwrap()],
    )
    .await;
    assert!(!output.status.success());
    assert!(String::from_utf8_lossy(&output.stderr).contains("authentication"));
    // An existing token file is ignored, including on server restart.
    server.kill().await.unwrap();
    std::fs::write(&token, b"invalid token").unwrap();
    let mut restarted = server_command(directory)
        .args(["--bind", "127.0.0.1:0"])
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let mut logs = tokio::io::BufReader::new(restarted.stderr.take().unwrap()).lines();
    let ready = timeout(Duration::from_secs(10), logs.next_line())
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    assert!(ready.starts_with("listening on "), "{ready}");
    let output = client(
        directory,
        ready.split_whitespace().nth(2).unwrap(),
        &["list", "--tailscale"],
    )
    .await;
    assert!(output.status.success());
    restarted.kill().await.unwrap();
}
