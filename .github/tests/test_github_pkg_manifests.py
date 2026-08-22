from __future__ import annotations

import json
import re
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
MANIFESTS = [
    REPO / "ucore" / "github-pkgs-x86_64.json",
    REPO / "ucore" / "github-pkgs-aarch64.json",
    REPO / "ucore" / "github-pkgs-noarch.json",
    REPO / "ucore" / "ci-deps.json",
]


class GithubPkgManifestTests(unittest.TestCase):
    def test_manifests_exist(self) -> None:
        for path in MANIFESTS:
            with self.subTest(manifest=path.name):
                self.assertTrue(path.is_file(), f"missing manifest: {path}")

    def test_entries_have_required_fields(self) -> None:
        for path in MANIFESTS:
            with self.subTest(manifest=path.name):
                entries = json.loads(path.read_text(encoding="utf-8"))
                self.assertIsInstance(entries, list)
                self.assertGreater(len(entries), 0)
                for index, entry in enumerate(entries):
                    name = entry.get("name", index)
                    with self.subTest(entry=name):
                        self.assertIsInstance(entry, dict)
                        self.assertTrue(entry.get("name"))
                        self.assertTrue(entry.get("url"))
                        self.assertTrue(entry.get("repo"))
                        self.assertRegex(entry.get("sha256", ""), SHA256_RE)
                        self.assertTrue(entry.get("version") or entry.get("commit"))


if __name__ == "__main__":
    unittest.main()
