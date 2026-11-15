//! Anisette servers: they stand in for a Mac when signing in with an Apple ID.
//! The public list is SideStore's; Quay checks each one itself (anisette v3 is what isideload speaks).

use std::time::Instant;

use serde::Deserialize;

use crate::error::{QuayError, Result};
use crate::http;

pub const SERVER_LISTS: &[&str] = &[
    "https://servers.sidestore.io/servers.json",
    "https://raw.githubusercontent.com/SideStore/anisette-servers/main/servers.json",
];

/// Works with isideload out of the box (iLoader's default).
pub const DEFAULT_SERVER: &str = "https://ani.iloader.app";

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct AnisetteServer {
    pub name: String,
    pub address: String,
}

#[derive(Deserialize)]
struct ListFile {
    servers: Vec<ListEntry>,
}

#[derive(Deserialize)]
struct ListEntry {
    name: String,
    address: String,
}

/// The built-in default first, then the public list (whichever mirror answers).
#[uniffi::export(async_runtime = "tokio")]
pub async fn fetch_anisette_servers() -> Result<Vec<AnisetteServer>> {
    let mut out = vec![AnisetteServer { name: "iLoader".into(), address: DEFAULT_SERVER.into() }];
    let mut last_err = None;
    for list in SERVER_LISTS {
        match http::get_text(list).await {
            Ok(text) => match serde_json::from_str::<ListFile>(&text) {
                Ok(file) => {
                    for e in file.servers {
                        let address = e.address.trim().trim_end_matches('/').to_string();
                        if !out.iter().any(|s| s.address == address) {
                            out.push(AnisetteServer { name: e.name, address });
                        }
                    }
                    return Ok(out);
                }
                Err(e) => last_err = Some(QuayError::network(format!("Список серверов не читается: {e}"))),
            },
            Err(e) => last_err = Some(e),
        }
    }
    // Offline: the default alone still lets you sign in.
    if out.len() == 1 && last_err.is_some() {
        tracing::warn!("anisette list unavailable: {:?}", last_err);
    }
    Ok(out)
}

/// Milliseconds for the server's v3 client info, or an error if it does not speak anisette v3.
#[uniffi::export(async_runtime = "tokio")]
pub async fn check_anisette_server(address: String) -> Result<u64> {
    let url = format!("{}/v3/client_info", address.trim_end_matches('/'));
    let started = Instant::now();
    let resp = http::client()
        .get(&url)
        .timeout(std::time::Duration::from_secs(8))
        .send()
        .await?;
    if !resp.status().is_success() {
        return Err(QuayError::network(format!("Сервер ответил {}", resp.status().as_u16())));
    }
    let body: serde_json::Value = resp
        .json()
        .await
        .map_err(|_| QuayError::network("Сервер не поддерживает anisette v3"))?;
    if body.get("client_info").is_none() && body.get("clientInfo").is_none() {
        return Err(QuayError::network("Сервер не поддерживает anisette v3"));
    }
    Ok(started.elapsed().as_millis() as u64)
}
