//! What is inside an .ipa, without unpacking it: Info.plist and the file's sha256.

use std::fs::File;
use std::io::{BufReader, Read};

use sha2::{Digest, Sha256};

use crate::error::{QuayError, Result};

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct IpaInfo {
    pub bundle_id: String,
    pub name: String,
    pub version: String,
    pub build_version: Option<String>,
    pub min_os_version: Option<String>,
    pub sha256: String,
    pub size: u64,
    /// The app has app extensions (widgets, share extensions …): each needs its own App ID on a free account.
    pub extension_count: u32,
    /// The largest icon PNG in the app folder (Apple's CgBI PNG: iOS draws it, other tools may not).
    pub icon_png: Option<Vec<u8>>,
}

#[uniffi::export]
pub fn inspect_ipa(path: String) -> Result<IpaInfo> {
    let size = std::fs::metadata(&path)?.len();
    let sha256 = file_sha256(&path)?;

    let file = File::open(&path)?;
    let mut zip = zip::ZipArchive::new(BufReader::new(file))
        .map_err(|_| QuayError::ipa("Файл повреждён или это не .ipa"))?;

    // Payload/<Name>.app/Info.plist, the top-level one.
    let names: Vec<String> = zip.file_names().map(str::to_string).collect();
    let info_name = names
        .iter()
        .find(|n| {
            let p: Vec<&str> = n.split('/').collect();
            p.len() == 3 && p[0] == "Payload" && p[1].ends_with(".app") && p[2] == "Info.plist"
        })
        .cloned()
        .ok_or_else(|| QuayError::ipa("В .ipa нет Payload/*.app/Info.plist"))?;
    let app_dir = info_name.trim_end_matches("Info.plist").to_string();
    let extension_count = names
        .iter()
        .filter(|n| {
            n.starts_with(&format!("{app_dir}PlugIns/"))
                && n.ends_with(".appex/Info.plist")
                && n.matches('/').count() == 4
        })
        .count() as u32;

    let mut bytes = Vec::new();
    zip.by_name(&info_name)
        .map_err(|_| QuayError::ipa("Не удалось прочитать Info.plist"))?
        .read_to_end(&mut bytes)?;
    let plist: plist::Dictionary = plist::from_bytes(&bytes)
        .map_err(|_| QuayError::ipa("Info.plist повреждён"))?;
    let get = |k: &str| plist.get(k).and_then(|v| v.as_string()).map(str::to_string);

    let bundle_id = get("CFBundleIdentifier").ok_or_else(|| QuayError::ipa("Нет CFBundleIdentifier"))?;
    let name = get("CFBundleDisplayName")
        .or_else(|| get("CFBundleName"))
        .unwrap_or_else(|| bundle_id.clone());
    let build = get("CFBundleVersion");
    let icon_png = largest_icon(&mut zip, &names, &app_dir, &plist);
    let version = get("CFBundleShortVersionString")
        .or_else(|| build.clone())
        .unwrap_or_else(|| "0".into());

    Ok(IpaInfo {
        bundle_id,
        name,
        version,
        build_version: build,
        min_os_version: get("MinimumOSVersion"),
        sha256,
        size,
        extension_count,
        icon_png,
    })
}

/// Icon files named in CFBundleIcons (e.g. "AppIcon60x60" → AppIcon60x60@2x.png), else any AppIcon*/Icon* PNG
/// in the app's root. Apps whose icon lives only in Assets.car have none.
fn largest_icon<R: std::io::Read + std::io::Seek>(
    zip: &mut zip::ZipArchive<R>,
    names: &[String],
    app_dir: &str,
    plist: &plist::Dictionary,
) -> Option<Vec<u8>> {
    let mut bases: Vec<String> = plist
        .get("CFBundleIcons")
        .and_then(|v| v.as_dictionary())
        .and_then(|d| d.get("CFBundlePrimaryIcon"))
        .and_then(|v| v.as_dictionary())
        .and_then(|d| d.get("CFBundleIconFiles"))
        .and_then(|v| v.as_array())
        .map(|a| a.iter().filter_map(|v| v.as_string().map(str::to_string)).collect())
        .unwrap_or_default();
    bases.extend(["AppIcon".to_string(), "Icon".to_string()]);
    let root_pngs: Vec<&String> = names
        .iter()
        .filter(|n| n.starts_with(app_dir) && !n[app_dir.len()..].contains('/') && n.to_lowercase().ends_with(".png"))
        .collect();
    let best = bases.iter().find_map(|base| {
        root_pngs
            .iter()
            .filter(|n| n[app_dir.len()..].starts_with(base.as_str()))
            .max_by_key(|n| zip.by_name(n.as_str()).map(|f| f.size()).unwrap_or(0))
            .map(|n| n.to_string())
    })?;
    let mut out = Vec::new();
    zip.by_name(&best).ok()?.read_to_end(&mut out).ok()?;
    Some(out)
}

pub fn file_sha256(path: &str) -> Result<String> {
    let mut f = BufReader::with_capacity(1 << 20, File::open(path)?);
    let mut h = Sha256::new();
    let mut buf = vec![0u8; 1 << 20];
    loop {
        let n = f.read(&mut buf)?;
        if n == 0 {
            break;
        }
        h.update(&buf[..n]);
    }
    Ok(hex::encode(h.finalize()))
}

/// Compares a downloaded file with the sha256 the source promised (case-insensitive).
#[uniffi::export]
pub fn verify_sha256(path: String, expected: String) -> Result<bool> {
    Ok(file_sha256(&path)?.eq_ignore_ascii_case(expected.trim()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn reads_info_plist() {
        let dir = std::env::temp_dir().join(format!("quay-ipa-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("t.ipa");
        {
            let f = File::create(&path).unwrap();
            let mut z = zip::ZipWriter::new(f);
            let opts = zip::write::SimpleFileOptions::default();
            let mut d = plist::Dictionary::new();
            d.insert("CFBundleIdentifier".into(), "com.x.app".into());
            d.insert("CFBundleName".into(), "App".into());
            d.insert("CFBundleShortVersionString".into(), "1.2".into());
            d.insert("CFBundleVersion".into(), "7".into());
            let mut xml = Vec::new();
            plist::to_writer_xml(&mut xml, &plist::Value::Dictionary(d)).unwrap();
            z.start_file("Payload/App.app/Info.plist", opts).unwrap();
            z.write_all(&xml).unwrap();
            z.start_file("Payload/App.app/PlugIns/W.appex/Info.plist", opts).unwrap();
            z.write_all(&xml).unwrap();
            z.start_file("Payload/App.app/AppIcon60x60@2x.png", opts).unwrap();
            z.write_all(b"small").unwrap();
            z.start_file("Payload/App.app/AppIcon60x60@3x.png", opts).unwrap();
            z.write_all(b"bigger icon").unwrap();
            z.finish().unwrap();
        }
        let info = inspect_ipa(path.to_string_lossy().into()).unwrap();
        assert_eq!(info.bundle_id, "com.x.app");
        assert_eq!(info.name, "App");
        assert_eq!(info.version, "1.2");
        assert_eq!(info.build_version.as_deref(), Some("7"));
        assert_eq!(info.extension_count, 1);
        assert_eq!(info.icon_png.as_deref(), Some(&b"bigger icon"[..]));
        assert_eq!(info.sha256.len(), 64);
        assert!(verify_sha256(path.to_string_lossy().into(), info.sha256.to_uppercase()).unwrap());
        std::fs::remove_dir_all(dir).unwrap();
    }
}
