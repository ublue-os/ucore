from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import unittest


REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "ucore" / "install-ucore-minimal.sh"
PREPARE = SCRIPT.read_text().split("#### PREPARE\n", 1)[1].split("#### INSTALL", 1)[0]
OPENH264 = [
    "fedora-cisco-openh264",
    "fedora-cisco-openh264-debuginfo",
    "fedora-cisco-openh264-source",
]
MOCKS = r'''
set -euo pipefail
dnf() { printf 'dnf %s\n' "$*"; }
dnf5() {
    if [[ "$*" == 'repo list --all --json' ]]; then
        [[ "${FAIL_DISCOVERY:-0}" == 0 ]] || return 19
        printf '%s\n' "$REPOS"
    else
        printf 'dnf5 %s\n' "$*"
        [[ "${FAIL_CONFIG:-0}" == 0 ]] || return 23
    fi
}
'''


class InstallRepoTests(unittest.TestCase):
    def prepare(self, ids, stream="testing", **extra):
        env = os.environ | {
            "UCORE_STREAM": stream,
            "REPOS": json.dumps([{"id": repo, "is_enabled": False} for repo in ids]),
        } | extra
        return subprocess.run(
            ["bash", "-c", MOCKS + PREPARE],
            env=env, text=True, capture_output=True,
        )

    def test_testing_enables_only_binary_updates_and_disables_openh264(self):
        result = self.prepare(["fedora", "updates-testing", "updates-testing-source"] + OPENH264)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("dnf5 config-manager setopt updates-testing.enabled=1", result.stdout)
        self.assertNotIn("updates-testing-source.enabled", result.stdout)
        for repo in OPENH264:
            self.assertIn(f"dnf5 config-manager setopt {repo}.enabled=0", result.stdout)
        self.assertLess(result.stdout.index("install dnf5-plugins"), result.stdout.index("config-manager"))
        self.assertIn("dnf -y copr disable ublue-os/packages", result.stdout)
        self.assertIn("dnf -y copr disable ublue-os/staging", result.stdout)

    def test_stable_and_lts_leave_testing_unchanged(self):
        for stream in ("stable", "lts"):
            with self.subTest(stream=stream):
                result = self.prepare(["updates-testing"] + OPENH264, stream)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn("updates-testing.enabled", result.stdout)

    def test_absent_optional_repos_are_not_configured(self):
        result = self.prepare(["fedora", "updates-testing-source", "fedora-cisco-openh264-other"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("config-manager", result.stdout)
        for repo in ["updates-testing"] + OPENH264:
            self.assertIn(f"Skipping absent optional repository: {repo}", result.stdout)

    def test_empty_repo_list_is_allowed(self):
        result = self.prepare([])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("config-manager", result.stdout)

    def test_already_enabled_repos_are_discovered(self):
        repos = json.dumps([
            {"id": repo, "is_enabled": True}
            for repo in ["updates-testing"] + OPENH264
        ])
        result = self.prepare([], REPOS=repos)
        self.assertEqual(result.returncode, 0, result.stderr)
        for repo in OPENH264:
            self.assertIn(f"dnf5 config-manager setopt {repo}.enabled=0", result.stdout)

    def test_discovery_failure_aborts(self):
        result = self.prepare(["fedora"], FAIL_DISCOVERY="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("config-manager", result.stdout)
        self.assertNotIn("copr", result.stdout)

    def test_malformed_discovery_aborts(self):
        result = self.prepare([], REPOS="not json")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("copr", result.stdout)

    def test_configuration_failure_aborts(self):
        result = self.prepare(["updates-testing"], FAIL_CONFIG="1")
        self.assertEqual(result.returncode, 23)
        self.assertNotIn("copr", result.stdout)


if __name__ == "__main__":
    unittest.main()
