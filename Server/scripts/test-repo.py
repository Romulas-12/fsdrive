#!/usr/bin/env python3
"""Tests for scripts/build-repo.py: builds the QNAP site from stand-in packages and checks it the
way App Center and its installer (qpkgd) read it.

usage: scripts/test-repo.py [-v]      (macOS: icons are made with sips)
"""
import hashlib
import json
import re
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

SERVER = Path(__file__).resolve().parent.parent
BUILD_REPO = SERVER / "scripts/build-repo.py"
BASE_URL = "https://example.test/fsdrive-packages-qnap"
CFG = (SERVER / "Packaging/qnap/qpkg.cfg").read_text()
NAME = re.search(r'^QPKG_NAME="(.*)"', CFG, re.M).group(1)
VERSION = re.search(r'^QPKG_VER="(.*)"', CFG, re.M).group(1)


def find_location(item, model, platform):
    """What qpkgd does: the first <platform> whose whole <platformID> is the NAS model or platform."""
    for p in item.findall("platform"):
        if p.findtext("platformID") in (model, platform):
            return p.findtext("location")
    return None


class QnapSite(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        tmp = Path(cls.tmp.name)
        packages = tmp / "qpkg"
        packages.mkdir()
        cls.packages = {}
        for arch in ("arm_64", "x86_64"):
            path = packages / f"{NAME}_{VERSION}_{arch}.qpkg"
            path.write_bytes(f"stand-in {arch} package".encode())
            cls.packages[arch] = path
        # A package of another version must not be picked up.
        (packages / f"{NAME}_0.0.1_arm_64.qpkg").write_bytes(b"old")
        cls.out = tmp / "site"
        subprocess.run([sys.executable, "-I", str(BUILD_REPO), "qnap", "--base-url", BASE_URL + "/",
                        "--out", str(cls.out), "--packages", str(packages)], check=True, stdout=subprocess.DEVNULL)
        cls.xml = ET.parse(cls.out / "repo.xml").getroot()
        cls.item = cls.xml.find("item")
        cls.release = json.loads((cls.out / "release.json").read_text())

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def local(self, url):
        """The file in the built site that a URL points to."""
        self.assertTrue(url.startswith(BASE_URL + "/"), url)
        return self.out / url[len(BASE_URL) + 1:]

    def test_one_item_with_package_name_and_version(self):
        self.assertEqual(self.xml.tag, "plugins")
        self.assertEqual(len(self.xml.findall("item")), 1)
        self.assertEqual(self.item.findtext("internalName"), NAME)
        self.assertEqual(self.item.findtext("version"), VERSION)
        self.assertRegex(self.xml.findtext("cachechk"), r"^\d{14}$")

    def test_platform_ids_are_single_values(self):
        # qpkgd compares <platformID> as a whole; a comma list matches no NAS.
        ids = [p.findtext("platformID") for p in self.item.findall("platform")]
        self.assertTrue(ids)
        for pid in ids:
            self.assertRegex(pid, r"^[A-Z0-9_-]+$")
        self.assertEqual(len(ids), len(set(ids)))

    def test_installer_finds_the_right_package(self):
        cases = {
            ("TS-X35EU", "TS-NASARM"): "arm_64",   # TS-435XeU, where the comma list failed
            ("TS-X35A", "TS-NASARM"): "arm_64",
            ("TS-X33", "TS-NASARM"): "arm_64",
            ("TS-X64", "TS-NASX86"): "x86_64",
            ("TS-X73A", "TS-NASX86"): "x86_64",
        }
        for (model, platform), arch in cases.items():
            with self.subTest(model=model):
                self.assertEqual(find_location(self.item, model, platform),
                                 f"{BASE_URL}/{self.packages[arch].name}")

    def test_32bit_arm_gets_nothing(self):
        # 32-bit ARM models report the same TS-NASARM platform; the arm_64 build cannot run there.
        for model in ("TS-X31P", "TS-X31P3", "TS-X41", "TS-X28"):
            with self.subTest(model=model):
                self.assertIsNone(find_location(self.item, model, "TS-NASARM"))

    def test_links_point_into_the_site(self):
        urls = [p.findtext("location") for p in self.item.findall("platform")]
        urls += [self.item.findtext("icon80"), self.item.findtext("icon100")]
        urls += [s.text for s in self.item.findall("snapshot")]
        self.assertGreaterEqual(len(self.item.findall("snapshot")), 1)
        for url in set(urls):
            with self.subTest(url=url):
                self.assertTrue(self.local(url).is_file())

    def test_icons_have_store_sizes(self):
        for size in (80, 100):
            with self.subTest(size=size):
                out = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight",
                                      str(self.local(self.item.findtext(f"icon{size}")))],
                                     check=True, capture_output=True, text=True).stdout
                self.assertIn(f"pixelWidth: {size}", out)
                self.assertIn(f"pixelHeight: {size}", out)

    def test_description_and_listing_fields(self):
        app = json.loads((SERVER / "Packaging/repo/app.json").read_text())
        self.assertEqual(self.item.findtext("description"), app["description"])
        self.assertEqual(self.item.findtext("type"), app["type"])
        self.assertEqual(self.item.findtext("maintainer"), app["developer"])
        self.assertRegex(self.item.findtext("publishedDate"), r"^\d{4}/\d{2}/\d{2}$")

    def test_release_json_matches_files(self):
        self.assertEqual(self.release["version"], VERSION)
        self.assertEqual(self.release["source"], f"{BASE_URL}/repo.xml")
        self.assertEqual({f["arch"] for f in self.release["files"]}, set(self.packages))
        for f in self.release["files"]:
            with self.subTest(arch=f["arch"]):
                data = self.local(f["url"]).read_bytes()
                self.assertEqual(f["size"], len(data))
                self.assertEqual(f["sha256"], hashlib.sha256(data).hexdigest())
        self.assertFalse(list(self.out.glob(f"{NAME}_0.0.1_*")))

    def test_pages_name_the_repository_url(self):
        for page in ("index.html", "README.md"):
            with self.subTest(page=page):
                self.assertIn(f"{BASE_URL}/repo.xml", (self.out / page).read_text())

    def test_store_binding_command(self):
        # App Center keeps the MD5 of the repository URL in qpkg.conf `store`; the README command
        # must compute it from the exact URL.
        cmd = re.search(r"^setcfg .*$", (self.out / "README.md").read_text(), re.M).group(0)
        url = re.search(r"printf %s '([^']+)'", cmd).group(1)
        self.assertEqual(url, f"{BASE_URL}/repo.xml")
        self.assertIn("md5sum", cmd)


class Helpers(unittest.TestCase):
    def test_cdata_survives_its_end_marker(self):
        sys.path.insert(0, str(BUILD_REPO.parent))
        import importlib.util
        spec = importlib.util.spec_from_file_location("build_repo", BUILD_REPO)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        text = "a ]]> b & <c>"
        self.assertEqual(ET.fromstring(f"<d>{mod.cdata(text)}</d>").text, text)


if __name__ == "__main__":
    unittest.main()
