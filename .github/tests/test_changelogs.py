from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path
from types import SimpleNamespace


SCRIPT = Path(__file__).parents[1] / "changelogs.py"
SPEC = importlib.util.spec_from_file_location("changelogs", SCRIPT)
assert SPEC and SPEC.loader
CHANGELOGS = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = CHANGELOGS
SPEC.loader.exec_module(CHANGELOGS)


def make_ref(image_name: str, tag_suffix: str, previous_tag: str | None) -> "CHANGELOGS.ImageRef":
    return CHANGELOGS.ImageRef(
        repository=f"ghcr.io/ublue-os/{image_name}",
        tag=f"stable{tag_suffix}",
        digest="sha256:deadbeef",
        labels={},
        manifests=[],
        matched_dated_tag=f"stable{tag_suffix}-20260815",
        previous_dated_tag=previous_tag,
    )


def full_refs_and_diffs(
    overrides: dict[tuple[str, str], dict[str, "CHANGELOGS.PackageDiff"]],
) -> tuple[dict, dict]:
    """Build refs_by_variant/variant_diffs for all 9 VARIANTS, empty unless overridden."""
    refs_by_variant = {}
    variant_diffs = {}
    for variant in CHANGELOGS.VARIANTS:
        refs_by_variant[variant] = make_ref(variant.image_name, variant.tag_suffix, "stable-20260814")
        variant_diffs[variant] = overrides.get((variant.image_name, variant.tag_suffix), {})
    return refs_by_variant, variant_diffs


def changed(name: str, previous: str, current: str) -> "CHANGELOGS.PackageDiff":
    entry = CHANGELOGS.ChangedEntry(name=name, previous_version=previous, current_version=current)
    return CHANGELOGS.PackageDiff(added=[], removed=[], changed=[entry])


class TieredDiffTests(unittest.TestCase):
    def test_change_uniform_across_a_tier_is_shown_once_not_duplicated(self) -> None:
        diff = {"amd64": changed("systemd", "259.6-1.fc44", "259.7-1.fc44")}
        overrides = {
            ("ucore", ""): diff,
            ("ucore", "-nvidia"): diff,
            ("ucore", "-nvidia-lts"): diff,
        }
        refs_by_variant, variant_diffs = full_refs_and_diffs(overrides)
        primary_ref = refs_by_variant[CHANGELOGS.Variant("ucore", "uCore", "")]

        lines = CHANGELOGS.render_tiered_diffs(primary_ref, refs_by_variant, variant_diffs)
        text = "\n".join(lines)

        self.assertIn("systemd", text)
        self.assertIn("## All ucore Images", text)
        self.assertNotIn("Additional Changes", text)

    def test_flavor_and_arch_specific_change_is_not_silently_dropped(self) -> None:
        # Reproduces the real xdg-dbus-proxy case: a package that only changed for one
        # flavor (nvidia-lts) on one architecture (amd64), and nowhere else.
        overrides = {
            ("ucore", "-nvidia-lts"): {
                # A comparison always covers every arch that was built; arm64 is
                # present but empty here because it simply didn't get the bump yet.
                "amd64": changed("xdg-dbus-proxy", "0.1.7-1.fc44", "0.1.8-1.fc44"),
                "arm64": CHANGELOGS.PackageDiff(added=[], removed=[], changed=[]),
            },
        }
        refs_by_variant, variant_diffs = full_refs_and_diffs(overrides)
        primary_ref = refs_by_variant[CHANGELOGS.Variant("ucore", "uCore", "")]

        lines = CHANGELOGS.render_tiered_diffs(primary_ref, refs_by_variant, variant_diffs)
        text = "\n".join(lines)

        self.assertIn("xdg-dbus-proxy", text)
        self.assertIn("uCore NVIDIA LTS — Additional Changes", text)
        # Must be attributed to amd64 only, not printed as if it applies to both arches.
        self.assertIn("Architecture-specific changes for `amd64`", text)

    def test_change_shared_by_both_nvidia_flavors_is_shown_once_via_nvidia_section(self) -> None:
        diff = {
            "amd64": changed("nvidia-container-toolkit", "1.19.0-1", "1.20.0-1"),
            "arm64": changed("nvidia-container-toolkit", "1.19.0-1", "1.20.0-1"),
        }
        overrides = {
            ("ucore-minimal", "-nvidia"): diff,
            ("ucore", "-nvidia"): diff,
            ("ucore-hci", "-nvidia"): diff,
            ("ucore-minimal", "-nvidia-lts"): diff,
            ("ucore", "-nvidia-lts"): diff,
            ("ucore-hci", "-nvidia-lts"): diff,
        }
        refs_by_variant, variant_diffs = full_refs_and_diffs(overrides)
        primary_ref = refs_by_variant[CHANGELOGS.Variant("ucore", "uCore", "")]

        lines = CHANGELOGS.render_tiered_diffs(primary_ref, refs_by_variant, variant_diffs)
        text = "\n".join(lines)

        self.assertEqual(text.count("nvidia-container-toolkit"), 1)
        self.assertIn("## All NVIDIA Images", text)
        self.assertNotIn("Additional Changes", text)

    def test_identical_leftover_on_two_variants_is_grouped_into_one_section(self) -> None:
        # ucore-hci-nvidia inherits ucore-nvidia's layer, so an untiered change often
        # lands identically on both. It should be attributed to both, not just the first.
        diff = {
            "amd64": changed("some-driver-helper", "1.0-1.fc44", "1.1-1.fc44"),
            "arm64": CHANGELOGS.PackageDiff(added=[], removed=[], changed=[]),
        }
        overrides = {
            ("ucore", "-nvidia"): diff,
            ("ucore-hci", "-nvidia"): diff,
        }
        refs_by_variant, variant_diffs = full_refs_and_diffs(overrides)
        primary_ref = refs_by_variant[CHANGELOGS.Variant("ucore", "uCore", "")]

        lines = CHANGELOGS.render_tiered_diffs(primary_ref, refs_by_variant, variant_diffs)
        text = "\n".join(lines)

        self.assertEqual(text.count("some-driver-helper"), 1)
        self.assertIn("uCore NVIDIA / uCore HCI NVIDIA — Additional Changes", text)

    def test_added_and_removed_leftover_entries_on_a_non_nvidia_variant(self) -> None:
        diff = {
            "amd64": CHANGELOGS.PackageDiff(
                added=[CHANGELOGS.AddedEntry(name="new-tool", version="1.0-1.fc44")],
                removed=[CHANGELOGS.RemovedEntry(name="old-tool", version="0.9-1.fc44")],
                changed=[],
            ),
            "arm64": CHANGELOGS.PackageDiff(added=[], removed=[], changed=[]),
        }
        overrides = {("ucore-minimal", ""): diff}
        refs_by_variant, variant_diffs = full_refs_and_diffs(overrides)
        primary_ref = refs_by_variant[CHANGELOGS.Variant("ucore", "uCore", "")]

        lines = CHANGELOGS.render_tiered_diffs(primary_ref, refs_by_variant, variant_diffs)
        text = "\n".join(lines)

        self.assertIn("uCore Minimal — Additional Changes", text)
        self.assertIn("+ new-tool", text)
        self.assertIn("- old-tool", text)

    def test_variant_with_no_previous_dated_tag_renders_no_empty_section(self) -> None:
        refs_by_variant, variant_diffs = full_refs_and_diffs({})
        # Simulate a variant with nothing to compare against, per main()'s handling.
        no_history_variant = CHANGELOGS.Variant("ucore-hci", "uCore HCI", "-nvidia-lts")
        refs_by_variant[no_history_variant] = make_ref("ucore-hci", "-nvidia-lts", None)
        variant_diffs[no_history_variant] = {}
        primary_ref = refs_by_variant[CHANGELOGS.Variant("ucore", "uCore", "")]

        lines = CHANGELOGS.render_tiered_diffs(primary_ref, refs_by_variant, variant_diffs)
        text = "\n".join(lines)

        self.assertNotIn("uCore HCI NVIDIA LTS — Additional Changes", text)


class DatedTagsTests(unittest.TestCase):
    def test_uses_existing_tags_across_long_calendar_gaps(self) -> None:
        tags = [
            "stable-20260621",
            "stable-20260501",
            "stable-20260401",
            "stable-nvidia-20260501",
            "testing-20260401",
        ]

        self.assertEqual(
            CHANGELOGS.dated_tags(tags, "stable", "20260620", 20),
            ["stable-20260501", "stable-20260401"],
        )

    def test_limits_existing_tags_not_calendar_days(self) -> None:
        tags = ["stable-20260501", "stable-20260401", "stable-20260301"]

        self.assertEqual(
            CHANGELOGS.dated_tags(tags, "stable", "20260620", 2),
            ["stable-20260501", "stable-20260401"],
        )

    def test_release_date_uses_the_configured_workflow_date(self) -> None:
        if hasattr(CHANGELOGS, "ARGS"):
            self.addCleanup(setattr, CHANGELOGS, "ARGS", CHANGELOGS.ARGS)
        else:
            self.addCleanup(delattr, CHANGELOGS, "ARGS")
        CHANGELOGS.ARGS = SimpleNamespace(release_date="20260620")

        self.assertEqual(CHANGELOGS.release_date(None), "20260620")


if __name__ == "__main__":
    unittest.main()
