from __future__ import annotations

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "ucore" / "fix-coreos-selinux-policy.sh"
SUBS_DIST = SCRIPT.read_text().split("#### SUBS_DIST\n", 1)[1]
STOCK_SUBS_DIST = """\
/etc/systemd/system /usr/lib/systemd/system
/var/home            /home
/var/roothome        /root
/usr/etc             /etc
"""
POSTPROCESSED_SUBS_DIST = """\
/etc/systemd/system /usr/lib/systemd/system
# /var/home            /home
/var/roothome        /root
/usr/etc             /etc
/home /var/home
/usr/etc/systemd/system /usr/lib/systemd/system
/usr/lib/opt /opt
/var/lib/selinux /etc/selinux
"""
# The same file as rpm-ostree's postprocess_subs_dist writes it.
RPM_OSTREE_SUBS_DIST = """\
/etc/systemd/system /usr/lib/systemd/system
# https://github.com/projectatomic/rpm-ostree/pull/1754
# /var/home            /home
/var/roothome        /root
/usr/etc             /etc
# https://github.com/projectatomic/rpm-ostree/pull/1754
/home /var/home
# https://github.com/coreos/rpm-ostree/pull/5485
/usr/etc/systemd/system /usr/lib/systemd/system
# https://github.com/coreos/rpm-ostree/pull/1795
/usr/lib/opt /opt
# https://github.com/coreos/rpm-ostree/issues/5616
/var/lib/selinux /etc/selinux
"""
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


class SubsDistTests(unittest.TestCase):
    def postprocess(self, content):
        with tempfile.TemporaryDirectory() as tmp:
            subs_dist = Path(tmp) / "file_contexts.subs_dist"
            subs_dist.write_text(content)
            result = subprocess.run(
                ["bash", "-c", "set -euo pipefail\nsubs_dist=\"$1\"\n" + SUBS_DIST,
                 "bash", str(subs_dist)],
                text=True, capture_output=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            return subs_dist.read_text()

    def test_stock_file_gets_rpm_ostree_aliases(self):
        self.assertEqual(self.postprocess(STOCK_SUBS_DIST), POSTPROCESSED_SUBS_DIST)

    def test_postprocessed_file_is_unchanged(self):
        for content in (POSTPROCESSED_SUBS_DIST, RPM_OSTREE_SUBS_DIST):
            with self.subTest(content=content):
                self.assertEqual(self.postprocess(content), content)

    def test_file_without_usr_etc_gets_it_once(self):
        stock = STOCK_SUBS_DIST.replace("/usr/etc             /etc\n", "")
        result = self.postprocess(stock).splitlines()
        self.assertEqual(result.count("/usr/etc /etc"), 1)
        self.assertEqual(result[-5:], [
            "/home /var/home",
            "/usr/etc /etc",
            "/usr/etc/systemd/system /usr/lib/systemd/system",
            "/usr/lib/opt /opt",
            "/var/lib/selinux /etc/selinux",
        ])


if __name__ == "__main__":
    unittest.main()
