//! Sources in the AltStore / SideStore format (also read by Feather and ESign).
//!
//! Parsed leniently from JSON values: the newer `versions[]` layout and the older one with the version
//! fields on the app itself, screenshots as strings, objects or per-device lists, and the usual key aliases.

use serde_json::{Map, Value};

use crate::error::{QuayError, Result};
use crate::http;

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct AppVersion {
    pub version: String,
    pub build_version: Option<String>,
    /// ISO 8601 as the source wrote it.
    pub date: Option<String>,
    pub notes: Option<String>,
    pub download_url: String,
    pub size: Option<u64>,
    pub sha256: Option<String>,
    pub min_os_version: Option<String>,
    pub max_os_version: Option<String>,
    /// What identifies this exact file: sha256 when known, else a GitHub asset id + date, else URL + size.
    pub fingerprint: String,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct PrivacyItem {
    pub key: String,
    pub text: String,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct StoreApp {
    pub bundle_id: String,
    pub name: String,
    pub developer: Option<String>,
    pub subtitle: Option<String>,
    pub description: Option<String>,
    pub icon_url: Option<String>,
    pub tint_color: Option<String>,
    pub category: Option<String>,
    pub screenshots: Vec<String>,
    /// Newest first.
    pub versions: Vec<AppVersion>,
    pub entitlements: Vec<String>,
    pub privacy: Vec<PrivacyItem>,
    pub beta: bool,
    /// The bundle id is a stand-in (GitHub repos): the real one is read from the IPA when it is installed.
    pub bundle_id_is_placeholder: bool,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct NewsItem {
    pub identifier: String,
    pub title: String,
    pub caption: Option<String>,
    pub date: Option<String>,
    pub image_url: Option<String>,
    pub url: Option<String>,
    pub app_bundle_id: Option<String>,
    pub tint_color: Option<String>,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct Source {
    pub identifier: String,
    pub name: String,
    pub subtitle: Option<String>,
    pub description: Option<String>,
    pub icon_url: Option<String>,
    pub header_url: Option<String>,
    pub website: Option<String>,
    pub tint_color: Option<String>,
    pub featured_bundle_ids: Vec<String>,
    pub apps: Vec<StoreApp>,
    pub news: Vec<NewsItem>,
    /// Where it was loaded from.
    pub source_url: String,
}

/// Download and parse a source.
#[uniffi::export(async_runtime = "tokio")]
pub async fn fetch_source(url: String) -> Result<Source> {
    let url = normalize_source_url(url)?;
    let text = http::get_text(&url).await?;
    parse_source(text, url)
}

/// Parse source JSON (also used for the cached copy, offline).
#[uniffi::export]
pub fn parse_source(json: String, source_url: String) -> Result<Source> {
    let value: Value = serde_json::from_str(json.trim_start_matches('\u{feff}'))
        .map_err(|e| QuayError::source(format!("Это не JSON источника: {e}")))?;
    let obj = value
        .as_object()
        .ok_or_else(|| QuayError::source("Источник должен быть JSON-объектом"))?;

    let apps_value = obj
        .get("apps")
        .and_then(Value::as_array)
        .ok_or_else(|| QuayError::source("В источнике нет списка приложений (apps)"))?;

    // Big aggregated sources repeat bundle ids; like AltStore, the first one wins (the UI keys apps by bundle id).
    let mut seen = std::collections::HashSet::new();
    let mut apps = Vec::new();
    for a in apps_value.iter().filter_map(Value::as_object) {
        if let Some(app) = parse_app(a) {
            if seen.insert(app.bundle_id.clone()) {
                apps.push(app);
            }
        }
    }

    let name = s(obj, &["name"]).unwrap_or_else(|| host_of(&source_url));
    let identifier = s(obj, &["identifier", "id"]).unwrap_or_else(|| source_url.clone());

    let featured_bundle_ids = obj
        .get("featuredApps")
        .and_then(Value::as_array)
        .map(|a| a.iter().filter_map(|v| v.as_str().map(str::to_string)).collect())
        .unwrap_or_default();

    let news = obj
        .get("news")
        .and_then(Value::as_array)
        .map(|a| a.iter().filter_map(Value::as_object).filter_map(parse_news).collect())
        .unwrap_or_default();

    Ok(Source {
        identifier,
        name,
        subtitle: s(obj, &["subtitle"]),
        description: s(obj, &["description", "localizedDescription"]),
        icon_url: s(obj, &["iconURL", "iconUrl", "icon"]),
        header_url: s(obj, &["headerURL", "headerUrl", "headerImageURL"]),
        website: s(obj, &["website", "sourceURL"]),
        tint_color: s(obj, &["tintColor"]).map(normalize_color),
        featured_bundle_ids,
        apps,
        news,
        source_url,
    })
}

fn parse_app(a: &Map<String, Value>) -> Option<StoreApp> {
    let bundle_id = s(a, &["bundleIdentifier", "bundleID", "bundleId", "bundle_id"])?;
    let name = s(a, &["name"]).unwrap_or_else(|| bundle_id.clone());

    let mut versions: Vec<AppVersion> = a
        .get("versions")
        .and_then(Value::as_array)
        .map(|vs| vs.iter().filter_map(Value::as_object).filter_map(parse_version).collect())
        .unwrap_or_default();

    // The older layout: one version on the app itself.
    if versions.is_empty() {
        if let Some(v) = parse_version(a) {
            versions.push(v);
        }
    }

    let (entitlements, privacy) = parse_permissions(a);

    Some(StoreApp {
        bundle_id,
        name,
        developer: s(a, &["developerName", "developer", "dev"]),
        subtitle: s(a, &["subtitle"]),
        description: s(a, &["localizedDescription", "description"]),
        icon_url: s(a, &["iconURL", "iconUrl", "icon"]),
        tint_color: s(a, &["tintColor"]).map(normalize_color),
        category: s(a, &["category"]),
        screenshots: parse_screenshots(a),
        versions,
        entitlements,
        privacy,
        beta: a.get("beta").and_then(Value::as_bool).unwrap_or(false),
        bundle_id_is_placeholder: false,
    })
}

fn parse_version(v: &Map<String, Value>) -> Option<AppVersion> {
    let download_url = s(v, &["downloadURL", "downloadUrl", "download_url", "down"])?;
    let version = s(v, &["version"]).unwrap_or_else(|| "0".to_string());
    let size = u(v, &["size"]);
    let sha256 = s(v, &["sha256"]).map(|h| h.to_lowercase());
    let fingerprint = match &sha256 {
        Some(h) => format!("sha256:{h}"),
        None => format!("url:{download_url}|{}", size.unwrap_or(0)),
    };
    Some(AppVersion {
        version,
        build_version: s(v, &["buildVersion", "build"]),
        date: s(v, &["date", "versionDate"]),
        notes: s(v, &["localizedDescription", "versionDescription", "changelog"]),
        download_url,
        size,
        sha256,
        min_os_version: s(v, &["minOSVersion", "minOsVersion"]),
        max_os_version: s(v, &["maxOSVersion", "maxOsVersion"]),
        fingerprint,
    })
}

fn parse_screenshots(a: &Map<String, Value>) -> Vec<String> {
    fn from_list(list: &[Value]) -> Vec<String> {
        list.iter()
            .filter_map(|v| match v {
                Value::String(u) => Some(u.clone()),
                Value::Object(o) => s(o, &["imageURL", "imageUrl", "url"]),
                _ => None,
            })
            .collect()
    }
    match a.get("screenshots") {
        Some(Value::Array(list)) => return from_list(list),
        Some(Value::Object(by_device)) => {
            // { "iphone": [...], "ipad": [...] }: the iPhone ones first.
            let mut out = Vec::new();
            for key in ["iphone", "ipad"] {
                if let Some(Value::Array(list)) = by_device.get(key) {
                    out.extend(from_list(list));
                }
            }
            if !out.is_empty() {
                return out;
            }
        }
        _ => {}
    }
    a.get("screenshotURLs")
        .and_then(Value::as_array)
        .map(|l| from_list(l))
        .unwrap_or_default()
}

fn parse_permissions(a: &Map<String, Value>) -> (Vec<String>, Vec<PrivacyItem>) {
    let mut entitlements = Vec::new();
    let mut privacy = Vec::new();
    if let Some(Value::Object(p)) = a.get("appPermissions") {
        match p.get("entitlements") {
            Some(Value::Array(list)) => {
                for e in list {
                    match e {
                        Value::String(n) => entitlements.push(n.clone()),
                        Value::Object(o) => {
                            if let Some(n) = s(o, &["name"]) {
                                entitlements.push(n)
                            }
                        }
                        _ => {}
                    }
                }
            }
            _ => {}
        }
        match p.get("privacy") {
            Some(Value::Object(o)) => {
                for (k, v) in o {
                    if let Some(t) = v.as_str() {
                        privacy.push(PrivacyItem { key: k.clone(), text: t.to_string() });
                    }
                }
            }
            Some(Value::Array(list)) => {
                for item in list.iter().filter_map(Value::as_object) {
                    if let (Some(k), Some(t)) = (s(item, &["name"]), s(item, &["usageDescription"])) {
                        privacy.push(PrivacyItem { key: k, text: t });
                    }
                }
            }
            _ => {}
        }
    }
    (entitlements, privacy)
}

fn parse_news(n: &Map<String, Value>) -> Option<NewsItem> {
    let title = s(n, &["title"])?;
    Some(NewsItem {
        identifier: s(n, &["identifier"]).unwrap_or_else(|| title.clone()),
        title,
        caption: s(n, &["caption"]),
        date: s(n, &["date"]),
        image_url: s(n, &["imageURL", "imageUrl"]),
        url: s(n, &["url"]),
        app_bundle_id: s(n, &["appID", "appId"]),
        tint_color: s(n, &["tintColor"]).map(normalize_color),
    })
}

/// The first non-empty string (or number) among `keys`.
pub(crate) fn s(o: &Map<String, Value>, keys: &[&str]) -> Option<String> {
    keys.iter().find_map(|k| match o.get(*k) {
        Some(Value::String(v)) if !v.trim().is_empty() => Some(v.trim().to_string()),
        Some(Value::Number(n)) => Some(n.to_string()),
        _ => None,
    })
}

fn u(o: &Map<String, Value>, keys: &[&str]) -> Option<u64> {
    keys.iter().find_map(|k| match o.get(*k) {
        Some(Value::Number(n)) => n.as_u64().or_else(|| n.as_f64().map(|f| f as u64)),
        Some(Value::String(v)) => v.trim().parse().ok(),
        _ => None,
    })
}

fn normalize_color(c: String) -> String {
    let c = c.trim().trim_start_matches('#');
    format!("#{}", c.to_uppercase())
}

fn host_of(url: &str) -> String {
    url::Url::parse(url)
        .ok()
        .and_then(|u| u.host_str().map(str::to_string))
        .unwrap_or_else(|| url.to_string())
}

/// Accepts what people paste: missing scheme, `altstore://source?url=…`, `sidestore://source?url=…`,
/// GitHub `blob` links (turned into raw ones).
#[uniffi::export]
pub fn normalize_source_url(input: String) -> Result<String> {
    let t = input.trim();
    if t.is_empty() {
        return Err(QuayError::source("Пустая ссылка"));
    }
    if let Ok(u) = url::Url::parse(t) {
        if matches!(u.scheme(), "altstore" | "sidestore" | "feather" | "quay") {
            if let Some((_, v)) = u.query_pairs().find(|(k, _)| k == "url") {
                return normalize_source_url(v.to_string());
            }
        }
    }
    let with_scheme = if t.contains("://") { t.to_string() } else { format!("https://{t}") };
    let mut u = url::Url::parse(&with_scheme)
        .map_err(|_| QuayError::source("Это не похоже на ссылку"))?;
    if !matches!(u.scheme(), "http" | "https") {
        return Err(QuayError::source("Ссылка должна начинаться с https://"));
    }
    // github.com/<o>/<r>/blob/<branch>/<path> → raw.githubusercontent.com/<o>/<r>/<branch>/<path>
    if u.host_str() == Some("github.com") {
        let parts: Vec<String> = u.path_segments().map(|p| p.map(str::to_string).collect()).unwrap_or_default();
        if parts.len() > 4 && parts[2] == "blob" {
            let raw = format!(
                "https://raw.githubusercontent.com/{}/{}/{}",
                parts[0],
                parts[1],
                parts[3..].join("/")
            );
            u = url::Url::parse(&raw).map_err(|_| QuayError::source("Неверная ссылка GitHub"))?;
        }
    }
    Ok(u.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    const NEW_LAYOUT: &str = r##"{
      "name": "neosay-dev", "identifier": "dev.neosay.source", "tintColor": "b9a4ff",
      "featuredApps": ["dev.neosay.horizon"],
      "apps": [{
        "name": "Horizon", "bundleIdentifier": "dev.neosay.horizon", "developerName": "neosay-dev",
        "iconURL": "https://x/icon.png",
        "screenshots": ["https://x/1.jpg", {"imageURL": "https://x/2.jpg", "width": 1}],
        "versions": [
          {"version": "0.2.1", "buildVersion": "21", "date": "2026-11-10T12:00:00Z",
           "downloadURL": "https://x/Horizon-0.2.1.ipa", "size": 123, "sha256": "ABC"},
          {"version": "0.2.0", "downloadURL": "https://x/Horizon-0.2.0.ipa", "size": "100"}
        ],
        "appPermissions": {"entitlements": ["a", {"name": "b"}], "privacy": {"NSCameraUsageDescription": "cam"}}
      }],
      "news": [{"title": "Hi", "identifier": "n1"}]
    }"##;

    const OLD_LAYOUT: &str = r#"{
      "name": "Old", "apps": [{
        "name": "Thing", "bundleIdentifier": "com.x.thing", "version": "1.0",
        "versionDate": "2024-01-01", "downloadURL": "https://x/t.ipa", "size": 5,
        "screenshotURLs": ["https://x/s.png"]
      }, {"name": "No bundle id"}]
    }"#;

    #[test]
    fn new_layout() {
        let src = parse_source(NEW_LAYOUT.into(), "https://x/source.json".into()).unwrap();
        assert_eq!(src.tint_color.as_deref(), Some("#B9A4FF"));
        assert_eq!(src.featured_bundle_ids, vec!["dev.neosay.horizon"]);
        let app = &src.apps[0];
        assert_eq!(app.screenshots, vec!["https://x/1.jpg", "https://x/2.jpg"]);
        assert_eq!(app.versions.len(), 2);
        assert_eq!(app.versions[0].sha256.as_deref(), Some("abc"));
        assert_eq!(app.versions[0].fingerprint, "sha256:abc");
        assert_eq!(app.versions[1].size, Some(100));
        assert_eq!(app.entitlements, vec!["a", "b"]);
        assert_eq!(app.privacy[0].text, "cam");
        assert_eq!(src.news[0].identifier, "n1");
    }

    #[test]
    fn repeated_bundle_ids_keep_the_first() {
        let json = r#"{"apps":[
            {"name":"A","bundleIdentifier":"x.a","version":"2","downloadURL":"https://x/a2.ipa"},
            {"name":"A old","bundleIdentifier":"x.a","version":"1","downloadURL":"https://x/a1.ipa"},
            {"name":"B","bundleIdentifier":"x.b","version":"1","downloadURL":"https://x/b.ipa"}]}"#;
        let src = parse_source(json.into(), "https://example.com/a.json".into()).unwrap();
        assert_eq!(src.apps.iter().map(|a| a.name.as_str()).collect::<Vec<_>>(), ["A", "B"]);
    }

    #[test]
    fn old_layout_and_bad_apps() {
        let src = parse_source(OLD_LAYOUT.into(), "https://example.com/a.json".into()).unwrap();
        assert_eq!(src.apps.len(), 1);
        assert_eq!(src.identifier, "https://example.com/a.json");
        let v = &src.apps[0].versions[0];
        assert_eq!(v.version, "1.0");
        assert_eq!(v.date.as_deref(), Some("2024-01-01"));
        assert_eq!(src.apps[0].screenshots, vec!["https://x/s.png"]);
    }

    #[test]
    fn rejects_non_sources() {
        assert!(parse_source("[]".into(), "u".into()).is_err());
        assert!(parse_source("{\"name\":1}".into(), "u".into()).is_err());
        assert!(parse_source("nope".into(), "u".into()).is_err());
    }

    #[test]
    fn urls() {
        assert_eq!(normalize_source_url("example.com/s.json".into()).unwrap(), "https://example.com/s.json");
        assert_eq!(
            normalize_source_url("altstore://source?url=https://a.b/c.json".into()).unwrap(),
            "https://a.b/c.json"
        );
        assert_eq!(
            normalize_source_url("https://github.com/o/r/blob/main/dir/source.json".into()).unwrap(),
            "https://raw.githubusercontent.com/o/r/main/dir/source.json"
        );
        assert!(normalize_source_url("ftp://x".into()).is_err());
        assert!(normalize_source_url("  ".into()).is_err());
    }
}
