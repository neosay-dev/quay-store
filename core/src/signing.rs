//! Signing and installing: a free Apple ID (isideload: certificate, App IDs, 7-day profiles) or your own
//! certificate (.p12 + .mobileprovision). Both end in installd over LocalDevVPN.
//!
//! Questions for the user (2FA code, which certificates to revoke) go to the Swift observer; the answer comes
//! back through `answer_two_factor` / `answer_certificates`, while the Rust side waits.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex as StdMutex, OnceLock, RwLock};
use std::time::{SystemTime, UNIX_EPOCH};

use apple_codesign_quick::{BundleSigningSettings, ProvisioningProfile, RustCryptoCmsSigner, sign_bundle};
use isideload::anisette::remote_v3::RemoteV3AnisetteProvider;
use isideload::auth::apple_account::{AppleAccount, TwoFactorCallbackParams, TwoFactorCallbackResponse};
use isideload::dev::certificates::DevelopmentCertificate;
use isideload::dev::developer_session::DeveloperSession;
use isideload::dev::devices::DevicesApi;
use isideload::dev::teams::DeveloperTeam;
use isideload::sideload::application::Application;
use isideload::sideload::builder::{ExtensionsBehavior, ExtensionsBehaviorSelection, MaxCertsBehavior};
use isideload::sideload::cert_identity::CertificateIdentity;
use isideload::sideload::sideloader::Sideloader;
use isideload::sideload::{SideloaderBuilder, TeamSelection};
use isideload::util::callbacks::{ExtensionsBehaviorCallbackBox, MaxCertsCallbackBox};
use isideload::util::storage::SideloadingStorage;
use rootcause::prelude::*;
use rsa::RsaPrivateKey;
use tokio::sync::{Mutex, oneshot};
use x509_cert::Certificate;
use x509_cert::der::Decode;

use crate::device;
use crate::error::{QuayError, Result};
use crate::storage::FileStorage;

// ---------- what Swift sees ----------

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum InstallStage {
    Connecting,
    SigningIn,
    Registering,
    Signing,
    Uploading,
    Installing,
    Done,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct TrustedPhone {
    pub id: u32,
    pub number: String,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct TwoFactorRequest {
    /// The code went by SMS (else to trusted devices).
    pub sms: bool,
    /// The last method failed or it is unclear what works: offer every option.
    pub unknown: bool,
    pub phones: Vec<TrustedPhone>,
    pub selected_phone_id: Option<u32>,
    pub last_error: Option<String>,
}

#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum TwoFactorAnswer {
    Code { code: String },
    SendSms { phone_id: u32 },
    SendToDevices,
    Resend,
    Cancel,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct DevCertificate {
    pub serial: String,
    pub name: String,
    pub machine_name: String,
}

#[uniffi::export(callback_interface)]
pub trait SigningObserver: Send + Sync {
    fn progress(&self, stage: InstallStage, fraction: f32);
    /// Show the 2FA sheet; answer with `answer_two_factor`.
    fn two_factor_required(&self, request: TwoFactorRequest);
    /// The account has the most certificates it may have; answer with `answer_certificates`
    /// (the serials to revoke, or None to stop).
    fn certificates_full(&self, certificates: Vec<DevCertificate>);
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct AccountInfo {
    pub email: String,
    pub team_id: String,
    pub team_name: String,
    /// A free (personal team) account: 3 apps, 10 App IDs a week, 7-day profiles.
    pub is_free: bool,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct InstallOutcome {
    /// The bundle id on the device (free accounts append the team id).
    pub installed_bundle_id: String,
    pub app_name: String,
    pub version: String,
    pub build_version: Option<String>,
    /// When the profile runs out (unix seconds).
    pub expires_at: Option<i64>,
}

// ---------- prompts ----------

fn observer_slot() -> &'static RwLock<Option<Arc<dyn SigningObserver>>> {
    static S: OnceLock<RwLock<Option<Arc<dyn SigningObserver>>>> = OnceLock::new();
    S.get_or_init(|| RwLock::new(None))
}

fn set_observer(o: Arc<dyn SigningObserver>) {
    if let Ok(mut g) = observer_slot().write() {
        *g = Some(o);
    }
}

fn observer() -> Option<Arc<dyn SigningObserver>> {
    observer_slot().read().ok().and_then(|g| g.clone())
}

fn notify(stage: InstallStage, fraction: f32) {
    if let Some(o) = observer() {
        o.progress(stage, fraction.clamp(0.0, 1.0));
    }
}

static TWO_FACTOR: StdMutex<Option<oneshot::Sender<TwoFactorAnswer>>> = StdMutex::new(None);
static CERTS: StdMutex<Option<oneshot::Sender<Option<Vec<String>>>>> = StdMutex::new(None);
/// Per install: register App IDs for extensions (true) or reuse the app's own (saves the weekly 10).
static REGISTER_EXTENSIONS: AtomicBool = AtomicBool::new(true);

#[uniffi::export]
pub fn answer_two_factor(answer: TwoFactorAnswer) {
    if let Some(tx) = TWO_FACTOR.lock().ok().and_then(|mut g| g.take()) {
        let _ = tx.send(answer);
    }
}

#[uniffi::export]
pub fn answer_certificates(revoke_serials: Option<Vec<String>>) {
    if let Some(tx) = CERTS.lock().ok().and_then(|mut g| g.take()) {
        let _ = tx.send(revoke_serials);
    }
}

async fn ask_two_factor(params: TwoFactorCallbackParams) -> std::result::Result<TwoFactorCallbackResponse, Report> {
    let (tx, rx) = oneshot::channel();
    if let Ok(mut g) = TWO_FACTOR.lock() {
        *g = Some(tx);
    }
    let request = TwoFactorRequest {
        sms: params.sms,
        unknown: params.unknown,
        phones: params
            .numbers
            .iter()
            .map(|n| TrustedPhone { id: n.id, number: n.number_with_dial_code.clone() })
            .collect(),
        selected_phone_id: params.selected_number_id,
        last_error: params.last_error.clone(),
    };
    match observer() {
        Some(o) => o.two_factor_required(request),
        None => return Ok(TwoFactorCallbackResponse::Abort),
    }
    Ok(match rx.await.unwrap_or(TwoFactorAnswer::Cancel) {
        TwoFactorAnswer::Code { code } => TwoFactorCallbackResponse::SubmitCode(code.trim().to_string()),
        TwoFactorAnswer::SendSms { phone_id } => TwoFactorCallbackResponse::SendSms(phone_id),
        TwoFactorAnswer::SendToDevices => TwoFactorCallbackResponse::SendToDevices,
        TwoFactorAnswer::Resend => TwoFactorCallbackResponse::ResendCode,
        TwoFactorAnswer::Cancel => TwoFactorCallbackResponse::Abort,
    })
}

fn max_certs_callback() -> MaxCertsCallbackBox {
    Box::new(|certs: Vec<DevelopmentCertificate>| {
        Box::pin(async move {
            let (tx, rx) = oneshot::channel();
            if let Ok(mut g) = CERTS.lock() {
                *g = Some(tx);
            }
            let list = certs
                .iter()
                .map(|c| DevCertificate {
                    serial: c.serial_number.clone().unwrap_or_default(),
                    name: c.name.clone().unwrap_or_default(),
                    machine_name: c.machine_name.clone().unwrap_or_default(),
                })
                .collect();
            match observer() {
                Some(o) => o.certificates_full(list),
                None => return Ok(None),
            }
            Ok(rx.await.unwrap_or(None))
        })
    })
}

fn extensions_callback() -> ExtensionsBehaviorCallbackBox {
    Box::new(|_extensions: &[isideload::sideload::bundle::Bundle]| {
        Box::pin(async move {
            Ok(if REGISTER_EXTENSIONS.load(Ordering::Relaxed) {
                ExtensionsBehavior::RegisterAll
            } else {
                ExtensionsBehavior::ReuseMain
            })
        })
    })
}

// ---------- the Apple ID session ----------

/// One storage for anisette and the sideloader, shared (two copies of the same file would overwrite each other).
#[derive(Clone)]
struct SharedStorage(Arc<FileStorage>);

impl SideloadingStorage for SharedStorage {
    fn store(&self, key: &str, value: &str) -> std::result::Result<(), Report> {
        self.0.store(key, value)
    }
    fn retrieve(&self, key: &str) -> std::result::Result<Option<String>, Report> {
        self.0.retrieve(key)
    }
}

type Loader = Sideloader<MaxCertsCallbackBox, ExtensionsBehaviorCallbackBox>;

struct Session {
    info: AccountInfo,
    loader: Loader,
    team: DeveloperTeam,
}

fn session() -> &'static Mutex<Option<Session>> {
    static S: OnceLock<Mutex<Option<Session>>> = OnceLock::new();
    S.get_or_init(|| Mutex::new(None))
}

fn report_text(r: &Report) -> String {
    let full = format!("{r}");
    let lower = full.to_lowercase();
    if lower.contains("-20101") || lower.contains("incorrect") || lower.contains("password") {
        "Неверный Apple ID или пароль".into()
    } else if lower.contains("anisette") {
        "Anisette-сервер не отвечает. Выбери другой в настройках".into()
    } else if lower.contains("abort") {
        "Вход отменён".into()
    } else if lower.contains("7460") || lower.contains("too many") || lower.contains("maximum number of app ids") {
        "Лимит бесплатного аккаунта: не больше 10 новых App ID за 7 дней. Подожди или переиспользуй приложения".into()
    } else if lower.contains("3 apps") || lower.contains("maximum number of apps") || lower.contains("0xe8008021") {
        "Лимит бесплатного аккаунта: не больше 3 активных приложений. Удали одно из подписанных".into()
    } else {
        full.lines().next().unwrap_or("Неизвестная ошибка").to_string()
    }
}

/// Signs in (2FA through the observer) and keeps the session for installs until the app quits.
#[uniffi::export(async_runtime = "tokio")]
pub async fn apple_id_sign_in(
    email: String,
    password: String,
    anisette_url: String,
    storage_dir: String,
    observer: Box<dyn SigningObserver>,
) -> Result<AccountInfo> {
    crate::quay_init(false);
    set_observer(Arc::from(observer));
    notify(InstallStage::SigningIn, 0.1);

    let storage = SharedStorage(Arc::new(FileStorage::open(&storage_dir)));
    let anisette = RemoteV3AnisetteProvider::new(&anisette_url, Box::new(storage.clone()), "0".to_string())
        .map_err(|e| QuayError::auth(report_text(&e)))?;

    let mut account: AppleAccount = AppleAccount::builder(&email)
        .anisette_provider(anisette)
        .login(&password, ask_two_factor)
        .await
        .map_err(|e| QuayError::auth(report_text(&e)))?;
    notify(InstallStage::SigningIn, 0.6);

    let dev_session = DeveloperSession::from_account(&mut account)
        .await
        .map_err(|e| QuayError::auth(format!("Не удалось открыть аккаунт разработчика: {}", report_text(&e))))?;

    let mut loader: Loader = SideloaderBuilder::new(dev_session, email.clone())
        .team_selection(TeamSelection::First)
        .max_certs_behavior(MaxCertsBehavior::Prompt(max_certs_callback()))
        .extensions_behavior(ExtensionsBehaviorSelection::Prompt(extensions_callback()))
        .storage(Box::new(storage))
        .machine_name("Quay Store".to_string())
        .delete_app_after_install(true)
        .build();

    let team = loader.get_team().await.map_err(|e| QuayError::auth(report_text(&e)))?;
    let team_name = team.name.clone().unwrap_or_default();
    let info = AccountInfo {
        email,
        team_id: team.team_id.clone(),
        is_free: team_name.contains("Personal Team"),
        team_name,
    };
    *session().lock().await = Some(Session { info: info.clone(), loader, team });
    notify(InstallStage::SigningIn, 1.0);
    Ok(info)
}

#[uniffi::export(async_runtime = "tokio")]
pub async fn apple_id_current() -> Option<AccountInfo> {
    session().lock().await.as_ref().map(|s| s.info.clone())
}

#[uniffi::export(async_runtime = "tokio")]
pub async fn apple_id_sign_out() {
    *session().lock().await = None;
}

/// Free Apple ID: register this device, sign (App IDs, profile) and install.
#[uniffi::export(async_runtime = "tokio")]
pub async fn install_with_apple_id(
    ipa_path: String,
    pairing_file: Vec<u8>,
    device_address: String,
    increased_memory_limit: bool,
    register_extensions: bool,
    observer: Box<dyn SigningObserver>,
) -> Result<InstallOutcome> {
    set_observer(Arc::from(observer));
    REGISTER_EXTENSIONS.store(register_extensions, Ordering::Relaxed);

    notify(InstallStage::Connecting, 0.0);
    let mut link = device::connect(&pairing_file, &device_address).await?;
    let dev = link.info().await?;

    let mut guard = session().lock().await;
    let s = guard
        .as_mut()
        .ok_or_else(|| QuayError::auth("Сначала войди в Apple ID"))?;

    notify(InstallStage::Registering, 0.0);
    let team = s.team.clone();
    s.loader
        .get_dev_session()
        .ensure_device_registered(&team, &dev.name, &dev.udid, None)
        .await
        .map_err(|e| QuayError::signing(format!("Не удалось добавить iPhone в аккаунт: {}", report_text(&e))))?;

    notify(InstallStage::Signing, 0.0);
    // An installed .app being signed again (Quay refreshing itself) already carries ".TEAMID": isideload would add it twice.
    if Path::new(&ipa_path).is_dir() {
        strip_team_suffix(Path::new(&ipa_path), &team.team_id)?;
    }
    let (signed_dir, _special) = s
        .loader
        .sign_app(
            PathBuf::from(&ipa_path),
            Some(team),
            increased_memory_limit,
            Some(|f: f32| {
                notify(InstallStage::Signing, f);
                std::future::ready(())
            }),
            None,
            Some(&dev.udid),
        )
        .await
        .map_err(|e| QuayError::signing(report_text(&e)))?;
    drop(guard);

    let outcome = describe_signed(&signed_dir);
    install_signed(&mut link, &signed_dir).await?;
    cleanup_extracted(&signed_dir);
    notify(InstallStage::Done, 1.0);
    outcome
}

// ---------- your own certificate ----------

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CertificateSummary {
    pub common_name: String,
    pub team_id: String,
    pub team_name: String,
    pub profile_name: String,
    /// "TEAMID.com.example.*" or an exact one.
    pub app_id: String,
    pub is_wildcard: bool,
    /// The earlier of the certificate's and the profile's end (unix seconds).
    pub expires_at: Option<i64>,
    pub provisions_all_devices: bool,
    pub device_udids: Vec<String>,
    /// The profile was made for this certificate.
    pub certificate_in_profile: bool,
}

fn load_identity(p12: &[u8], password: &str) -> Result<CertificateIdentity> {
    use p12_keystore::{KeyStore, Pkcs12ImportPolicy};
    let ks = KeyStore::from_pkcs12(p12, password, Pkcs12ImportPolicy::Strict)
        .or_else(|_| KeyStore::from_pkcs12(p12, password, Pkcs12ImportPolicy::Relaxed))
        .map_err(|_| QuayError::signing("Не удалось открыть .p12: неверный пароль или файл повреждён"))?;
    let (_, chain) = ks
        .private_key_chain()
        .ok_or_else(|| QuayError::signing("В .p12 нет ключа с сертификатом"))?;
    let cert_der = chain
        .certs()
        .first()
        .ok_or_else(|| QuayError::signing("В .p12 нет сертификата"))?
        .as_der()
        .to_vec();
    let key_der = chain.key().as_der();
    let private_key = {
        use rsa::pkcs1::DecodeRsaPrivateKey;
        use rsa::pkcs8::DecodePrivateKey;
        RsaPrivateKey::from_pkcs8_der(key_der)
            .or_else(|_| RsaPrivateKey::from_pkcs1_der(key_der))
            .map_err(|_| QuayError::signing("Ключ в .p12 не RSA: такой сертификат Apple не выдаёт"))?
    };
    let certificate = Certificate::from_der(&cert_der)
        .map_err(|_| QuayError::signing("Сертификат в .p12 повреждён"))?;
    Ok(CertificateIdentity {
        machine_id: String::new(),
        machine_name: String::new(),
        private_key,
        certificate,
    })
}

fn parse_profile(bytes: &[u8]) -> Result<ProvisioningProfile> {
    ProvisioningProfile::parse(bytes).map_err(|_| QuayError::signing("Это не .mobileprovision или он повреждён"))
}

fn date_secs(v: Option<&plist::Value>) -> Option<i64> {
    let d = v?.as_date()?;
    let t: SystemTime = d.into();
    t.duration_since(UNIX_EPOCH).ok().map(|d| d.as_secs() as i64)
}

fn subject_cn(c: &Certificate) -> String {
    let s = c.tbs_certificate.subject.to_string();
    s.split(',')
        .find_map(|p| p.trim().strip_prefix("CN=").map(str::to_string))
        .unwrap_or(s)
}

/// What the certificate import screen shows, and whether the pair fits together.
#[uniffi::export]
pub fn inspect_certificate(p12: Vec<u8>, password: String, mobileprovision: Vec<u8>) -> Result<CertificateSummary> {
    use x509_cert::der::Encode;
    let id = load_identity(&p12, &password)?;
    let profile = parse_profile(&mobileprovision)?;
    let pl = profile.plist();
    let st = |k: &str| pl.get(k).and_then(|v| v.as_string()).unwrap_or_default().to_string();
    let app_id = profile
        .entitlements()
        .get("application-identifier")
        .and_then(|v| v.as_string())
        .unwrap_or_default()
        .to_string();
    let devices = pl
        .get("ProvisionedDevices")
        .and_then(|v| v.as_array())
        .map(|a| a.iter().filter_map(|v| v.as_string().map(str::to_string)).collect())
        .unwrap_or_default();
    let cert_der = id.certificate.to_der().unwrap_or_default();
    let in_profile = profile.certificate_chain_der().iter().any(|c| *c == cert_der);
    let cert_end = id.certificate.tbs_certificate.validity.not_after.to_unix_duration().as_secs() as i64;
    let prof_end = date_secs(pl.get("ExpirationDate"));
    Ok(CertificateSummary {
        common_name: subject_cn(&id.certificate),
        team_id: profile.team_id().to_string(),
        team_name: st("TeamName"),
        profile_name: st("Name"),
        is_wildcard: app_id.ends_with('*'),
        app_id,
        expires_at: Some(prof_end.map_or(cert_end, |p| p.min(cert_end))),
        provisions_all_devices: pl.get("ProvisionsAllDevices").and_then(|v| v.as_boolean()).unwrap_or(false),
        device_udids: devices,
        certificate_in_profile: in_profile,
    })
}

/// The bundle id the profile allows for an app: wildcard profiles keep it (or prefix it), exact ones replace it.
pub fn bundle_id_for_profile(app_id_entitlement: &str, team_id: &str, original: &str) -> String {
    let id = app_id_entitlement
        .strip_prefix(&format!("{team_id}."))
        .unwrap_or(app_id_entitlement);
    if let Some(prefix) = id.strip_suffix('*') {
        if prefix.is_empty() || original.starts_with(prefix) {
            original.to_string()
        } else {
            format!("{prefix}{original}")
        }
    } else {
        id.to_string()
    }
}

/// Your own certificate: sign with it and install.
#[uniffi::export(async_runtime = "tokio")]
pub async fn install_with_certificate(
    ipa_path: String,
    p12: Vec<u8>,
    password: String,
    mobileprovision: Vec<u8>,
    pairing_file: Vec<u8>,
    device_address: String,
    observer: Box<dyn SigningObserver>,
) -> Result<InstallOutcome> {
    set_observer(Arc::from(observer));
    notify(InstallStage::Connecting, 0.0);
    let mut link = device::connect(&pairing_file, &device_address).await?;
    let dev = link.info().await?;

    let identity = load_identity(&p12, &password)?;
    let profile = parse_profile(&mobileprovision)?;
    let pl = profile.plist();
    let all_devices = pl.get("ProvisionsAllDevices").and_then(|v| v.as_boolean()).unwrap_or(false);
    let listed = pl
        .get("ProvisionedDevices")
        .and_then(|v| v.as_array())
        .map(|a| a.iter().any(|v| v.as_string() == Some(dev.udid.as_str())))
        .unwrap_or(false);
    if !all_devices && !listed {
        return Err(QuayError::signing("Этого iPhone нет в профиле (.mobileprovision). Добавь его UDID и скачай профиль заново"));
    }

    notify(InstallStage::Signing, 0.1);
    let signed_dir = {
        let ipa_path = ipa_path.clone();
        let mobileprovision = mobileprovision.clone();
        tokio::task::spawn_blocking(move || sign_with_identity(&ipa_path, &identity, &mobileprovision))
            .await
            .map_err(|e| QuayError::signing(format!("Подпись прервалась: {e}")))??
    };

    let outcome = describe_signed(&signed_dir);
    install_signed(&mut link, &signed_dir).await?;
    cleanup_extracted(&signed_dir);
    notify(InstallStage::Done, 1.0);
    outcome
}

fn sign_with_identity(ipa_path: &str, identity: &CertificateIdentity, mobileprovision: &[u8]) -> Result<PathBuf> {
    let profile = parse_profile(mobileprovision)?;
    let team_id = profile.team_id().to_string();
    let app_id_ent = profile
        .entitlements()
        .get("application-identifier")
        .and_then(|v| v.as_string())
        .unwrap_or_default()
        .to_string();

    let mut app = Application::new(PathBuf::from(ipa_path)).map_err(|e| QuayError::ipa(report_text(&e)))?;
    let original = app.main_bundle_id().map_err(|e| QuayError::ipa(report_text(&e)))?;
    let new_id = bundle_id_for_profile(&app_id_ent, &team_id, &original);
    if new_id != original {
        app.update_bundle_id(&original, &new_id).map_err(|e| QuayError::signing(report_text(&e)))?;
    }
    let write = |r: std::result::Result<(), Report>| r.map_err(|e| QuayError::signing(report_text(&e)));
    write(app.bundle.write_info())?;
    for ext in app.bundle.app_extensions_mut() {
        write(ext.write_info())?;
    }
    for fw in app.bundle.frameworks_mut() {
        write(fw.write_info())?;
    }

    // Entitlements from the profile, with the wildcard made concrete for each bundle.
    let concrete = |bundle_id: &str| {
        let mut e = profile.entitlements().clone();
        e.insert("application-identifier".into(), format!("{team_id}.{bundle_id}").into());
        e
    };
    let chain = identity
        .profile_to_certificate_chain(&profile)
        .map_err(|e| QuayError::signing(format!("Сертификат не подходит к профилю: {}", report_text(&e))))?;
    let signer = RustCryptoCmsSigner::new(identity.private_key.clone(), identity.certificate.clone(), chain);
    let mut settings = BundleSigningSettings::new(&team_id, concrete(&new_id), Some(&signer));
    settings.embedded_mobileprovision = Some(mobileprovision);
    let ext_ids: Vec<String> = app
        .bundle
        .app_extensions()
        .iter()
        .filter_map(|b| b.bundle_identifier().map(str::to_string))
        .collect();
    let mut by_id_ent = BTreeMap::new();
    let mut by_id_prov = BTreeMap::new();
    for id in &ext_ids {
        by_id_ent.insert(id.clone(), concrete(id));
        by_id_prov.insert(id.clone(), mobileprovision);
    }
    settings.entitlements_by_bundle_id = by_id_ent;
    settings.embedded_mobileprovisions_by_bundle_id = by_id_prov;

    sign_bundle(&app.bundle.bundle_dir, &settings).map_err(|e| QuayError::signing(format!("Подпись не удалась: {e}")))?;
    Ok(app.bundle.bundle_dir.clone())
}

// ---------- shared ----------

/// "dev.neosay.quaystore.ABCDE12345" → "dev.neosay.quaystore", in the app and its extensions.
fn strip_team_suffix(app_dir: &Path, team_id: &str) -> Result<()> {
    let suffix = format!(".{team_id}");
    let mut plists = vec![app_dir.join("Info.plist")];
    if let Ok(entries) = std::fs::read_dir(app_dir.join("PlugIns")) {
        plists.extend(entries.flatten().map(|e| e.path().join("Info.plist")));
    }
    for path in plists.into_iter().filter(|p| p.exists()) {
        let mut info: plist::Dictionary =
            plist::from_file(&path).map_err(|_| QuayError::signing("Info.plist не читается"))?;
        let id = info.get("CFBundleIdentifier").and_then(|v| v.as_string()).map(str::to_string);
        if let Some(id) = id {
            if let Some(stripped) = id.strip_suffix(&suffix) {
                info.insert("CFBundleIdentifier".into(), plist::Value::String(stripped.to_string()));
                plist::to_file_binary(&path, &info).map_err(|_| QuayError::signing("Info.plist не записывается"))?;
            } else if id.contains(&suffix) {
                // Extensions: "app.TEAM.widget" → "app.widget".
                let fixed = id.replacen(&suffix, "", 1);
                info.insert("CFBundleIdentifier".into(), plist::Value::String(fixed));
                plist::to_file_binary(&path, &info).map_err(|_| QuayError::signing("Info.plist не записывается"))?;
            }
        }
    }
    Ok(())
}

async fn install_signed(link: &mut device::Link, signed_dir: &Path) -> Result<()> {
    notify(InstallStage::Uploading, 0.0);
    link.install(signed_dir, |pct: u64| {
        let f = pct as f32 / 100.0;
        if pct < 70 {
            notify(InstallStage::Uploading, f / 0.7);
        } else {
            notify(InstallStage::Installing, (f - 0.7) / 0.3);
        }
    })
    .await
    .map_err(|e| {
        let t = report_text(&e);
        let l = t.to_lowercase();
        if l.contains("0xe8008015") || l.contains("no valid provisioning profile") {
            QuayError::install("iOS отклонил профиль. Проверь, что iPhone добавлен в аккаунт, и что сертификат не отозван")
        } else if l.contains("revoked") || l.contains("0xe8008018") {
            QuayError::install("Сертификат отозван Apple. Нужен новый")
        } else if l.contains("developer mode") {
            QuayError::install("Включи режим разработчика: Настройки → Конфиденциальность и безопасность")
        } else {
            QuayError::install(t)
        }
    })
}

/// Bundle id, name, version and profile end from the signed .app.
fn describe_signed(dir: &Path) -> Result<InstallOutcome> {
    let info: plist::Dictionary = plist::from_file(dir.join("Info.plist"))
        .map_err(|_| QuayError::signing("Подписанное приложение без Info.plist"))?;
    let g = |k: &str| info.get(k).and_then(|v| v.as_string()).map(str::to_string);
    let expires_at = std::fs::read(dir.join("embedded.mobileprovision"))
        .ok()
        .and_then(|b| ProvisioningProfile::parse(&b).ok())
        .and_then(|p| date_secs(p.plist().get("ExpirationDate")));
    let bundle = g("CFBundleIdentifier").unwrap_or_default();
    Ok(InstallOutcome {
        app_name: g("CFBundleDisplayName").or_else(|| g("CFBundleName")).unwrap_or_else(|| bundle.clone()),
        installed_bundle_id: bundle,
        version: g("CFBundleShortVersionString").unwrap_or_default(),
        build_version: g("CFBundleVersion"),
        expires_at,
    })
}

/// isideload unpacks into tmp/<ipa>_extracted/Payload/X.app: remove the whole folder.
fn cleanup_extracted(app_dir: &Path) {
    if let Some(root) = app_dir.parent().and_then(Path::parent) {
        if root.file_name().map(|n| n.to_string_lossy().ends_with("_extracted")).unwrap_or(false) {
            let _ = std::fs::remove_dir_all(root);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn profile_bundle_ids() {
        assert_eq!(bundle_id_for_profile("ABC.*", "ABC", "com.x.app"), "com.x.app");
        assert_eq!(bundle_id_for_profile("ABC.com.me.*", "ABC", "com.me.app"), "com.me.app");
        assert_eq!(bundle_id_for_profile("ABC.com.me.*", "ABC", "com.x.app"), "com.me.com.x.app");
        assert_eq!(bundle_id_for_profile("ABC.com.me.exact", "ABC", "com.x.app"), "com.me.exact");
    }
}
