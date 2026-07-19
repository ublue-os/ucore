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
