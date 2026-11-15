#!/usr/bin/env python3
"""Quay Store's own source (AltStore format) from this repo's v* GitHub releases, newest first.

The release step uploads it as source.json, so Quay updates itself from
https://github.com/<repo>/releases/latest/download/source.json
"""
import hashlib
import json
import subprocess
import sys
import urllib.request

REPO = sys.argv[1] if len(sys.argv) > 1 else "neosay-dev/quay-store"
RAW = f"https://raw.githubusercontent.com/{REPO}/main"


def gh(*args):
    return json.loads(subprocess.check_output(["gh", *args, "-R", REPO]))


def sha256_of(path_or_url):
    h = hashlib.sha256()
    if path_or_url.startswith("http"):
        with urllib.request.urlopen(path_or_url) as r:
            for chunk in iter(lambda: r.read(1 << 20), b""):
                h.update(chunk)
    else:
        with open(path_or_url, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
    return h.hexdigest()


versions = []
for r in gh("release", "list", "--limit", "50", "--json", "tagName"):
    tag = r["tagName"]
    if not tag.startswith("v"):
        continue
    rel = gh("release", "view", tag, "--json", "tagName,publishedAt,createdAt,body,assets")
    version = tag[1:]
    ipa = next((a for a in rel["assets"] if a["name"] == f"QuayStore-{version}.ipa"), None)
    if ipa is None:
        continue
    local = f"QuayStore-{version}.ipa"
    try:
        digest = sha256_of(local)
    except OSError:
        digest = sha256_of(ipa["url"])
    versions.append({
        "version": version,
        "date": rel.get("publishedAt") or rel["createdAt"],
        "localizedDescription": (rel.get("body") or "").strip(),
        "downloadURL": ipa["url"],
        "size": ipa["size"],
        "sha256": digest,
        "minOSVersion": "16.0",
    })

versions.sort(key=lambda v: [int(p) if p.isdigit() else p for p in v["version"].split(".")], reverse=True)

source = {
    "name": "Quay Store",
    "identifier": "dev.neosay.quaystore.source",
    "subtitle": "Sideload-стор для iPhone",
    "website": f"https://github.com/{REPO}",
    "tintColor": "#E87236",
    "apps": [{
        "name": "Quay Store",
        "bundleIdentifier": "dev.neosay.quaystore",
        "developerName": "neosay-dev",
        "subtitle": "Свои источники, подпись и установка на iPhone",
        "localizedDescription": "Источники AltStore/SideStore и репозитории GitHub, подпись бесплатным Apple ID "
            "или своим сертификатом, установка через LocalDevVPN, обновления и продление подписей.",
        "category": "utilities",
        "versions": versions,
        "appPermissions": {"entitlements": [], "privacy": {
            "NSLocalNetworkUsageDescription": "Установка приложений на этот iPhone через LocalDevVPN.",
        }},
    }],
    "news": [],
}
json.dump(source, sys.stdout, ensure_ascii=False, indent=2)
print()
