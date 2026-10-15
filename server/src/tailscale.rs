use crate::protocol::TailscaleIdentity;
use anyhow::{Context, Result, ensure};
use serde::{Deserialize, de::DeserializeOwned};
use std::{net::SocketAddr, process::Stdio, time::Duration};
use tokio::{io::AsyncReadExt, process::Command, sync::Semaphore};

pub(crate) struct Tailscale {
    allowed_users: Vec<String>,
    lookups: Semaphore,
}

#[derive(Deserialize)]
#[serde(rename_all = "PascalCase")]
struct Status {
    backend_state: String,
    #[serde(rename = "TUN")]
    tun: bool,
    #[serde(rename = "Self")]
    this_node: SelfNode,
}

#[derive(Deserialize)]
struct SelfNode {
    #[serde(rename = "TailscaleIPs")]
    ips: Vec<std::net::IpAddr>,
}

#[derive(Deserialize)]
#[serde(rename_all = "PascalCase")]
struct WhoIs {
    node: Node,
    user_profile: User,
}

#[derive(Deserialize)]
#[serde(rename_all = "PascalCase")]
struct Node {
    #[serde(rename = "StableID")]
    stable_id: String,
    user: u64,
    #[serde(default)]
    tags: Vec<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "PascalCase")]
struct User {
    #[serde(rename = "ID")]
    id: u64,
    login_name: String,
}

impl Tailscale {
    pub(crate) async fn new(address: SocketAddr, allowed_users: Vec<String>) -> Result<Self> {
        ensure!(
            !allowed_users.is_empty() && allowed_users.iter().all(|user| !user.trim().is_empty()),
            "Tailscale mode requires at least one allowed user"
        );
        let status: Status = query(&["status", "--json", "--peers=false"]).await?;
        ensure!(
            status.backend_state == "Running" && status.tun,
            "Tailscale must be running in kernel networking mode"
        );
        ensure!(
            status.this_node.ips.contains(&address.ip()) && !address.ip().is_unspecified(),
            "--bind must use this machine's Tailscale IP, not a wildcard, LAN, or loopback address"
        );
        Ok(Self {
            allowed_users,
            lookups: Semaphore::new(16),
        })
    }

    pub(crate) async fn authorize(&self, address: SocketAddr) -> Result<TailscaleIdentity> {
        let _permit = self
            .lookups
            .try_acquire()
            .context("too many identity lookups")?;
        let identity: WhoIs =
            query(&["whois", "--json", "--proto=udp", &address.to_string()]).await?;
        ensure!(
            identity.node.tags.is_empty(),
            "tagged devices are not allowed"
        );
        ensure!(
            !identity.node.stable_id.is_empty()
                && identity.node.user != 0
                && identity.node.user == identity.user_profile.id
                && self
                    .allowed_users
                    .contains(&identity.user_profile.login_name),
            "Tailscale user is not allowed"
        );
        eprintln!(
            "Tailscale connection: user={} node={} peer={address}",
            identity.user_profile.login_name, identity.node.stable_id
        );
        Ok(TailscaleIdentity {
            login_name: identity.user_profile.login_name,
            user_id: identity.user_profile.id,
            node_id: identity.node.stable_id,
        })
    }
}

// The CLI talks to the local daemon and handles platform-specific socket access.
// Bound both execution and output; a failed lookup never falls back to a token.
async fn query<T: DeserializeOwned>(args: &[&str]) -> Result<T> {
    tokio::time::timeout(Duration::from_secs(5), async {
        let mut child = Command::new("tailscale")
            .args(args)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .kill_on_drop(true)
            .spawn()
            .context("run tailscale (install it and allow access to the local daemon)")?;
        let mut output = Vec::new();
        child
            .stdout
            .take()
            .unwrap()
            .take(1024 * 1024 + 1)
            .read_to_end(&mut output)
            .await?;
        ensure!(output.len() <= 1024 * 1024, "Tailscale response too large");
        ensure!(child.wait().await?.success(), "Tailscale lookup failed");
        serde_json::from_slice(&output).context("invalid Tailscale response")
    })
    .await
    .context("Tailscale lookup timed out")?
}
