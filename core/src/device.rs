//! The iPhone talking to itself through LocalDevVPN (10.7.0.1), two ways:
//!
//! - **Lockdown** pairing file (classic .plist / .mobiledevicepairing): lockdown on port 62078. Up to iOS 26.3.
//! - **RPPairing** file (iOS 26.4+ and 27, made by idevice_pair / StikPair / new iLoader): pair-verify on
//!   port 49152, a TLS-PSK tunnel, a software TCP stack inside the app, then services over RSD.
//!
//! Which one is used follows from the file itself.

use std::net::IpAddr;
use std::path::Path;
use std::time::Duration;

use idevice::IdeviceService;
use idevice::RsdService;
use idevice::heartbeat::HeartbeatClient;
use idevice::installation_proxy::InstallationProxyClient;
use idevice::lockdown::LockdownClient;
use idevice::pairing_file::PairingFile;
use idevice::provider::{IdeviceProvider, TcpProvider};
use idevice::remote_pairing::{RemotePairingClient, RpPairingFile, RpPairingSocket, connect_tls_psk_tunnel_native};
use idevice::rsd::RsdHandshake;
use idevice::tcp::handle::AdapterHandle;
use rootcause::prelude::*;
use tokio::net::TcpStream;
use tokio::task::JoinHandle;

use crate::error::{QuayError, Result};

pub const DEFAULT_DEVICE_ADDRESS: &str = "10.7.0.1";
const LABEL: &str = "QuayStore";
const RP_PAIRING_PORT: u16 = 49152;
const CONNECT_TIMEOUT: Duration = Duration::from_secs(15);

// ---------- pairing files ----------

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum PairingKind {
    /// Classic lockdown pairing (iOS up to 26.3).
    Lockdown,
    /// RPPairing (iOS 26.4 and newer).
    RemotePairing,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct PairingSummary {
    pub kind: PairingKind,
    /// The device's UDID, when the file says (lockdown files do).
    pub udid: Option<String>,
}

enum Pairing {
    Lockdown(PairingFile),
    Remote(RpPairingFile),
}

fn read_pairing(bytes: &[u8]) -> Result<Pairing> {
    if let Ok(p) = PairingFile::from_bytes(bytes) {
        return Ok(Pairing::Lockdown(p));
    }
    if let Ok(p) = RpPairingFile::from_bytes(bytes) {
        return Ok(Pairing::Remote(p));
    }
    Err(QuayError::device(
        "Это не pairing file. Нужен .plist из iLoader / idevice_pair (RPPairing для iOS 26.4+) или .mobiledevicepairing",
    ))
}

/// What the import screen says before saving a file.
#[uniffi::export]
pub fn inspect_pairing_file(pairing_file: Vec<u8>) -> Result<PairingSummary> {
    Ok(match read_pairing(&pairing_file)? {
        Pairing::Lockdown(p) => PairingSummary { kind: PairingKind::Lockdown, udid: p.udid.clone() },
        Pairing::Remote(_) => PairingSummary { kind: PairingKind::RemotePairing, udid: None },
    })
}

/// "10.7.0.1/32" (how LocalDevVPN shows it) → 10.7.0.1.
fn parse_address(address: &str) -> Result<IpAddr> {
    let a = address.trim();
    let a = a.split('/').next().unwrap_or(a);
    a.parse().map_err(|_| QuayError::device(format!("Неверный адрес устройства: {address}")))
}

// ---------- the connection ----------

pub enum Link {
    Lockdown { provider: TcpProvider, _heartbeat: Option<Heartbeat> },
    Rsd { adapter: AdapterHandle, handshake: RsdHandshake },
}

/// Keeps a lockdown connection alive while Quay works (the device drops idle peers).
pub struct Heartbeat(JoinHandle<()>);

impl Heartbeat {
    async fn start(p: &TcpProvider) -> Option<Self> {
        let mut client = HeartbeatClient::connect(p).await.ok()?;
        Some(Self(tokio::spawn(async move {
            let mut interval = 15u64;
            loop {
                match client.get_marco(interval).await {
                    Ok(next) => interval = next.max(5),
                    Err(_) => break,
                }
                if client.send_polo().await.is_err() {
                    break;
                }
            }
        })))
    }
}

impl Drop for Heartbeat {
    fn drop(&mut self) {
        self.0.abort();
    }
}

pub fn map_idevice(e: idevice::IdeviceError) -> QuayError {
    let text = e.to_string();
    let lower = text.to_lowercase();
    if lower.contains("permission") || lower.contains("os { code: 1") {
        QuayError::device("iOS не пускает на этот адрес. В настройках устройства должен быть адрес из LocalDevVPN «Device IP» (обычно 10.7.0.1), а не адрес самого туннеля")
    } else if lower.contains("connection refused") || lower.contains("timed out") || lower.contains("unreachable") || lower.contains("network") {
        QuayError::device("Нет связи с устройством. Включи LocalDevVPN и попробуй ещё раз")
    } else if lower.contains("pairverify") || lower.contains("pair-verify") || lower.contains("pairing") || lower.contains("invalidhostid") || lower.contains("ssl") || lower.contains("tls") {
        QuayError::device("Pairing file не подходит к этому iPhone. Сделай новый (на iOS 26.4+ нужен RPPairing)")
    } else {
        QuayError::device(format!("Ошибка устройства: {text}"))
    }
}

fn io_err(e: std::io::Error) -> QuayError {
    map_idevice(idevice::IdeviceError::InternalError(e.to_string()))
}

pub async fn connect(pairing_file: &[u8], address: &str) -> Result<Link> {
    let ip = parse_address(address)?;
    let pairing = read_pairing(pairing_file)?;
    tokio::time::timeout(CONNECT_TIMEOUT, async move {
        match pairing {
            Pairing::Lockdown(pairing_file) => {
                let provider = TcpProvider { addr: ip, scope_id: None, pairing_file, label: LABEL.to_string() };
                let heartbeat = Heartbeat::start(&provider).await;
                Ok(Link::Lockdown { provider, _heartbeat: heartbeat })
            }
            Pairing::Remote(mut rp) => {
                let stream = TcpStream::connect((ip, RP_PAIRING_PORT)).await.map_err(io_err)?;
                let mut rpc = RemotePairingClient::new(RpPairingSocket::new(stream), LABEL);
                // Verify only: a new pairing would need the code from the device's screen.
                rpc.attempt_pair_verify().await.map_err(map_idevice)?;
                rpc.validate_pairing(&mut rp).await.map_err(|_| {
                    QuayError::device("iPhone не принял этот RPPairing file. Сделай новый в idevice_pair или iLoader")
                })?;
                let tunnel_port = rpc.create_tcp_listener().await.map_err(map_idevice)?;
                let tunnel_stream = TcpStream::connect((ip, tunnel_port)).await.map_err(io_err)?;
                let tunnel = connect_tls_psk_tunnel_native(tunnel_stream, rpc.encryption_key())
                    .await
                    .map_err(map_idevice)?;
                let client_ip: IpAddr = tunnel.info.client_address.parse().map_err(|_| QuayError::device("Туннель дал неверный адрес"))?;
                let server_ip: IpAddr = tunnel.info.server_address.parse().map_err(|_| QuayError::device("Туннель дал неверный адрес"))?;
                let mtu = tunnel.info.mtu as usize;
                let rsd_port = tunnel.info.server_rsd_port;
                let mut adapter = idevice::tcp::adapter::Adapter::new(Box::new(tunnel.into_inner()), client_ip, server_ip);
                adapter.set_mss(mtu.clamp(1280, 8192) - 60);
                let mut adapter = adapter.to_async_handle();
                let rsd_stream = adapter.connect(rsd_port).await.map_err(io_err)?;
                let handshake = RsdHandshake::new(rsd_stream).await.map_err(map_idevice)?;
                Ok(Link::Rsd { adapter, handshake })
            }
        }
    })
    .await
    .map_err(|_| QuayError::device("Устройство не отвечает. Включи LocalDevVPN"))?
}

impl Link {
    async fn lockdown(&mut self) -> Result<LockdownClient> {
        match self {
            Link::Lockdown { provider, .. } => {
                let mut l = LockdownClient::connect(provider).await.map_err(map_idevice)?;
                let pf = provider.get_pairing_file().await.map_err(map_idevice)?;
                l.start_session(&pf).await.map_err(map_idevice)?;
                Ok(l)
            }
            // Over RSD lockdown is already trusted: no session.
            Link::Rsd { adapter, handshake } => LockdownClient::connect_rsd(adapter, handshake).await.map_err(map_idevice),
        }
    }

    async fn installation_proxy(&mut self) -> Result<InstallationProxyClient> {
        match self {
            Link::Lockdown { provider, .. } => InstallationProxyClient::connect(provider).await.map_err(map_idevice),
            Link::Rsd { adapter, handshake } => InstallationProxyClient::connect_rsd(adapter, handshake).await.map_err(map_idevice),
        }
    }

    pub async fn info(&mut self) -> Result<DeviceInfo> {
        let mut l = self.lockdown().await?;
        let name = value_string(&mut l, "DeviceName", None).await;
        let udid = value_string(&mut l, "UniqueDeviceID", None).await;
        let product_version = value_string(&mut l, "ProductVersion", None).await;
        let product_type = value_string(&mut l, "ProductType", None).await;
        let developer_mode = l
            .get_value(Some("DeveloperModeStatus"), Some("com.apple.security.mac.amfi"))
            .await
            .ok()
            .and_then(|v| v.as_boolean());
        if udid.is_empty() {
            return Err(QuayError::device("Устройство не сообщило UDID. Сделай новый pairing file"));
        }
        let kind = match self {
            Link::Lockdown { .. } => PairingKind::Lockdown,
            Link::Rsd { .. } => PairingKind::RemotePairing,
        };
        Ok(DeviceInfo { name, udid, product_version, product_type, developer_mode, connection: kind })
    }

    /// Uploads a signed .app and installs it (progress 0–100: upload to 70, install after).
    pub async fn install(&mut self, app_dir: &Path, progress: impl Fn(u64) + Send + Sync) -> std::result::Result<(), Report> {
        match self {
            Link::Lockdown { provider, .. } => isideload::sideload::install::install_app(provider, app_dir, progress).await,
            Link::Rsd { adapter, handshake } => isideload::sideload::install::install_app_rsd(adapter, handshake, app_dir, progress).await,
        }
    }
}

async fn value_string(l: &mut LockdownClient, key: &str, domain: Option<&str>) -> String {
    match l.get_value(Some(key), domain).await {
        Ok(v) => v.as_string().map(str::to_string).unwrap_or_default(),
        Err(_) => String::new(),
    }
}

// ---------- exported ----------

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct DeviceInfo {
    pub name: String,
    pub udid: String,
    pub product_version: String,
    pub product_type: String,
    pub developer_mode: Option<bool>,
    pub connection: PairingKind,
}

/// The onboarding's connection check: VPN up, pairing file valid, device answering.
#[uniffi::export(async_runtime = "tokio")]
pub async fn check_device(pairing_file: Vec<u8>, address: String) -> Result<DeviceInfo> {
    let mut link = connect(&pairing_file, &address).await?;
    tokio::time::timeout(CONNECT_TIMEOUT, link.info())
        .await
        .map_err(|_| QuayError::device("Устройство не отвечает. Включи LocalDevVPN"))?
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct DeviceApp {
    pub bundle_id: String,
    pub name: String,
    pub version: String,
    pub build_version: Option<String>,
    /// Signed by a development profile (sideloaded), not from the App Store.
    pub is_sideloaded: bool,
}

/// User apps on the device: which of the store's apps are really there.
#[uniffi::export(async_runtime = "tokio")]
pub async fn list_device_apps(pairing_file: Vec<u8>, address: String) -> Result<Vec<DeviceApp>> {
    let mut link = connect(&pairing_file, &address).await?;
    let mut ip = link.installation_proxy().await?;
    let apps = ip.get_apps(Some("User"), None).await.map_err(map_idevice)?;
    let mut out: Vec<DeviceApp> = apps
        .into_iter()
        .filter_map(|(bundle_id, v)| {
            let d = v.as_dictionary()?;
            let g = |k: &str| d.get(k).and_then(|v| v.as_string()).map(str::to_string);
            Some(DeviceApp {
                name: g("CFBundleDisplayName").or_else(|| g("CFBundleName")).unwrap_or_else(|| bundle_id.clone()),
                version: g("CFBundleShortVersionString").unwrap_or_default(),
                build_version: g("CFBundleVersion"),
                is_sideloaded: g("SignerIdentity")
                    .map(|s| s.contains("Development") || s.contains("Developer"))
                    .unwrap_or(false)
                    || d.get("ProfileValidated").and_then(|v| v.as_boolean()).unwrap_or(false),
                bundle_id,
            })
        })
        .collect();
    out.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()));
    Ok(out)
}

#[uniffi::export(async_runtime = "tokio")]
pub async fn uninstall_app(pairing_file: Vec<u8>, address: String, bundle_id: String) -> Result<()> {
    let mut link = connect(&pairing_file, &address).await?;
    let mut ip = link.installation_proxy().await?;
    ip.uninstall(bundle_id, None).await.map_err(map_idevice)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn addresses() {
        assert_eq!(parse_address("10.7.0.1").unwrap().to_string(), "10.7.0.1");
        assert_eq!(parse_address(" 10.7.0.1/32 ").unwrap().to_string(), "10.7.0.1");
        assert!(parse_address("nope").is_err());
    }

    #[test]
    fn rejects_junk_pairing() {
        assert!(inspect_pairing_file(b"not a plist".to_vec()).is_err());
    }
}
