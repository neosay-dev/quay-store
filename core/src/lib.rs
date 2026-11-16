//! quay-core: everything in Quay Store that is not UI.
//!
//! Sources (AltStore format), GitHub releases, update checks, the anisette server list, IPA inspection,
//! the device connection over LocalDevVPN, and signing + installing (free Apple ID or your own certificate).
//! The Swift app calls it through UniFFI bindings (`uniffi-bindgen`, see the CI workflow).

uniffi::setup_scaffolding!();

pub mod anisette;
pub mod device;
pub mod error;
pub mod github;
pub mod http;
pub mod ipa;
pub mod ota;
pub mod signing;
pub mod source;
pub mod storage;
pub mod version;

pub use error::QuayError;

use std::sync::Once;

static INIT: Once = Once::new();

/// Call once at launch, before anything else: TLS (ring) and logging.
#[uniffi::export]
pub fn quay_init(verbose: bool) {
    INIT.call_once(|| {
        let _ = rustls::crypto::ring::default_provider().install_default();
        let _ = isideload::init();
        let level = if verbose {
            tracing::Level::DEBUG
        } else {
            tracing::Level::INFO
        };
        let _ = tracing_subscriber::fmt()
            .with_max_level(level)
            .with_ansi(false)
            .without_time()
            .try_init();
    });
}

/// The core's version, shown next to the app version in Settings.
#[uniffi::export]
pub fn core_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}
