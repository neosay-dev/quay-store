//! One HTTP client for sources, GitHub and anisette checks.

use std::sync::OnceLock;
use std::time::Duration;

use crate::error::{QuayError, Result};

pub const USER_AGENT: &str = concat!("QuayStore/", env!("CARGO_PKG_VERSION"));

pub fn client() -> &'static reqwest::Client {
    static CLIENT: OnceLock<reqwest::Client> = OnceLock::new();
    CLIENT.get_or_init(|| {
        let _ = rustls::crypto::ring::default_provider().install_default();
        reqwest::Client::builder()
            .user_agent(USER_AGENT)
            .connect_timeout(Duration::from_secs(10))
            .timeout(Duration::from_secs(30))
            .build()
            .expect("HTTP client")
    })
}

/// GET a URL as text; non-2xx statuses become readable errors.
pub async fn get_text(url: &str) -> Result<String> {
    let resp = client().get(url).send().await?;
    let status = resp.status();
    if !status.is_success() {
        return Err(QuayError::network(format!(
            "Сервер ответил {} для {url}",
            status.as_u16()
        )));
    }
    Ok(resp.text().await?)
}

/// What a download URL currently points at, without downloading it: ETag, Last-Modified and size.
/// A changed fingerprint for the same version means the IPA was rebuilt.
#[uniffi::export(async_runtime = "tokio")]
pub async fn remote_fingerprint(url: String) -> Result<Option<String>> {
    let resp = client().head(&url).send().await?;
    if !resp.status().is_success() {
        return Ok(None);
    }
    let h = resp.headers();
    let get = |k: &str| h.get(k).and_then(|v| v.to_str().ok()).map(str::to_string);
    let parts: Vec<String> = [get("etag"), get("last-modified"), get("content-length")]
        .into_iter()
        .flatten()
        .collect();
    Ok(if parts.is_empty() { None } else { Some(parts.join("|")) })
}
