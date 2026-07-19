from __future__ import annotations

import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "sentinel-result-aggregate.py"
SPEC = importlib.util.spec_from_file_location("sentinel_result_aggregate", SCRIPT)
assert SPEC and SPEC.loader
AGGREGATE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = AGGREGATE
SPEC.loader.exec_module(AGGREGATE)


class SentinelResultAggregateTests(unittest.TestCase):
    def write_result(self, directory: Path, name: str, value: str) -> None:
        result_dir = directory / name
        result_dir.mkdir()
        (result_dir / "sentinel-result.env").write_text(value, encoding="utf-8")

    def test_all_unchanged_results_are_unchanged(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            directory = Path(temporary_directory)
            self.write_result(directory, "first", "changed=false\n")
            self.write_result(directory, "second", "changed=false\n")

            self.assertFalse(AGGREGATE.aggregate_results(directory, 2))

    def test_any_changed_result_requires_full_build(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            directory = Path(temporary_directory)
            self.write_result(directory, "first", "changed=false\n")
            self.write_result(directory, "second", "changed=true\n")

            self.assertTrue(AGGREGATE.aggregate_results(directory, 2))

    def test_missing_results_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            with self.assertRaisesRegex(RuntimeError, "expected 2 sentinel results, found 0"):
                AGGREGATE.aggregate_results(Path(temporary_directory), 2)

    def test_extra_results_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            directory = Path(temporary_directory)
            self.write_result(directory, "first", "changed=false\n")
            self.write_result(directory, "second", "changed=false\n")

            with self.assertRaisesRegex(RuntimeError, "expected 1 sentinel results, found 2"):
                AGGREGATE.aggregate_results(directory, 1)

    def test_invalid_result_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            directory = Path(temporary_directory)
            self.write_result(directory, "first", "changed=maybe\n")

            with self.assertRaisesRegex(RuntimeError, "changed=true or changed=false"):
                AGGREGATE.aggregate_results(directory, 1)

    def test_expected_count_uses_the_architecture_list(self) -> None:
        self.assertEqual(AGGREGATE.expected_result_count("['aarch64', 'x86_64']"), 4)


if __name__ == "__main__":
    unittest.main()
