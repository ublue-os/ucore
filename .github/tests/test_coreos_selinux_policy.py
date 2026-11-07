from __future__ import annotations

import os
from pathlib import Path
import subprocess
import unittest


REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "ucore" / "fix-coreos-selinux-policy.sh"
MOCKS = r'''
rpm() {
    case "$1" in
        -E) printf '%s\n' "$FEDORA" ;;
        -q)
            case "${@: -1}" in
                selinux-policy) printf '%s' "$POLICY" ;;
                selinux-policy-targeted) printf '%s' "$TARGETED" ;;
                container-selinux) printf '%s' "$CONTAINER" ;;
                *) return 99 ;;
            esac ;;
        --eval)
            case "$2" in
                *0:44.6-1.fc44*|*4:2.250.0-1.fc44*) echo -1 ;;
                *) echo 0 ;;
            esac ;;
        *) return 99 ;;
    esac
}
dnf() { printf 'UPGRADE %s\n' "$*"; return 23; }
'''


class CoreosSelinuxPolicyTests(unittest.TestCase):
    def run_workaround(self, **extra):
        env = os.environ | {
            "FEDORA": "45",
            "POLICY": "0:45.23-1.fc45",
            "TARGETED": "0:45.23-1.fc45",
            "CONTAINER": "4:2.251.0-1.fc45",
        } | extra
        return subprocess.run(
            ["bash", "-c", MOCKS + SCRIPT.read_text()],
            env=env, text=True, capture_output=True,
        )

    def test_other_fedora_releases_are_untouched(self):
        for release in ("44", "46"):
            with self.subTest(release=release):
                result = self.run_workaround(FEDORA=release, POLICY="0:44.6-1.fc44")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, "")

    def test_fixed_base_skips_workaround(self):
        result = self.run_workaround()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")

    def test_each_old_package_triggers_upgrade_and_failure_propagates(self):
        for variable, value in (
            ("POLICY", "0:44.6-1.fc44"),
            ("TARGETED", "0:44.6-1.fc44"),
            ("CONTAINER", "4:2.250.0-1.fc44"),
        ):
            with self.subTest(package=variable):
                result = self.run_workaround(**{variable: value})
                self.assertEqual(result.returncode, 23, result.stderr)
                self.assertIn("selinux-policy >= 45.23-1.fc45", result.stdout)
                self.assertIn("selinux-policy-targeted >= 45.23-1.fc45", result.stdout)
                self.assertIn("container-selinux >= 4:2.251.0-1.fc45", result.stdout)


if __name__ == "__main__":
    unittest.main()
