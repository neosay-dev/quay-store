#!/usr/bin/env python3
"""Source Studio: local web page that turns .ipa files into an AltStore-format source on GitHub.

    python3 tools/source_studio.py          # opens http://127.0.0.1:8765
    python3 tools/source_studio.py --selftest

Needs `gh` logged in. IPAs go to GitHub releases (git refuses files over 100 MB),
icons and source.json go into the repo. Running again on the same repo adds versions.
"""
import hashlib
import json
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import uuid
import webbrowser
import zipfile
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

WORK = Path(tempfile.mkdtemp(prefix="source-studio-"))
UPLOADS = {}  # id -> {"path": Path, "info": dict | None}
SAFE = re.compile(r"[^A-Za-z0-9._-]+")


def run(*cmd, cwd=None):
    r = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    if r.returncode:
        raise RuntimeError(f"{' '.join(map(str, cmd[:3]))}: {r.stderr.strip() or r.stdout.strip()}")
    return r.stdout.strip()


def ipa_info(path):
    with zipfile.ZipFile(path) as z:
        name = next((n for n in z.namelist() if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", n)), None)
        if name is None:
            raise ValueError("в .ipa нет Payload/*.app/Info.plist")
        p = plistlib.loads(z.read(name))
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return {
        "name": p.get("CFBundleDisplayName") or p.get("CFBundleName") or Path(name).parent.stem,
        "bundleIdentifier": p["CFBundleIdentifier"],
        "version": p.get("CFBundleShortVersionString") or p.get("CFBundleVersion") or "1.0",
        "buildVersion": p.get("CFBundleVersion") or "",
        "minOSVersion": p.get("MinimumOSVersion") or "14.0",
        "size": Path(path).stat().st_size,
        "sha256": h.hexdigest(),
    }


def merge(source, app, version):
    """Put `version` first in the app's list; same version number replaces the old entry."""
    old = next((a for a in source["apps"] if a["bundleIdentifier"] == app["bundleIdentifier"]), None)
    if old is None:
        old = {**app, "versions": []}
        source["apps"].append(old)
    else:
        old.update({k: v for k, v in app.items() if v})
    old["versions"] = [version] + [v for v in old["versions"] if v["version"] != version["version"]]


def publish(req, log):
    owner = req["owner"].strip()
    name = SAFE.sub("-", req["repo"].strip()).strip("-.")  # same rule GitHub applies: spaces etc. become "-"
    if not re.fullmatch(r"[A-Za-z0-9-]+", owner):
        raise ValueError(f"владелец «{owner}»: только латиница, цифры и дефис (логин GitHub)")
    if not name:
        raise ValueError(f"название репозитория «{req['repo']}»: нужна латиница, например my-source")
    repo = f"{owner}/{name}"
    raw = f"https://raw.githubusercontent.com/{repo}/main"
    login = run("gh", "api", "user", "-q", ".login")

    try:
        run("gh", "repo", "view", repo)
        log(f"репозиторий {repo} есть, дополняю")
    except RuntimeError:
        run("gh", "repo", "create", repo, "--public", "--add-readme",
            "-d", req.get("sourceName") or "AltStore source")
        log(f"создан {repo}")
    dest = WORK / f"repo-{uuid.uuid4().hex[:8]}"
    run("gh", "repo", "clone", repo, str(dest))

    src_file = dest / "source.json"
    source = json.loads(src_file.read_text()) if src_file.exists() else {
        "name": "", "identifier": f"io.github.{owner.lower()}.{SAFE.sub('-', name).lower()}",
        "website": f"https://github.com/{repo}", "apps": [], "news": []}
    source["name"] = req.get("sourceName") or source["name"] or name
    if req.get("sourceSubtitle"):
        source["subtitle"] = req["sourceSubtitle"]
    if req.get("tintColor"):
        source["tintColor"] = req["tintColor"]

    for a in req["apps"]:
        up = UPLOADS.get(a["ipa"])
        if not up or not up["info"]:
            raise ValueError("файл .ipa не найден, выбери его заново")
        info = up["info"]
        bundle, ver = info["bundleIdentifier"], info["version"]
        tag = SAFE.sub("-", f"{bundle}-{ver}")
        asset = SAFE.sub("-", f"{a.get('name') or info['name']}-{ver}") + ".ipa"
        ipa = WORK / asset
        shutil.copyfile(up["path"], ipa)
        log(f"{asset}: загрузка в релиз {tag}…")
        try:
            run("gh", "release", "view", tag, "-R", repo)
            run("gh", "release", "upload", tag, str(ipa), "--clobber", "-R", repo)
        except RuntimeError:
            run("gh", "release", "create", tag, str(ipa), "-R", repo,
                "--title", f"{a.get('name') or info['name']} {ver}", "--notes", a.get("notes") or ver)

        icon_url = ""
        if a.get("icon") and a["icon"] in UPLOADS:
            icon = UPLOADS[a["icon"]]["path"]
            rel = Path("icons") / (SAFE.sub("-", bundle) + icon.suffix.lower())
            (dest / "icons").mkdir(exist_ok=True)
            shutil.copyfile(icon, dest / rel)
            icon_url = f"{raw}/{rel.as_posix()}"

        merge(source, {
            "name": a.get("name") or info["name"],
            "bundleIdentifier": bundle,
            "developerName": a.get("developer") or login,
            "subtitle": a.get("subtitle", ""),
            "localizedDescription": a.get("description", ""),
            "iconURL": icon_url,
            "category": a.get("category", ""),
        }, {
            "version": ver,
            "buildVersion": info["buildVersion"],
            "date": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "localizedDescription": a.get("notes", ""),
            "downloadURL": f"https://github.com/{repo}/releases/download/{tag}/{asset}",
            "size": info["size"],
            "sha256": info["sha256"],
            "minOSVersion": info["minOSVersion"],
        })
        ipa.unlink()

    src_file.write_text(json.dumps(source, ensure_ascii=False, indent=2) + "\n")
    run("git", "add", "-A", cwd=dest)
    run("git", "-c", f"user.name={login}", "-c", f"user.email={login}@users.noreply.github.com",
        "commit", "-m", f"Update source ({len(req['apps'])} app)", cwd=dest)
    run("git", "push", cwd=dest)
    shutil.rmtree(dest, ignore_errors=True)
    url = f"{raw}/source.json"
    log(f"готово: {url}")
    return url


class Handler(BaseHTTPRequestHandler):
    def send(self, code, body, ctype="application/json"):
        data = body if isinstance(body, bytes) else json.dumps(body, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/":
            self.send(200, PAGE.encode(), "text/html; charset=utf-8")
        elif self.path == "/me":
            try:
                self.send(200, {"login": run("gh", "api", "user", "-q", ".login")})
            except RuntimeError as e:
                self.send(500, {"error": str(e)})
        else:
            self.send(404, {"error": "not found"})

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        if self.path == "/upload":
            fname = Path(self.headers.get("X-Name", "file")).name
            fid = uuid.uuid4().hex
            path = WORK / f"{fid}{Path(fname).suffix.lower()}"
            with open(path, "wb") as f:
                left = length
                while left:
                    chunk = self.rfile.read(min(left, 1 << 20))
                    if not chunk:
                        break
                    f.write(chunk)
                    left -= len(chunk)
            try:
                info = ipa_info(path) if path.suffix == ".ipa" else None
            except (zipfile.BadZipFile, ValueError, KeyError) as e:
                path.unlink()
                return self.send(400, {"error": f"{fname}: {e}"})
            UPLOADS[fid] = {"path": path, "info": info}
            self.send(200, {"id": fid, "info": info})
        elif self.path == "/publish":
            lines = []
            try:
                url = publish(json.loads(self.rfile.read(length)), lines.append)
                self.send(200, {"url": url, "log": lines})
            except Exception as e:  # show any failure on the page instead of a dead request
                self.send(500, {"error": str(e), "log": lines})
        else:
            self.send(404, {"error": "not found"})

    def log_message(self, *a):
        pass


PAGE = r"""<!doctype html><html lang="ru"><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>Source Studio</title>
<style>
:root{--bg:#141210;--card:#1d1a17;--line:#332d27;--text:#ece6df;--dim:#968b7f;--acc:#E87236}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:15px/1.45 ui-sans-serif,system-ui,sans-serif}
main{max-width:760px;margin:0 auto;padding:40px 20px 80px}h1{font-size:22px;margin:0 0 4px}
.sub{color:var(--dim);margin:0 0 28px}h2{font-size:13px;text-transform:uppercase;letter-spacing:.08em;color:var(--dim);margin:28px 0 10px}
fieldset{border:1px solid var(--line);background:var(--card);border-radius:10px;padding:16px;margin:0 0 12px}
label{display:block;font-size:13px;color:var(--dim);margin:10px 0 4px}
input,textarea,select{width:100%;background:var(--bg);color:var(--text);border:1px solid var(--line);border-radius:6px;padding:8px 10px;font:inherit}
input:focus,textarea:focus{outline:2px solid var(--acc);outline-offset:-1px}textarea{min-height:80px;resize:vertical}
.row{display:grid;grid-template-columns:1fr 1fr;gap:12px}.meta{font:12px ui-monospace,monospace;color:var(--dim);margin-top:6px}
button{background:var(--acc);color:#1a0d05;border:0;border-radius:6px;padding:10px 16px;font:600 15px inherit;cursor:pointer}
button.ghost{background:none;color:var(--dim);border:1px solid var(--line);font-weight:400}
button:disabled{opacity:.5;cursor:wait}.head{display:flex;justify-content:space-between;align-items:center}
.icon{width:56px;height:56px;border-radius:13px;object-fit:cover;background:var(--line);flex:none}
.top{display:flex;gap:12px;align-items:center}#log{white-space:pre-wrap;font:13px ui-monospace,monospace;color:var(--dim);margin-top:16px}
#log a{color:var(--acc)}
</style>
<main>
<h1>Source Studio</h1><p class="sub">.ipa → релизы GitHub → source.json для Quay, SideStore, AltStore</p>

<h2>Репозиторий</h2>
<fieldset><div class="row">
<div><label for="owner">Владелец</label><input id="owner"></div>
<div><label for="repo">Название репозитория</label><input id="repo" placeholder="my-source"></div></div>
<div class="row">
<div><label for="sname">Название источника</label><input id="sname" placeholder="Мои приложения"></div>
<div><label for="tint">Цвет</label><input id="tint" type="color" value="#E87236"></div></div>
<label for="ssub">Подзаголовок</label><input id="ssub">
<p class="meta">Если репозиторий уже есть, приложения и версии добавятся в его source.json.</p></fieldset>

<div class="head"><h2>Приложения</h2><button class="ghost" id="add" type="button">+ ещё .ipa</button></div>
<div id="apps"></div>
<button id="go" type="button">Создать и запушить</button>
<div id="log" aria-live="polite"></div>
</main>
<template id="tpl"><fieldset>
<div class="top"><img class="icon" alt=""><div style="flex:1">
<label>Файл .ipa</label><input type="file" accept=".ipa" class="ipa"><div class="meta info"></div></div></div>
<label>Иконка (необязательно, PNG/JPG)</label><input type="file" accept="image/png,image/jpeg" class="iconf">
<div class="row"><div><label>Название</label><input class="name"></div>
<div><label>Категория</label><select class="category"><option value="">—</option><option>games</option>
<option>utilities</option><option>social</option><option>entertainment</option><option>developer</option><option>other</option></select></div></div>
<label>Подзаголовок</label><input class="subtitle">
<label>Описание</label><textarea class="description"></textarea>
<label>Что нового в этой версии</label><input class="notes">
<p style="text-align:right;margin:10px 0 0"><button class="ghost del" type="button">Убрать</button></p>
</fieldset></template>
<script>
const $ = s => document.querySelector(s), log = $("#log");
fetch("/me").then(r => r.json()).then(j => { $("#owner").value = j.login || ""; if (j.error) log.textContent = j.error });

async function upload(file) {
  const r = await fetch("/upload", {method: "POST", headers: {"X-Name": encodeURIComponent(file.name)}, body: file});
  const j = await r.json(); if (!r.ok) throw new Error(j.error); return j;
}
function addApp() {
  const el = $("#tpl").content.firstElementChild.cloneNode(true);
  el.querySelector(".ipa").onchange = async e => {
    const f = e.target.files[0]; if (!f) return; const info = el.querySelector(".info");
    info.textContent = "загрузка…"; el.dataset.ipa = "";
    try {
      const j = await upload(f); el.dataset.ipa = j.id; const i = j.info;
      info.textContent = `${i.bundleIdentifier} · ${i.version} (${i.buildVersion}) · iOS ${i.minOSVersion}+ · ${(i.size/1048576).toFixed(1)} МБ`;
      const n = el.querySelector(".name"); if (!n.value) n.value = i.name;
    } catch (err) { info.textContent = err.message }
  };
  el.querySelector(".iconf").onchange = async e => {
    const f = e.target.files[0]; if (!f) return;
    el.querySelector(".icon").src = URL.createObjectURL(f);
    try { el.dataset.icon = (await upload(f)).id } catch (err) { log.textContent = err.message }
  };
  el.querySelector(".del").onclick = () => el.remove();
  $("#apps").append(el);
}
$("#add").onclick = addApp; addApp();

$("#go").onclick = async () => {
  const apps = [...document.querySelectorAll("#apps fieldset")].map(el => ({
    ipa: el.dataset.ipa, icon: el.dataset.icon || null,
    ...Object.fromEntries(["name","category","subtitle","description","notes"].map(k => [k, el.querySelector("."+k).value.trim()]))
  }));
  if (!apps.length || apps.some(a => !a.ipa)) return log.textContent = "выбери .ipa у каждого приложения и дождись загрузки";
  if (!$("#repo").value.trim()) return log.textContent = "укажи название репозитория";
  $("#go").disabled = true; log.textContent = "публикую, большие файлы грузятся долго…";
  try {
    const r = await fetch("/publish", {method: "POST", body: JSON.stringify({
      owner: $("#owner").value, repo: $("#repo").value, sourceName: $("#sname").value.trim(),
      sourceSubtitle: $("#ssub").value.trim(), tintColor: $("#tint").value, apps})});
    const j = await r.json();
    log.textContent = (j.log || []).join("\n") + "\n";
    if (!r.ok) log.textContent += "ошибка: " + j.error;
    else { const a = document.createElement("a"); a.href = a.textContent = j.url; a.target = "_blank"; log.append(a) }
  } catch (err) { log.textContent += err.message }
  $("#go").disabled = false;
};
</script>"""


def selftest():
    ipa = WORK / "t.ipa"
    with zipfile.ZipFile(ipa, "w") as z:
        z.writestr("Payload/T.app/Info.plist", plistlib.dumps({
            "CFBundleIdentifier": "a.b", "CFBundleShortVersionString": "2.0", "CFBundleVersion": "7",
            "CFBundleName": "T", "MinimumOSVersion": "15.0"}, fmt=plistlib.FMT_BINARY))
    i = ipa_info(ipa)
    assert (i["bundleIdentifier"], i["version"], i["buildVersion"], i["minOSVersion"]) == ("a.b", "2.0", "7", "15.0")
    src = {"apps": []}
    merge(src, {"bundleIdentifier": "a.b", "name": "T", "iconURL": ""}, {"version": "1.0"})
    merge(src, {"bundleIdentifier": "a.b", "name": "T2", "iconURL": ""}, {"version": "2.0"})
    merge(src, {"bundleIdentifier": "a.b", "name": "", "iconURL": ""}, {"version": "2.0", "x": 1})
    assert len(src["apps"]) == 1 and src["apps"][0]["name"] == "T2"
    assert [v["version"] for v in src["apps"][0]["versions"]] == ["2.0", "1.0"] and src["apps"][0]["versions"][0]["x"] == 1
    print("ok")


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        selftest()
    else:
        srv = ThreadingHTTPServer(("127.0.0.1", 8765), Handler)  # localhost only: it can push to your GitHub
        print("Source Studio: http://127.0.0.1:8765  (Ctrl+C — выход)")
        webbrowser.open("http://127.0.0.1:8765")
        try:
            srv.serve_forever()
        except KeyboardInterrupt:
            shutil.rmtree(WORK, ignore_errors=True)
