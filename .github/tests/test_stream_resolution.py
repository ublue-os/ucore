from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


UCORE = Path(__file__).resolve().parents[2] / "ucore"


class StreamResolutionTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.workdir = Path(self.directory.name)
        shutil.copy(UCORE / "Justfile", self.workdir)
        shutil.copy(UCORE / "Containerfile.in", self.workdir)
        skopeo = self.workdir / "skopeo"
        skopeo.write_text("""#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  *fedora-coreos:stable*) printf '{"Labels":{"org.opencontainers.image.version":"%s"}}\\n' "$MOCK_COREOS_VERSION" ;;
  *akmods-zfs:longterm-6.18-45*) printf '{"Labels":{"ostree.linux":"6.18.60-200.fc45.x86_64"}}\\n' ;;
  *akmods-zfs:coreos-stable-45*) printf '{"Labels":{"ostree.linux":"7.2.11-300.fc45.x86_64"}}\\n' ;;
  *) printf 'Unexpected skopeo call: %s\n' "$*" >&2; exit 1 ;;
esac
""")
        skopeo.chmod(0o755)

    def run_just(self, *args, stream="stable", **env):
        environment = os.environ | {
            "PATH": f"{self.workdir}:{os.environ['PATH']}",
            "UCORE_STREAM": stream,
            "KERNEL_FLAVOR": "longterm-6.18" if stream == "lts" else "coreos-stable",
            "FEDORA_VERSION": "",
            "MOCK_COREOS_VERSION": "45.20261030.3.1",
        } | env
        return subprocess.run(
            ["just", *args], cwd=self.workdir, env=environment,
            text=True, capture_output=True,
        )

    def test_stable_uses_f45_base_and_akmods(self):
        result = self.run_just("stream-info", "stream-info.env")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("FEDORA_VERSION=45\n", result.stdout)
        self.assertIn("IMAGE_VERSION=45.20261030.3.1\n", result.stdout)
        result = self.run_just("containerfile")
        self.assertEqual(result.returncode, 0, result.stderr)
        containerfile = (self.workdir / "Containerfile").read_text()
        self.assertIn("akmods-zfs:coreos-stable-45", containerfile)
        self.assertIn("fedora-coreos:45.20261030.3.1", containerfile)

    def test_lts_uses_f45_base_and_akmods(self):
        result = self.run_just("stream-info", "stream-info.env", stream="lts")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("FEDORA_VERSION=45\n", result.stdout)
        self.assertIn("IMAGE_VERSION=45.20261030.3.1\n", result.stdout)
        result = self.run_just("containerfile", stream="lts")
        self.assertEqual(result.returncode, 0, result.stderr)
        containerfile = (self.workdir / "Containerfile").read_text()
        self.assertIn("akmods-zfs:longterm-6.18-45", containerfile)
        self.assertIn("fedora-coreos:45.20261030.3.1", containerfile)

    def test_rejects_explicit_mismatched_fedora_version(self):
        result = self.run_just(
            "containerfile", "quay.io/fedora/fedora-coreos:45.20261030.3.1",
            FEDORA_VERSION="44",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not match CoreOS image", result.stderr)


if __name__ == "__main__":
    unittest.main()
