#!/usr/bin/env python3
"""Checks a published QNAP package site: every link in repo.xml answers, and the packages served
are the ones release.json describes (size and SHA-256).

usage: scripts/check-repo.py https://romulas-12.github.io/fsdrive-packages-qnap [--wait-for CACHECHK]
   --wait-for waits (up to 5 minutes) until the site serves the repo.xml with that <cachechk>,
   as GitHub Pages takes a moment to deploy; scripts/publish-repo.sh passes it.
"""
import argparse
import hashlib
import json
import sys
import time
import urllib.request
import xml.etree.ElementTree as ET


def get(url, method="GET"):
    req = urllib.request.Request(url, method=method, headers={"Cache-Control": "no-cache"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.read() if method == "GET" else r.status


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("base_url")
    ap.add_argument("--wait-for", help="<cachechk> the site must serve")
    args = ap.parse_args()
    base = args.base_url.rstrip("/")

    deadline = time.time() + 300
    while True:
        root = ET.fromstring(get(f"{base}/repo.xml?t={time.time():.0f}"))
        if not args.wait_for or root.findtext("cachechk") == args.wait_for:
            break
        if time.time() > deadline:
            sys.exit(f"FAIL {base}/repo.xml still has cachechk {root.findtext('cachechk')}, not {args.wait_for}")
        time.sleep(5)

    item = root.find("item")
    release = json.loads(get(f"{base}/release.json"))
    failures = []
    if item.findtext("version") != release["version"]:
        failures.append(f"repo.xml version {item.findtext('version')} != release.json {release['version']}")

    urls = {p.findtext("location") for p in item.findall("platform")}
    urls |= {item.findtext("icon80"), item.findtext("icon100")} | {s.text for s in item.findall("snapshot")}
    for url in sorted(urls):
        try:
            get(url, "HEAD")
            print(f"  ok {url}")
        except Exception as e:
            failures.append(f"{url}: {e}")

    for f in release["files"]:
        data = get(f["url"])
        if len(data) != f["size"] or hashlib.sha256(data).hexdigest() != f["sha256"]:
            failures.append(f"{f['url']}: size or SHA-256 differs from release.json")
        else:
            print(f"  ok {f['url']} sha256 {f['sha256'][:16]}…")

    for msg in failures:
        print(f"  FAIL {msg}")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
