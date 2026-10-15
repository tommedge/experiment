use anyhow::Result;
use clap::{Args, Parser, Subcommand};
use multiplexer::{
    client::Client,
    protocol::{Request, Size},
    server::Server,
};
use std::{net::SocketAddr, path::PathBuf, time::Duration};

#[derive(Parser)]
#[command(about = "Persistent PTYs with Ghostty screen replication over encrypted UDP")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    Serve {
        #[arg(long, default_value = "127.0.0.1:4433")]
        bind: SocketAddr,
        #[arg(long, default_value = ".multiplexer")]
        state: PathBuf,
        #[arg(long, default_value = "/bin/sh")]
        shell: String,
        /// Authenticate using the local Tailscale daemon instead of a shared token.
        #[arg(long, requires = "allow_user")]
        tailscale: bool,
        /// Allowed Tailscale login name; repeat to allow multiple users.
        #[arg(long, requires = "tailscale")]
        allow_user: Vec<String>,
    },
    List(Connection),
    New(SessionOptions),
    Attach {
        id: u64,
        #[command(flatten)]
        options: SessionOptions,
    },
}

#[derive(Args)]
struct Connection {
    #[arg(long, default_value = "127.0.0.1:4433")]
    server: SocketAddr,
    #[arg(long, default_value = ".multiplexer/cert.der")]
    cert: PathBuf,
    #[arg(long, default_value = ".multiplexer/token")]
    token_file: PathBuf,
    /// Use Tailscale identity, without reading or sending a shared token.
    #[arg(long, conflicts_with = "token_file")]
    tailscale: bool,
}

#[derive(Args)]
struct SessionOptions {
    #[command(flatten)]
    connection: Connection,
    #[arg(long)]
    headless: bool,
    /// Send these bytes once after the first screen (use shell quoting for newlines).
    #[arg(long, requires = "headless")]
    send: Option<String>,
    /// Stop successfully when the screen contains this text; fail on timeout.
    #[arg(long, requires = "headless")]
    expect: Option<String>,
    #[arg(long, default_value_t = 2)]
    timeout: u64,
    #[arg(long, default_value_t = 80)]
    cols: u16,
    #[arg(long, default_value_t = 24)]
    rows: u16,
}

#[tokio::main]
async fn main() -> Result<()> {
    rustls::crypto::ring::default_provider()
        .install_default()
        .ok();
    match Cli::parse().command {
        Command::Serve {
            bind,
            state,
            shell,
            tailscale,
            allow_user,
        } => {
            let server = if tailscale {
                Server::bind_tailscale(bind, &state, shell, allow_user).await?
            } else {
                Server::bind(bind, &state, shell)?
            };
            eprintln!(
                "listening on {} (UDP/QUIC); credentials in {}",
                server.endpoint.local_addr()?,
                state.display()
            );
            tokio::select! { _ = server.clone().run() => {}, result = tokio::signal::ctrl_c() => { result?; } }
            server.endpoint.close(0u32.into(), b"shutdown");
        }
        Command::List(options) => {
            let mut client = Client::connect(
                options.server,
                &options.cert,
                (!options.tailscale).then_some(options.token_file.as_path()),
                Request::List,
            )
            .await?;
            for session in client.list().await? {
                if let Some(creator) = session.creator {
                    println!(
                        "{}\t{}\t{}",
                        session.id, creator.login_name, creator.node_id
                    );
                } else {
                    println!("{}", session.id);
                }
            }
        }
        Command::New(options) => attach(None, options).await?,
        Command::Attach { id, options } => attach(Some(id), options).await?,
    }
    Ok(())
}

async fn attach(id: Option<u64>, options: SessionOptions) -> Result<()> {
    let (cols, rows) = if options.headless {
        (options.cols, options.rows)
    } else {
        crossterm::terminal::size()?
    };
    let size = Size { cols, rows };
    size.validate()?;
    let request = match id {
        Some(id) => Request::Attach { id, size },
        None => Request::Create { size },
    };
    let connection = options.connection;
    let mut client = Client::connect(
        connection.server,
        &connection.cert,
        (!connection.tailscale).then_some(connection.token_file.as_path()),
        request,
    )
    .await?;
    if options.headless {
        client
            .headless(
                options.send.as_deref(),
                options.expect.as_deref(),
                Duration::from_secs(options.timeout),
            )
            .await?;
    } else {
        client.interactive().await?;
    }
    Ok(())
}
