//! A pairing file without a computer (iOS 27+): Quay pretends to be a Mac that wants to pair.
//!
//! Swift advertises the service over Bonjour; the user opens Settings → Privacy & Security → Developer Mode →
//! "Pair with Quay Store" and types the PIN Quay shows. The result is an RPPairing file, the same kind
//! idevice_pair makes, used for installs through LocalDevVPN.

use std::sync::OnceLock;
use std::time::Duration;

use idevice::remote_pairing::{PairableHost, PairableHostInfo, RpPairingFile, RpPairingSocket};
use tokio::net::TcpListener;
use tokio::sync::Notify;

use crate::error::{QuayError, Result};

const HOST_NAME: &str = "Quay Store";
const WAIT_FOR: Duration = Duration::from_secs(10 * 60);

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct TxtEntry {
    pub key: String,
    pub value: String,
}

#[uniffi::export(callback_interface)]
pub trait PairingHostObserver: Send + Sync {
    /// Publish `_remotepairing-pairable-host._tcp` named `service_name` on `port` with these TXT records.
    fn advertise(&self, service_name: String, port: u16, txt: Vec<TxtEntry>);
    /// The code to type on the device.
    fn show_pin(&self, pin: String);
}

fn cancel() -> &'static Notify {
    static N: OnceLock<Notify> = OnceLock::new();
    N.get_or_init(Notify::new)
}

#[uniffi::export]
pub fn cancel_pairing() {
    cancel().notify_waiters();
}

/// Waits (up to 10 minutes) for the device to pair; returns the RPPairing file.
#[uniffi::export(async_runtime = "tokio")]
pub async fn pair_this_device(observer: Box<dyn PairingHostObserver>) -> Result<Vec<u8>> {
    // shortcut: fresh keys and alt_irk each time, so an older Quay pairing stops working; persist them if that matters.
    let mut file = RpPairingFile::generate(HOST_NAME);
    let info = PairableHostInfo::generate(HOST_NAME, "Mac17,7");
    let listener = match TcpListener::bind("[::]:0").await {
        Ok(l) => l,
        Err(_) => TcpListener::bind("0.0.0.0:0").await?,
    };
    let port = listener.local_addr()?.port();
    let service_name = file.identifier().to_string();
    let txt = info
        .mdns_txt_records(&service_name)
        .into_iter()
        .map(|(key, value)| TxtEntry { key, value })
        .collect();
    observer.advertise(service_name, port, txt);

    let wait = async {
        loop {
            let (stream, _) = listener.accept().await?;
            let mut host = PairableHost::new(RpPairingSocket::new_device(stream), info.clone());
            let shown = host
                .accept(&mut file, |pin| {
                    observer.show_pin(pin);
                    std::future::ready(())
                })
                .await;
            match shown {
                Ok(_) => return Ok::<Vec<u8>, QuayError>(file.to_bytes()),
                // The device may probe first or the user may type a wrong PIN: keep listening.
                Err(e) => tracing::warn!("pairing attempt failed: {e}"),
            }
        }
    };
    tokio::select! {
        r = tokio::time::timeout(WAIT_FOR, wait) => r.map_err(|_| QuayError::device("iPhone не начал сопряжение за 10 минут"))?,
        _ = cancel().notified() => Err(QuayError::Cancelled),
    }
}
