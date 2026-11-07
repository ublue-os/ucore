from __future__ import annotations

import io
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest


UCORE = Path(__file__).resolve().parents[2] / "ucore"


@unittest.skipUnless(shutil.which("just"), "just is required")
@unittest.skipIf(os.geteuid() == 0, "requires an unprivileged user to check permissions")
class GenSbomTests(unittest.TestCase):
    def run_recipe(self, syft_status: int) -> None:
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            bin_dir = work / "bin"
            bin_dir.mkdir()
            temp_dir = work / "tmp"
            temp_dir.mkdir()
            archive = work / "rootfs.tar"
            with tarfile.open(archive, "w") as exported:
                certs = tarfile.TarInfo("certs")
                certs.type = tarfile.DIRTYPE
                certs.mode = 0o555
                exported.addfile(certs)
                cert = tarfile.TarInfo("certs/example.pem")
                cert.mode = 0o444
                cert.size = 4
                exported.addfile(cert, io.BytesIO(b"test"))

            podman = bin_dir / "podman"
            podman.write_text(
                '#!/usr/bin/env bash\n'
                'case "$*" in\n'
                '  "image exists "*) exit 0 ;;\n'
                '  "container create "*) exit 0 ;;\n'
                '  "container rm "*) touch "$REMOVED" ;;\n'
                '  "export "*) cat "$ARCHIVE" ;;\n'
                '  *) exit 99 ;;\n'
                'esac\n'
            )
            podman.chmod(0o755)
            syft = bin_dir / "syft"
            syft.write_text(
                '#!/usr/bin/env bash\n'
                'set -eu\n'
                # Check that scanning still sees the original permissions.
                'test "$(stat -c %a "$3/certs")" = 555\n'
                'printf "{}\\n" > "${5#spdx-json=}"\n'
                'exit "$SYFT_STATUS"\n'
            )
            syft.chmod(0o755)
            removed = work / "removed"
            output = work / "sbom.json"
            result = subprocess.run(
                ["just", "gen-sbom", "test-image", str(output)],
                cwd=UCORE,
                env={
                    **os.environ,
                    "PATH": f"{bin_dir}:{os.environ['PATH']}",
                    "TMPDIR": str(temp_dir),
                    "SYFT_CMD": str(syft),
                    "SYFT_STATUS": str(syft_status),
                    "ARCHIVE": str(archive),
                    "REMOVED": str(removed),
                },
                capture_output=True,
                text=True,
            )
            try:
                if syft_status:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(f"exit code {syft_status}", result.stderr)
                else:
                    self.assertEqual(result.returncode, 0, result.stderr)
                self.assertTrue(output.exists(), result.stderr)
                self.assertTrue(removed.exists(), "temporary container was not removed")
                self.assertEqual(list(temp_dir.iterdir()), [], "temporary rootfs was not removed")
            finally:
                # Let the test clean up even when exercising the broken recipe.
                for parent, directories, _ in os.walk(temp_dir):
                    Path(parent).chmod(0o700)
                    for name in directories:
                        (Path(parent) / name).chmod(0o700)

    def test_cleans_read_only_directories_after_successful_scan(self) -> None:
        self.run_recipe(0)

    def test_preserves_scan_failure_and_cleans_read_only_directories(self) -> None:
        self.run_recipe(42)


if __name__ == "__main__":
    unittest.main()
