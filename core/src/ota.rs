//! Serves one signed .ipa on 127.0.0.1 so iOS can install it through itms-services (no pairing file).

use std::time::Duration;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

use crate::error::{QuayError, Result};

/// How long the file stays available: iOS starts the download only after the user taps "Install".
const SERVE_FOR: Duration = Duration::from_secs(15 * 60);

/// Starts serving `path` at http://127.0.0.1:<port>/<anything>; returns the port.
#[uniffi::export(async_runtime = "tokio")]
pub async fn serve_ipa(path: String) -> Result<u16> {
    let len = tokio::fs::metadata(&path).await?.len();
    let listener = TcpListener::bind(("127.0.0.1", 0))
        .await
        .map_err(|e| QuayError::install(format!("Не удалось запустить локальный сервер: {e}")))?;
    let port = listener.local_addr()?.port();
    tokio::spawn(async move {
        let _ = tokio::time::timeout(SERVE_FOR, async {
            loop {
                let Ok((stream, _)) = listener.accept().await else { break };
                let path = path.clone();
                tokio::spawn(async move {
                    let _ = respond(stream, &path, len).await;
                });
            }
        })
        .await;
    });
    Ok(port)
}

// shortcut: no Range support (installd downloads in one request), add it if resumed downloads appear.
async fn respond(mut stream: TcpStream, path: &str, len: u64) -> std::io::Result<()> {
    let mut buf = vec![0u8; 8192];
    let mut read = 0;
    while !buf[..read].windows(4).any(|w| w == b"\r\n\r\n") {
        if read == buf.len() {
            return Ok(());
        }
        let n = stream.read(&mut buf[read..]).await?;
        if n == 0 {
            return Ok(());
        }
        read += n;
    }
    let head = String::from_utf8_lossy(&buf[..read]);
    let is_head = head.starts_with("HEAD ");
    if !is_head && !head.starts_with("GET ") {
        stream.write_all(b"HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").await?;
        return Ok(());
    }
    let header = format!(
        "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: {len}\r\nConnection: close\r\n\r\n"
    );
    stream.write_all(header.as_bytes()).await?;
    if !is_head {
        let mut file = tokio::fs::File::open(path).await?;
        tokio::io::copy(&mut file, &mut stream).await?;
    }
    stream.shutdown().await
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};

    #[tokio::test]
    async fn serves_the_file() {
        let path = std::env::temp_dir().join(format!("quay-ota-{}.ipa", std::process::id()));
        std::fs::write(&path, b"hello ipa").unwrap();
        let port = serve_ipa(path.to_string_lossy().into()).await.unwrap();
        let body = tokio::task::spawn_blocking(move || {
            let mut s = std::net::TcpStream::connect(("127.0.0.1", port)).unwrap();
            s.write_all(b"GET /app.ipa HTTP/1.1\r\nHost: x\r\n\r\n").unwrap();
            let mut out = String::new();
            s.read_to_string(&mut out).unwrap();
            out
        })
        .await
        .unwrap();
        assert!(body.starts_with("HTTP/1.1 200"));
        assert!(body.contains("Content-Length: 9"));
        assert!(body.ends_with("hello ipa"));
        std::fs::remove_file(path).unwrap();
    }
}
