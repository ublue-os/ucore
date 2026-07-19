#!/usr/bin/env python3

from __future__ import annotations

import argparse
import ast
import sys
from pathlib import Path


def read_changed_result(path: Path) -> bool:
    lines = [line.strip() for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]
    if lines == ["changed=true"]:
        return True
    if lines == ["changed=false"]:
        return False
    raise RuntimeError(f"{path}: expected exactly one changed=true or changed=false assignment")


def aggregate_results(results_dir: Path, expected_results: int) -> bool:
    if expected_results < 1:
        raise RuntimeError(f"expected result count must be positive: {expected_results}")

    result_files = sorted(results_dir.rglob("sentinel-result.env"))
    if len(result_files) != expected_results:
        raise RuntimeError(
            f"expected {expected_results} sentinel results, found {len(result_files)} in {results_dir}"
        )
    return any(read_changed_result(path) for path in result_files)


def expected_result_count(architectures: str, nvidia_variants: int = 2) -> int:
    try:
        parsed_architectures = ast.literal_eval(architectures)
    except (SyntaxError, ValueError) as exc:
        raise RuntimeError(f"invalid architecture list: {architectures}") from exc
    if not isinstance(parsed_architectures, list) or not all(
        isinstance(architecture, str) for architecture in parsed_architectures
    ):
        raise RuntimeError(f"architecture list must contain strings: {architectures}")
    if nvidia_variants < 1:
        raise RuntimeError(f"NVIDIA variant count must be positive: {nvidia_variants}")
    return len(parsed_architectures) * nvidia_variants


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Aggregate sentinel package-diff results.")
    parser.add_argument("--results-dir", required=True, type=Path)
    expected_results = parser.add_mutually_exclusive_group(required=True)
    expected_results.add_argument("--expected-results", type=int)
    expected_results.add_argument("--architectures")
    parser.add_argument("--nvidia-variants", type=int, default=2)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    expected_results = args.expected_results
    if args.architectures:
        expected_results = expected_result_count(args.architectures, args.nvidia_variants)
    changed = aggregate_results(args.results_dir, expected_results)
    print(f"changed={'true' if changed else 'false'}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except RuntimeError as exc:
        print(f"error: {exc}", file=sys.stderr)
        sys.exit(1)
