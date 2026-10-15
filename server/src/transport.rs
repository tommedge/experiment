use anyhow::{Context, Result, ensure};
use rustls::pki_types::{CertificateDer, PrivatePkcs8KeyDer};
use std::{fs, net::SocketAddr, path::Path, sync::Arc, time::Duration};

fn config() -> quinn::TransportConfig {
    let mut config = quinn::TransportConfig::default();
    config.keep_alive_interval(Some(Duration::from_secs(5)));
    config.max_concurrent_bidi_streams(1u32.into());
    config.max_concurrent_uni_streams(0u32.into());
    config.datagram_receive_buffer_size(Some(256 * 1024));
    config
}

pub fn server(
    address: SocketAddr,
    state: &Path,
    token_auth: bool,
) -> Result<(quinn::Endpoint, Vec<u8>)> {
    fs::create_dir_all(state)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(state, fs::Permissions::from_mode(0o700))?;
    }
    let cert_path = state.join("cert.der");
    let key_path = state.join("key.der");
    let token_path = state.join("token");
    if !cert_path.exists() && !key_path.exists() {
        let certified = rcgen::generate_simple_self_signed(vec!["multiplexer".into()])?;
        private_file(&key_path, &certified.signing_key.serialize_der())?;
        private_file(&cert_path, certified.cert.der())?;
    }
    let token = if token_auth {
        if !token_path.exists() {
            private_file(&token_path, &rand::random::<[u8; 32]>())?;
        }
        let token = fs::read(token_path)?;
        ensure!(token.len() == 32, "token file must contain 32 bytes");
        token
    } else {
        Vec::new()
    };
    let mut server = quinn::ServerConfig::with_single_cert(
        vec![CertificateDer::from(fs::read(cert_path)?)],
        PrivatePkcs8KeyDer::from(fs::read(key_path)?).into(),
    )?;
    // Tailscale authorization is tied to the address checked at connection time.
    server.migration(token_auth);
    server.transport_config(Arc::new(config()));
    Ok((quinn::Endpoint::server(server, address)?, token))
}

fn private_file(path: &Path, data: &[u8]) -> Result<()> {
    use std::io::Write;
    let mut options = fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    options.open(path)?.write_all(data)?;
    Ok(())
}

pub async fn connect(
    address: SocketAddr,
    cert: &Path,
) -> Result<(quinn::Endpoint, quinn::Connection)> {
    let mut roots = rustls::RootCertStore::empty();
    roots.add(CertificateDer::from(
        fs::read(cert).context("read trusted server certificate")?,
    ))?;
    let mut client = quinn::ClientConfig::with_root_certificates(Arc::new(roots))?;
    client.transport_config(Arc::new(config()));
    let bind = if address.is_ipv4() {
        "0.0.0.0:0"
    } else {
        "[::]:0"
    };
    let mut endpoint = quinn::Endpoint::client(bind.parse()?)?;
    endpoint.set_default_client_config(client);
    let connection = endpoint.connect(address, "multiplexer")?.await?;
    Ok((endpoint, connection))
}
