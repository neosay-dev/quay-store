//! Real sources, saved 2026-11-16: AltStore's, SideStore's, SideStore Community, Quark. Every app with a
//! download must come through with its versions.

use quay_core::source::parse_source;

fn check(name: &str, apps: usize) {
    let json = std::fs::read_to_string(format!("{}/tests/fixtures/{name}.json", env!("CARGO_MANIFEST_DIR"))).unwrap();
    let src = parse_source(json, format!("https://example.com/{name}.json")).unwrap();
    assert_eq!(src.apps.len(), apps, "{name}");
    for app in &src.apps {
        assert!(!app.versions.is_empty(), "{name}: {} has no versions", app.name);
        assert!(app.versions.iter().all(|v| v.download_url.starts_with("http")), "{name}: {}", app.name);
    }
}

#[test]
fn altstore() { check("altstore", 6) }
#[test]
fn sidestore() { check("sidestore", 1) }
#[test]
fn sidestore_community() { check("sidestore-community", 23) }
#[test]
fn quark() { check("quark", 38) }
