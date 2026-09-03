from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path
from unittest.mock import patch


SCRIPT = Path(__file__).parents[1] / "sentinel-rpm-diff.py"
SPEC = importlib.util.spec_from_file_location("sentinel_rpm_diff", SCRIPT)
assert SPEC and SPEC.loader
SENTINEL = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = SENTINEL
SPEC.loader.exec_module(SENTINEL)


class SentinelRpmDiffTests(unittest.TestCase):
    def test_missing_published_sbom_requests_repair_build(self) -> None:
        arguments = [
            "sentinel-rpm-diff.py",
            "--candidate-sbom",
            "candidate.json",
            "--published-image",
            "example.invalid/ucore:lts",
            "--arch",
            "x86_64",
        ]
        error = SENTINEL.MissingSBOMError("example.invalid/ucore@sha256:bad: no SPDX SBOM referrer found")

        with (
            patch.object(sys, "argv", arguments),
            patch.object(SENTINEL, "platform_digest", return_value="sha256:bad"),
            patch.object(SENTINEL, "discover_sbom", side_effect=error),
            patch("builtins.print") as output,
        ):
            self.assertEqual(SENTINEL.main(), 0)

        output.assert_any_call("changed=true")

    def test_registry_errors_still_fail(self) -> None:
        arguments = [
            "sentinel-rpm-diff.py",
            "--candidate-sbom",
            "candidate.json",
            "--published-image",
            "example.invalid/ucore:lts",
            "--arch",
            "x86_64",
        ]

        with (
            patch.object(sys, "argv", arguments),
            patch.object(SENTINEL, "platform_digest", side_effect=RuntimeError("registry unavailable")),
        ):
            with self.assertRaisesRegex(RuntimeError, "registry unavailable"):
                SENTINEL.main()


if __name__ == "__main__":
    unittest.main()
