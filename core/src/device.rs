//! The iPhone talking to itself: lockdown and installd over LocalDevVPN (10.7.0.1) with the pairing file.

use std::net::IpAddr;
use std::time::Duration;

use idevice::IdeviceService;
use idevice::heartbeat::HeartbeatClient;
use idevice::installation_proxy::InstallationProxyClient;
use idevice::lockdown::LockdownClient;
use idevice::pairing_file::PairingFile;
use idevice::provider::{IdeviceProvider, TcpProvider};
use tokio::task::JoinHandle;

use crate::error::{QuayError, Result};

/// LocalDevVPN's address for the device itself.
pub const DEFAULT_DEVICE_ADDRESS: &str = "10.7.0.1";
const LABEL: &str = "QuayStore";

pub fn provider(pairing_file: &[u8], address: &str) -> Result<TcpProvider> {
    let pairing_file = PairingFile::from_bytes(pairing_file)
        .map_err(|_| QuayError::device("Pairing file повреждён или это не он"))?;
    let addr: IpAddr = address
        .trim()
        .parse()
        .map_err(|_| QuayError::device(format!("Неверный адрес устройства: {address}")))?;
    Ok(TcpProvider { addr, scope_id: None, pairing_file, label: LABEL.to_string() })
}

/// Keeps the connection alive while Quay works with installd (the device drops idle lockdown peers).
pub struct Heartbeat(JoinHandle<()>);

impl Heartbeat {
    pub async fn start(p: &TcpProvider) -> Result<Self> {
        let mut client = HeartbeatClient::connect(p).await.map_err(map_idevice)?;
        let handle = tokio::spawn(async move {
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
        });
        Ok(Self(handle))
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
    if lower.contains("connection refused") || lower.contains("timed out") || lower.contains("unreachable") || lower.contains("network") {
        QuayError::device("Нет связи с устройством. Включи LocalDevVPN и проверь Wi-Fi")
    } else if lower.contains("pairing") || lower.contains("invalidhostid") || lower.contains("ssl") || lower.contains("tls") {
        QuayError::device("Pairing file не подходит к этому iPhone. Сделай новый в iLoader")
    } else {
        QuayError::device(format!("Ошибка устройства: {text}"))
    }
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct DeviceInfo {
    pub name: String,
    pub udid: String,
    pub product_version: String,
    pub product_type: String,
    pub developer_mode: Option<bool>,
}

async fn lockdown_session(p: &TcpProvider) -> Result<LockdownClient> {
    let mut l = LockdownClient::connect(p).await.map_err(map_idevice)?;
    let pf = p.get_pairing_file().await.map_err(map_idevice)?;
    l.start_session(&pf).await.map_err(map_idevice)?;
    Ok(l)
}

async fn value_string(l: &mut LockdownClient, key: &str, domain: Option<&str>) -> String {
    match l.get_value(Some(key), domain).await {
        Ok(v) => v.as_string().map(str::to_string).unwrap_or_default(),
        Err(_) => String::new(),
    }
}

/// The onboarding's connection check: VPN up, pairing file valid, device answering.
#[uniffi::export(async_runtime = "tokio")]
pub async fn check_device(pairing_file: Vec<u8>, address: String) -> Result<DeviceInfo> {
    let p = provider(&pairing_file, &address)?;
    let fut = async {
        let mut l = lockdown_session(&p).await?;
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
        Ok(DeviceInfo { name, udid, product_version, product_type, developer_mode })
    };
    tokio::time::timeout(Duration::from_secs(12), fut)
        .await
        .map_err(|_| QuayError::device("Устройство не отвечает. Включи LocalDevVPN и Wi-Fi"))?
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

/// User apps installed on the device: which of the store's apps are really there.
#[uniffi::export(async_runtime = "tokio")]
pub async fn list_device_apps(pairing_file: Vec<u8>, address: String) -> Result<Vec<DeviceApp>> {
    let p = provider(&pairing_file, &address)?;
    let _hb = Heartbeat::start(&p).await.ok();
    let mut ip = InstallationProxyClient::connect(&p).await.map_err(map_idevice)?;
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
    let p = provider(&pairing_file, &address)?;
    let _hb = Heartbeat::start(&p).await.ok();
    let mut ip = InstallationProxyClient::connect(&p).await.map_err(map_idevice)?;
    ip.uninstall(bundle_id, None).await.map_err(map_idevice)?;
    Ok(())
}

/// Validates a pairing file without connecting: what the import screen says before saving it.
#[uniffi::export]
pub fn validate_pairing_file(pairing_file: Vec<u8>) -> Result<String> {
    let pf = PairingFile::from_bytes(&pairing_file)
        .map_err(|_| QuayError::device("Это не pairing file (нужен .plist или .mobiledevicepairing из iLoader)"))?;
    Ok(pf.udid.clone().unwrap_or_default())
}
