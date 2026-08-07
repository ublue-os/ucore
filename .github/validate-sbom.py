#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from urllib.parse import parse_qs, urlparse


def normalize_arch(arch: str) -> str:
    if arch in ("x86_64", "amd64"):
        return "amd64"
    if arch in ("aarch64", "arm64"):
        return "arm64"
    return arch


def rpm_purls(package: dict) -> list[str]:
    return [
        locator
        for ref in package.get("externalRefs", [])
        if (locator := ref.get("referenceLocator")) and locator.startswith("pkg:rpm/")
    ]


def validate_sbom(path: Path, arch: str) -> None:
    """Require architecture-qualified RPM PURLs; filename fallback hides degraded metadata."""
    data = json.loads(path.read_text(encoding="utf-8"))
    expected_arch = normalize_arch(arch)
    total_packages = len(data.get("packages", []))
    rpm_purl_count = 0
    target_rpm_count = 0
    noarch_rpm_count = 0

    for package in data.get("packages", []):
        for purl in rpm_purls(package):
            rpm_purl_count += 1
            qualifiers = parse_qs(urlparse(purl).query, keep_blank_values=True)
            package_arch = normalize_arch((qualifiers.get("arch") or [""])[-1])
            if package_arch == expected_arch:
                target_rpm_count += 1
            elif package_arch == "noarch":
                noarch_rpm_count += 1

    print(
        f"SBOM RPM metadata: packages={total_packages}, rpm_purls={rpm_purl_count}, "
        f"target_rpms={target_rpm_count}, noarch_rpms={noarch_rpm_count}"
    )
    if target_rpm_count == 0:
        raise RuntimeError(
            f"{path}: no RPM package metadata for {expected_arch} "
            f"(packages={total_packages}, rpm_purls={rpm_purl_count}, "
            f"target_rpms={target_rpm_count}, noarch_rpms={noarch_rpm_count})"
        )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Validate architecture-qualified RPM metadata in an SPDX SBOM.")
    parser.add_argument("--sbom", required=True, type=Path)
    parser.add_argument("--arch", required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    validate_sbom(args.sbom, args.arch)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, RuntimeError, json.JSONDecodeError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        sys.exit(1)
