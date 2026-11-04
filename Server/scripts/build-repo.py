#!/usr/bin/env python3
"""Builds the package site of one NAS system: a static site its app store reads updates from.

Every system gets its own site and git repository (fsdrive-packages-<system>). Layout for QNAP:
    repo.xml            App Center repository (App Center -> Settings -> App Repository)
    *.qpkg, icons/
    release.json        current version, files and SHA-256
    index.html          how to add the repository and install manually
    README.md           the same for the git repository page

usage: scripts/build-repo.py qnap --base-url https://example.com/fsdrive-packages-qnap [--out DIR]
   run scripts/build-qpkg.sh [--x86] first. scripts/publish-repo.sh publishes to GitHub Pages.
"""
import argparse
import hashlib
import html
import json
import re
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from xml.sax.saxutils import escape

SERVER = Path(__file__).resolve().parent.parent
ROOT = SERVER.parent
APP = json.loads((SERVER / "Packaging/repo/app.json").read_text())

# QPKG arch -> App Center platform IDs, one <platform> each: the installer (qpkgd) compares
# <platformID> as a whole with the NAS model (e.g. TS-X35EU) or platform, and does not split
# comma lists the way the web page does. TS-NASX86 covers every x86 model. ARM NAS report the
# platform TS-NASARM for 32-bit and 64-bit alike, so 64-bit ARM models are named one by one.
QNAP_PLATFORM_IDS = {
    "arm_64": ["TS-NASARM_64", "TS-X16", "TS-X28A", "TS-XA28A", "TS-X32", "TS-X32U", "TS-X33", "TS-X33U",
               "TS-X33EU", "TS-X35", "TS-X35A", "TS-X35EU", "TS-X42"],
    "x86_64": ["TS-NASX86"],
}


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def cdata(text):
    return "<![CDATA[" + text.replace("]]>", "]]]]><![CDATA[>") + "]]>"


def resize_icon(size, dest):
    """Renders Design/AppIcon.png at size x size (macOS sips)."""
    subprocess.run(["sips", "-z", str(size), str(size), str(ROOT / "Design/AppIcon.png"), "--out", str(dest)],
                   check=True, stdout=subprocess.DEVNULL)


def build_qnap(out, base_url, packages):
    cfg = (SERVER / "Packaging/qnap/qpkg.cfg").read_text()
    version = re.search(r'^QPKG_VER="(.*)"', cfg, re.M).group(1)
    name = re.search(r'^QPKG_NAME="(.*)"', cfg, re.M).group(1)
    qpkgs = {arch: packages / f"{name}_{version}_{arch}.qpkg" for arch in QNAP_PLATFORM_IDS}
    qpkgs = {arch: p for arch, p in qpkgs.items() if p.exists()}
    if not qpkgs:
        sys.exit(f"qnap: no {packages}/{name}_{version}_*.qpkg — run scripts/build-qpkg.sh first")

    (out / "icons").mkdir()
    for size in (80, 100):
        resize_icon(size, out / f"icons/{name}_{size}.png")
    # Settings page with demo data, in the order App Center shows them.
    (out / "snapshots").mkdir()
    snapshots = []
    for src in sorted((ROOT / "docs/screenshots").glob("qnap-*.png")):
        shutil.copy2(src, out / "snapshots" / src.name)
        snapshots.append(f"    <snapshot>{base_url}/snapshots/{src.name}</snapshot>")

    files, platforms = [], []
    for arch, src in qpkgs.items():
        shutil.copy2(src, out / src.name)
        files.append({"arch": arch, "url": f"{base_url}/{src.name}", "size": src.stat().st_size,
                      "sha256": sha256(src)})
        platforms += [f"""    <platform>
      <platformID>{pid}</platformID>
      <location>{escape(f"{base_url}/{src.name}")}</location>
    </platform>""" for pid in QNAP_PLATFORM_IDS[arch]]

    now = datetime.now(timezone.utc)
    # QPKG_SUMMARY and QTS_MINI_VERSION stay in qpkg.cfg: QTS enforces them from the package itself.
    xml = f"""<?xml version="1.0" encoding="utf-8"?>
<plugins>
  <cachechk>{now:%Y%m%d%H%M%S}</cachechk>
  <item>
    <name>{cdata(APP["name"])}</name>
    <internalName>{name}</internalName>
    <changeLog>{escape(base_url)}/</changeLog>
    <category>{escape(APP["category"])}</category>
    <type>{escape(APP["type"])}</type>
    <icon80>{base_url}/icons/{name}_80.png</icon80>
    <icon100>{base_url}/icons/{name}_100.png</icon100>
    <description>{cdata(APP["description"])}</description>
    <keyword>{escape(APP["keywords"])}</keyword>
    <version>{version}</version>
{chr(10).join(platforms)}
    <publishedDate>{now:%Y/%m/%d}</publishedDate>
    <maintainer>{cdata(APP["developer"])}</maintainer>
    <developer>{cdata(APP["developer"])}</developer>
    <developerLink>{cdata(APP["homepage"])}</developerLink>
    <forumlink>{cdata(APP["homepage"])}</forumlink>
    <language>{cdata("English, Українська")}</language>
{chr(10).join(snapshots)}
    <bannerImg>{cdata("")}</bannerImg>
    <tutorialLink>{cdata(base_url + "/")}</tutorialLink>
  </item>
</plugins>
"""
    (out / "repo.xml").write_text(xml)
    return {"version": version, "published": now.isoformat(timespec="seconds"),
            "source": f"{base_url}/repo.xml", "files": files,
            "snapshots": [f"snapshots/{p.name}" for p in sorted((out / "snapshots").glob("*.png"))]}


# To add a NAS system: write build_<system>(out, base_url, packages) that fills out/ from the
# built packages and returns its release dict, and register it here with its setup steps.
SYSTEMS = {
    "qnap": {
        "title": "QNAP (QTS, QuTS hero)",
        "build": build_qnap,
        "packages": SERVER / "build/qpkg",
        "install": "App Center → Settings → App Repository → Add, then paste the repository URL. "
                   "In App Center → Settings → General, allow applications without a valid digital signature.",
        "install_uk": "App Center → Налаштування → «Репозиторій застосунків» → «Додати», вставте адресу "
                      "репозиторію. У App Center → Налаштування → «Загальні» дозвольте застосунки без "
                      "дійсного цифрового підпису.",
        # App Center refuses to install from a repository over a package installed by hand ("Failed to
        # find the application on the cloud server"). It binds a package to a repository with the
        # `store` field in qpkg.conf, which holds the MD5 of the repository URL.
        "switch": "If FSDrive was installed by hand before, App Center refuses to install it from the repository. "
                  "Bind the installed package to the repository over SSH, then install; settings and files are kept:\n\n"
                  "```\nsetcfg FSDrive store $(printf %s '{source}' | md5sum | cut -c1-32) -f /etc/config/qpkg.conf\n```",
    },
}


def write_index(out, system, rel):
    files = "".join(f'<li><a href="{html.escape(f["url"])}">{html.escape(f["url"].rsplit("/", 1)[1])}</a></li>'
                    for f in rel["files"])
    title = f"{APP['name']} for {system['title']}"
    (out / "index.html").write_text(f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>{html.escape(title)}</title>
<style>
  :root {{ color-scheme: light dark; }}
  body {{ font: 16px/1.5 -apple-system, system-ui, sans-serif; max-width: 44rem; margin: 2rem auto; padding: 0 16px; }}
  pre {{ padding: .6rem .8rem; border-radius: 6px; background: color-mix(in srgb, currentColor 8%, transparent); overflow-x: auto; }}
  small {{ font-weight: normal; opacity: .6; }}
</style></head>
<body>
<h1>{html.escape(title)} <small>{html.escape(rel["version"])}</small></h1>
<p>{html.escape(APP["summary"])}</p>
<p>{html.escape(system["install"])}</p>
<pre>{html.escape(rel["source"])}</pre>
<p>Manual install:</p><ul>{files}</ul>
<p><a href="release.json">release.json</a> · <a href="{html.escape(APP["homepage"])}">{html.escape(APP["name"])}</a></p>
</body></html>
""")


def write_readme(out, base_url, system, rel):
    files = "\n".join(f"| {f['arch']} | [{f['url'].rsplit('/', 1)[1]}]({f['url']}) | `{f['sha256']}` |"
                      for f in rel["files"])
    (out / "README.md").write_text(f"""# {APP["name"]} for {system["title"]}

{APP["description"]}

{"".join(f"![{APP['name']}]({p})" + chr(10) for p in rel.get("snapshots", [])[:1])}
This repository holds only the built package site, served at <{base_url}/>; the source code is in
[{APP["name"]}]({APP["homepage"]}). It is regenerated and replaced on every release; do not edit it by hand.

## Install

{system["install"]}

```
{rel["source"]}
```

Version {rel["version"]}. To install manually, download the package for your NAS:

| Arch | Package | SHA-256 |
|---|---|---|
{files}

The package is not signed by the NAS vendor, so the app store shows a "no digital signature" notice.

{system.get("switch", "").format(source=rel["source"])}

## Встановлення

{system["install_uk"]}

License: {APP["license"]}.
""")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("system", choices=list(SYSTEMS))
    ap.add_argument("--base-url", required=True, help="public URL the site is served at")
    ap.add_argument("--out", help="default: build/repo/<system>")
    ap.add_argument("--packages", help="folder with the built packages; default: where the build script puts them")
    args = ap.parse_args()
    base_url = args.base_url.rstrip("/")
    out = Path(args.out or SERVER / "build/repo" / args.system)
    shutil.rmtree(out, ignore_errors=True)
    out.mkdir(parents=True)

    system = SYSTEMS[args.system]
    rel = system["build"](out, base_url, Path(args.packages) if args.packages else system["packages"])
    (out / "release.json").write_text(json.dumps(rel, indent=2) + "\n")
    write_index(out, system, rel)
    write_readme(out, base_url, system, rel)
    print(f"{args.system} {rel['version']}: {rel['source']}\n-> {out}")


if __name__ == "__main__":
    main()
