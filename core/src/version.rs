//! Version comparison and update detection.

use std::cmp::Ordering;

use crate::source::AppVersion;

/// Compares "1.10.2" with "1.9" numerically, part by part; text parts ("beta") compare as text and a
/// version with fewer parts is padded with zeros. Leading "v" is ignored.
pub fn compare(a: &str, b: &str) -> Ordering {
    let split = |s: &str| -> Vec<String> {
        s.trim()
            .trim_start_matches(['v', 'V'])
            .split(|c: char| c == '.' || c == '-' || c == '+' || c == '_')
            .filter(|p| !p.is_empty())
            .map(str::to_string)
            .collect()
    };
    let (pa, pb) = (split(a), split(b));
    for i in 0..pa.len().max(pb.len()) {
        let x = pa.get(i).map(String::as_str).unwrap_or("0");
        let y = pb.get(i).map(String::as_str).unwrap_or("0");
        let ord = match (x.parse::<u64>(), y.parse::<u64>()) {
            (Ok(m), Ok(n)) => m.cmp(&n),
            // "1.0" is newer than "1.0-beta": a number beats text in the same place.
            (Ok(_), Err(_)) => Ordering::Greater,
            (Err(_), Ok(_)) => Ordering::Less,
            (Err(_), Err(_)) => x.cmp(y),
        };
        if ord != Ordering::Equal {
            return ord;
        }
    }
    Ordering::Equal
}

/// -1, 0 or 1, for Swift.
#[uniffi::export]
pub fn compare_versions(a: String, b: String) -> i32 {
    match compare(&a, &b) {
        Ordering::Less => -1,
        Ordering::Equal => 0,
        Ordering::Greater => 1,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum UpdateKind {
    UpToDate,
    /// A higher version or build number.
    NewVersion,
    /// The same version and build, but a different file.
    Rebuilt,
}

/// What is installed, as Quay remembers it.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct InstalledState {
    pub version: String,
    pub build_version: Option<String>,
    /// The fingerprint of the version it was installed from (AppVersion.fingerprint).
    pub fingerprint: Option<String>,
    /// sha256 of the IPA file it was installed from.
    pub sha256: Option<String>,
}

#[uniffi::export]
pub fn check_update(installed: InstalledState, latest: AppVersion) -> UpdateKind {
    match compare(&latest.version, &installed.version) {
        Ordering::Greater => return UpdateKind::NewVersion,
        Ordering::Less => return UpdateKind::UpToDate,
        Ordering::Equal => {}
    }
    if let (Some(lb), Some(ib)) = (&latest.build_version, &installed.build_version) {
        match compare(lb, ib) {
            Ordering::Greater => return UpdateKind::NewVersion,
            Ordering::Less => return UpdateKind::UpToDate,
            Ordering::Equal => {}
        }
    }
    // Same version: did the file change?
    if let (Some(ls), Some(is)) = (&latest.sha256, &installed.sha256) {
        return if ls.eq_ignore_ascii_case(is) { UpdateKind::UpToDate } else { UpdateKind::Rebuilt };
    }
    if let Some(f) = &installed.fingerprint {
        if *f != latest.fingerprint {
            return UpdateKind::Rebuilt;
        }
    }
    UpdateKind::UpToDate
}

#[cfg(test)]
mod tests {
    use super::*;

    fn v(version: &str, build: Option<&str>, sha: Option<&str>, fp: &str) -> AppVersion {
        AppVersion {
            version: version.into(),
            build_version: build.map(Into::into),
            date: None,
            notes: None,
            download_url: "https://x/a.ipa".into(),
            size: None,
            sha256: sha.map(Into::into),
            min_os_version: None,
            max_os_version: None,
            fingerprint: fp.into(),
        }
    }

    fn installed(version: &str, build: Option<&str>, sha: Option<&str>, fp: Option<&str>) -> InstalledState {
        InstalledState {
            version: version.into(),
            build_version: build.map(Into::into),
            fingerprint: fp.map(Into::into),
            sha256: sha.map(Into::into),
        }
    }

    #[test]
    fn ordering() {
        assert_eq!(compare("1.10", "1.9"), Ordering::Greater);
        assert_eq!(compare("v2.0", "2"), Ordering::Equal);
        assert_eq!(compare("1.0", "1.0-beta"), Ordering::Greater);
        assert_eq!(compare("0.2.1", "0.2.10"), Ordering::Less);
    }

    #[test]
    fn updates() {
        let i = installed("1.0", Some("5"), Some("aa"), Some("sha256:aa"));
        assert_eq!(check_update(i.clone(), v("1.1", None, None, "x")), UpdateKind::NewVersion);
        assert_eq!(check_update(i.clone(), v("1.0", Some("6"), None, "x")), UpdateKind::NewVersion);
        assert_eq!(check_update(i.clone(), v("1.0", Some("5"), Some("AA"), "x")), UpdateKind::UpToDate);
        assert_eq!(check_update(i.clone(), v("1.0", Some("5"), Some("bb"), "x")), UpdateKind::Rebuilt);
        assert_eq!(check_update(i, v("0.9", None, None, "x")), UpdateKind::UpToDate);
        let j = installed("1.0", None, None, Some("gh:1|2026"));
        assert_eq!(check_update(j.clone(), v("1.0", None, None, "gh:2|2026")), UpdateKind::Rebuilt);
        assert_eq!(check_update(j, v("1.0", None, None, "gh:1|2026")), UpdateKind::UpToDate);
    }
}
