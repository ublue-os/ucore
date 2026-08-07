from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "validate-sbom.py"
SPEC = importlib.util.spec_from_file_location("validate_sbom", SCRIPT)
assert SPEC and SPEC.loader
VALIDATOR = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = VALIDATOR
SPEC.loader.exec_module(VALIDATOR)


class ValidateSbomTests(unittest.TestCase):
    def write_sbom(self, packages: list[dict]) -> Path:
        temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(temporary_directory.cleanup)
        path = Path(temporary_directory.name) / "sbom.json"
        path.write_text(json.dumps({"packages": packages}), encoding="utf-8")
        return path

    def test_accepts_target_arch_rpm_packages(self) -> None:
        path = self.write_sbom(
            [
                {"externalRefs": [{"referenceLocator": "pkg:rpm/fedora/bash@5?arch=aarch64"}]},
                {"externalRefs": [{"referenceLocator": "pkg:rpm/fedora/tmux@3?arch=noarch"}]},
            ]
        )

        VALIDATOR.validate_sbom(path, "aarch64")

    def test_rejects_rpm_packages_without_architecture_metadata(self) -> None:
        path = self.write_sbom(
            [{"externalRefs": [{"referenceLocator": "pkg:rpm/fedora/bash@5?distro=fedora-44"}]}]
        )

        with self.assertRaisesRegex(
            RuntimeError,
            r"packages=1, rpm_purls=1, target_rpms=0, noarch_rpms=0",
        ):
            VALIDATOR.validate_sbom(path, "aarch64")

    def test_rejects_noarch_only_rpm_packages(self) -> None:
        path = self.write_sbom(
            [{"externalRefs": [{"referenceLocator": "pkg:rpm/fedora/tmux@3?arch=noarch"}]}]
        )

        with self.assertRaisesRegex(RuntimeError, "no RPM package metadata for arm64"):
            VALIDATOR.validate_sbom(path, "aarch64")

    def test_rejects_foreign_arch_and_noarch_rpm_packages(self) -> None:
        path = self.write_sbom(
            [
                {"externalRefs": [{"referenceLocator": "pkg:rpm/fedora/bash@5?arch=x86_64"}]},
                {"externalRefs": [{"referenceLocator": "pkg:rpm/fedora/tmux@3?arch=noarch"}]},
            ]
        )

        with self.assertRaisesRegex(RuntimeError, "no RPM package metadata for arm64"):
            VALIDATOR.validate_sbom(path, "aarch64")


if __name__ == "__main__":
    unittest.main()
