//! A GitHub repository as a source: its releases with .ipa assets.
//!
//! Responses are cached on disk with their ETag: a "not modified" answer does not count against
//! GitHub's limit of 60 requests an hour without a token.

use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use crate::error::{QuayError, Result};
use crate::http;
use crate::source::{AppVersion, Source, StoreApp};

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct RepoRef {
    pub owner: String,
    pub repo: String,
}

/// `https://github.com/o/r`, `github.com/o/r/releases/...`, `o/r`, `git@github.com:o/r.git`.
#[uniffi::export]
pub fn parse_repo_link(input: String) -> Option<RepoRef> {
    let t = input.trim().trim_end_matches('/');
    let rest = if let Some(r) = t.strip_prefix("git@github.com:") {
        r.to_string()
    } else if let Some(i) = t.find("github.com/") {
        t[i + "github.com/".len()..].to_string()
    } else if !t.contains("://") && t.matches('/').count() == 1 {
        t.to_string()
    } else {
        return None;
    };
    let mut parts = rest.split(['/', '?', '#']).filter(|p| !p.is_empty());
    let owner = parts.next()?.to_string();
    let repo = parts.next()?.trim_end_matches(".git").to_string();
    // GitHub user names have no dots: "example.com/source.json" is not a repository.
    let owner_ok = !owner.is_empty() && owner.chars().all(|c| c.is_ascii_alphanumeric() || c == '-');
    let repo_ok = !repo.is_empty() && repo.chars().all(|c| c.is_ascii_alphanumeric() || "-_.".contains(c));
    if owner_ok && repo_ok { Some(RepoRef { owner, repo }) } else { None }
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct GithubAsset {
    pub id: u64,
    pub name: String,
    pub size: u64,
    pub download_url: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct GithubRelease {
    pub tag: String,
    pub name: String,
    pub notes: Option<String>,
    pub published_at: Option<String>,
    pub prerelease: bool,
    pub ipas: Vec<GithubAsset>,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct GithubRepoInfo {
    pub repo: RepoRef,
    /// Newest first, only releases with at least one .ipa.
    pub releases: Vec<GithubRelease>,
    /// A source file (altstore.json, source.json, …) attached to a release: offer to add it as a source.
    pub source_url: Option<String>,
    /// Remaining API requests this hour, if GitHub said.
    pub rate_limit_remaining: Option<u32>,
}

#[derive(Deserialize)]
struct ApiAsset {
    id: u64,
    name: String,
    size: u64,
    browser_download_url: String,
    updated_at: String,
}

#[derive(Deserialize)]
struct ApiRelease {
    tag_name: String,
    name: Option<String>,
    body: Option<String>,
    published_at: Option<String>,
    prerelease: bool,
    draft: bool,
    assets: Vec<ApiAsset>,
}

#[derive(Serialize, Deserialize)]
struct Cached {
    etag: String,
    body: String,
}

const SOURCE_FILE_NAMES: &[&str] = &["altstore.json", "source.json", "sidestore.json", "apps.json", "repo.json"];

/// Releases of a repository. `cache_dir`: where ETag-cached answers live (Caches/github).
/// `token`: an optional personal access token (5000 requests an hour instead of 60).
#[uniffi::export(async_runtime = "tokio")]
pub async fn fetch_github_repo(
    repo: RepoRef,
    cache_dir: String,
    token: Option<String>,
) -> Result<GithubRepoInfo> {
    let url = format!(
        "https://api.github.com/repos/{}/{}/releases?per_page=30",
        repo.owner, repo.repo
    );
    let cache_path = PathBuf::from(&cache_dir).join(format!("{}__{}.json", repo.owner, repo.repo));
    let cached: Option<Cached> = std::fs::read_to_string(&cache_path)
        .ok()
        .and_then(|t| serde_json::from_str(&t).ok());

    let mut req = http::client()
        .get(&url)
        .header("Accept", "application/vnd.github+json")
        .header("X-GitHub-Api-Version", "2022-11-28");
    if let Some(t) = token.as_deref().filter(|t| !t.trim().is_empty()) {
        req = req.bearer_auth(t.trim());
    }
    if let Some(c) = &cached {
        req = req.header("If-None-Match", &c.etag);
    }

    let resp = req.send().await?;
    let remaining = resp
        .headers()
        .get("x-ratelimit-remaining")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.parse().ok());
    let status = resp.status().as_u16();

    let body = match status {
        304 => cached.map(|c| c.body).ok_or_else(|| QuayError::network("GitHub: пустой кэш"))?,
        200 => {
            let etag = resp.headers().get("etag").and_then(|v| v.to_str().ok()).map(str::to_string);
            let body = resp.text().await?;
            if let Some(etag) = etag {
                let _ = std::fs::create_dir_all(&cache_dir);
                let _ = std::fs::write(&cache_path, serde_json::to_string(&Cached { etag, body: body.clone() }).unwrap_or_default());
            }
            body
        }
        404 => return Err(QuayError::network("Репозиторий не найден (или он приватный)")),
        403 | 429 => {
            // Out of requests: the cached answer is better than nothing.
            if let Some(c) = cached {
                c.body
            } else {
                return Err(QuayError::network(
                    "Лимит GitHub исчерпан. Подожди час или добавь токен GitHub в настройках",
                ));
            }
        }
        s => return Err(QuayError::network(format!("GitHub ответил {s}"))),
    };

    let api: Vec<ApiRelease> = serde_json::from_str(&body)
        .map_err(|e| QuayError::network(format!("Непонятный ответ GitHub: {e}")))?;

    let mut source_url = None;
    let mut releases = Vec::new();
    for r in api.into_iter().filter(|r| !r.draft) {
        if source_url.is_none() {
            source_url = r
                .assets
                .iter()
                .find(|a| SOURCE_FILE_NAMES.contains(&a.name.to_lowercase().as_str()))
                .map(|a| a.browser_download_url.clone());
        }
        let ipas: Vec<GithubAsset> = r
            .assets
            .into_iter()
            .filter(|a| a.name.to_lowercase().ends_with(".ipa") || a.name.to_lowercase().ends_with(".tipa"))
            .map(|a| GithubAsset {
                id: a.id,
                name: a.name,
                size: a.size,
                download_url: a.browser_download_url,
                updated_at: a.updated_at,
            })
            .collect();
        if ipas.is_empty() {
            continue;
        }
        releases.push(GithubRelease {
            name: r.name.filter(|n| !n.trim().is_empty()).unwrap_or_else(|| r.tag_name.clone()),
            tag: r.tag_name,
            notes: r.body.filter(|b| !b.trim().is_empty()),
            published_at: r.published_at,
            prerelease: r.prerelease,
            ipas,
        });
    }

    Ok(GithubRepoInfo { repo, releases, source_url, rate_limit_remaining: remaining })
}

/// "ios-v0.2.1" → "0.2.1", "v1.0" → "1.0", "nightly" → "nightly".
pub fn version_from_tag(tag: &str) -> String {
    match tag.find(|c: char| c.is_ascii_digit()) {
        Some(i) => tag[i..].to_string(),
        None => tag.to_string(),
    }
}

/// The asset name without its version and noise: "Horizon-0.2.1.ipa" → "Horizon".
/// Assets with the same stem across releases are the same app.
pub fn asset_stem(name: &str, version: &str) -> String {
    let base = name.rsplit_once('.').map(|(b, _)| b).unwrap_or(name);
    let mut stem = base.replace(version, "");
    for noise in ["-unsigned", "_unsigned", ".unsigned", "unsigned"] {
        stem = stem.replace(noise, "");
    }
    let sep = |c: char| c == '-' || c == '_' || c == '.' || c == ' ';
    let mut stem = stem.trim_matches(sep).to_string();
    // "App_v" (from "App_v1.0"): the "v" belonged to the version.
    for tail in ["-v", "_v", ".v", " v", "-V", "_V"] {
        if let Some(s) = stem.strip_suffix(tail) {
            stem = s.trim_matches(sep).to_string();
            break;
        }
    }
    if stem.is_empty() { base.to_string() } else { stem }
}

/// The repository as a source, so it can be followed like any other: one app per kind of .ipa.
#[uniffi::export]
pub fn github_repo_as_source(info: GithubRepoInfo, include_prereleases: bool) -> Source {
    let RepoRef { owner, repo } = info.repo.clone();
    let mut apps: Vec<StoreApp> = Vec::new();
    for r in info.releases.iter().filter(|r| include_prereleases || !r.prerelease) {
        let version = version_from_tag(&r.tag);
        for a in &r.ipas {
            let stem = asset_stem(&a.name, &version);
            let bundle_id = format!("github.{owner}.{repo}.{stem}").to_lowercase();
            let v = AppVersion {
                version: version.clone(),
                build_version: None,
                date: r.published_at.clone(),
                notes: r.notes.clone(),
                download_url: a.download_url.clone(),
                size: Some(a.size),
                sha256: None,
                min_os_version: None,
                max_os_version: None,
                fingerprint: format!("gh:{}|{}", a.id, a.updated_at),
            };
            match apps.iter_mut().find(|x| x.bundle_id == bundle_id) {
                Some(app) => app.versions.push(v),
                None => apps.push(StoreApp {
                    bundle_id,
                    name: stem.clone(),
                    developer: Some(owner.clone()),
                    subtitle: Some(format!("{owner}/{repo}")),
                    description: None,
                    icon_url: Some(format!("https://github.com/{owner}.png?size=256")),
                    tint_color: None,
                    category: None,
                    screenshots: vec![],
                    versions: vec![v],
                    entitlements: vec![],
                    privacy: vec![],
                    beta: r.prerelease,
                    bundle_id_is_placeholder: true,
                }),
            }
        }
    }
    Source {
        identifier: format!("github:{owner}/{repo}"),
        name: repo.clone(),
        subtitle: Some(format!("GitHub · {owner}")),
        description: None,
        icon_url: Some(format!("https://github.com/{owner}.png?size=256")),
        header_url: None,
        website: Some(format!("https://github.com/{owner}/{repo}")),
        tint_color: None,
        featured_bundle_ids: vec![],
        apps,
        news: vec![],
        source_url: format!("https://github.com/{owner}/{repo}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn links() {
        let r = |s: &str| parse_repo_link(s.into()).map(|r| format!("{}/{}", r.owner, r.repo));
        assert_eq!(r("https://github.com/neosay-dev/horizon-ios").as_deref(), Some("neosay-dev/horizon-ios"));
        assert_eq!(r("github.com/a/b/releases/tag/v1").as_deref(), Some("a/b"));
        assert_eq!(r("a/b").as_deref(), Some("a/b"));
        assert_eq!(r("git@github.com:a/b.git").as_deref(), Some("a/b"));
        assert_eq!(r("https://example.com/a/b"), None);
        assert_eq!(r("github.com/onlyowner"), None);
        assert_eq!(r("example.com/source.json"), None);
    }

    #[test]
    fn tags_and_stems() {
        assert_eq!(version_from_tag("ios-v0.2.1"), "0.2.1");
        assert_eq!(version_from_tag("nightly"), "nightly");
        assert_eq!(asset_stem("Horizon-0.2.1.ipa", "0.2.1"), "Horizon");
        assert_eq!(asset_stem("VoidGram-unsigned.ipa", "1.4"), "VoidGram");
        assert_eq!(asset_stem("App_v1.0.ipa", "1.0"), "App");
    }

    #[test]
    fn repo_to_source_groups_by_stem() {
        let asset = |id, name: &str| GithubAsset {
            id,
            name: name.into(),
            size: 1,
            download_url: format!("https://g/{name}"),
            updated_at: "t".into(),
        };
        let info = GithubRepoInfo {
            repo: RepoRef { owner: "o".into(), repo: "r".into() },
            releases: vec![
                GithubRelease { tag: "v2".into(), name: "2".into(), notes: None, published_at: None, prerelease: false, ipas: vec![asset(2, "A-2.ipa"), asset(3, "B-2.ipa")] },
                GithubRelease { tag: "v1".into(), name: "1".into(), notes: None, published_at: None, prerelease: false, ipas: vec![asset(1, "A-1.ipa")] },
                GithubRelease { tag: "v3-beta".into(), name: "3".into(), notes: None, published_at: None, prerelease: true, ipas: vec![asset(4, "A-3-beta.ipa")] },
            ],
            source_url: None,
            rate_limit_remaining: None,
        };
        let src = github_repo_as_source(info, false);
        assert_eq!(src.apps.len(), 2);
        assert_eq!(src.apps[0].versions.len(), 2);
        assert_eq!(src.apps[0].versions[0].version, "2");
        assert!(src.apps[0].bundle_id_is_placeholder);
    }
}
