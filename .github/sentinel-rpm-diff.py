#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import shlex
import subprocess
import sys
import tempfile
from pathlib import Path
from urllib.parse import parse_qs, urlparse


SBOM_ARTIFACT_TYPE = "application/vnd.spdx+json"


def run_command(command: list[str]) -> str:
    result = subprocess.run(command, check=False, capture_output=True, text=True)
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or f"exit code {result.returncode}"
        raise RuntimeError(f"{' '.join(shlex.quote(part) for part in command)}: {detail}")
    return result.stdout


def run_json(command: list[str]) -> dict:
    return json.loads(run_command(command))


def normalize_arch(arch: str) -> str:
    if arch in ("x86_64", "amd64"):
        return "amd64"
    if arch in ("aarch64", "arm64"):
        return "arm64"
    return arch


def platform_digest(image_ref: str, arch: str) -> str:
    raw = json.loads(run_command(["skopeo", "inspect", "--raw", f"docker://{image_ref}"]))
    manifests = raw.get("manifests")
    if not manifests:
        inspect_data = run_json(["skopeo", "inspect", f"docker://{image_ref}"])
        return inspect_data["Digest"]

    expected_arch = normalize_arch(arch)
    for manifest in manifests:
        platform = manifest.get("platform", {})
        if platform.get("os") != "linux":
            continue
        if normalize_arch(platform.get("architecture", "")) == expected_arch:
            return manifest["digest"]
    raise RuntimeError(f"{image_ref}: no linux/{expected_arch} manifest found")


def discover_sbom(image_ref: str, digest: str) -> str:
    repository = image_ref.rsplit(":", 1)[0]
    data = run_json(
        [
            "oras",
            "discover",
            "--format",
            "json",
            "--depth",
            "1",
            "--artifact-type",
            SBOM_ARTIFACT_TYPE,
            f"{repository}@{digest}",
        ]
    )
    referrers = data.get("referrers", [])
    if not referrers:
        referrers = data.get("manifests", [])
    for referrer in referrers:
        artifact_type = referrer.get("artifactType") or referrer.get("mediaType")
        if artifact_type and artifact_type != SBOM_ARTIFACT_TYPE:
            continue
        digest = referrer.get("digest")
        if digest:
            return f"{repository}@{digest}"
    raise RuntimeError(f"{repository}@{digest}: no SPDX SBOM referrer found")


def pull_sbom(artifact_ref: str) -> Path:
    tempdir = tempfile.TemporaryDirectory(prefix="ucore-sentinel-sbom-")
    path = Path(tempdir.name)
    run_command(["oras", "pull", "--output", str(path), artifact_ref])
    candidates = sorted(path.rglob("*.json"))
    if not candidates:
        raise RuntimeError(f"{artifact_ref}: no JSON file pulled from SBOM artifact")
    # Keep the TemporaryDirectory alive through process exit.
    _TEMP_DIRS.append(tempdir)
    return candidates[0]


_TEMP_DIRS: list[tempfile.TemporaryDirectory] = []


def package_purl(package: dict) -> str | None:
    for ref in package.get("externalRefs", []):
        locator = ref.get("referenceLocator")
        if locator and locator.startswith("pkg:"):
            return locator
    return None


def rpm_packages(path: Path) -> dict[str, str]:
    data = json.loads(path.read_text(encoding="utf-8"))
    packages: dict[str, str] = {}
    for package in data.get("packages", []):
        purl = package_purl(package)
        if not purl or not purl.startswith("pkg:rpm/"):
            continue
        qualifiers = parse_qs(urlparse(purl).query, keep_blank_values=True)
        arch = normalize_arch((qualifiers.get("arch") or [""])[-1])
        if not arch:
            arch = normalize_arch(infer_arch_from_filename(package.get("packageFileName", "")))
        if not arch:
            continue
        name = package.get("name")
        version = package.get("versionInfo")
        if not name or not version:
            continue
        packages[f"{name}|{arch}"] = version
    if not packages:
        raise RuntimeError(f"{path}: no RPM packages found")
    return packages


def infer_arch_from_filename(filename: str) -> str:
    if filename.endswith(".x86_64.rpm"):
        return "amd64"
    if filename.endswith(".aarch64.rpm"):
        return "arm64"
    if filename.endswith(".noarch.rpm"):
        return "noarch"
    return ""


def has_diff(previous: dict[str, str], current: dict[str, str]) -> bool:
    if set(previous) != set(current):
        return True
    return any(previous[key] != current[key] for key in previous)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Detect RPM package diffs between a candidate SBOM and a published image.")
    parser.add_argument("--candidate-sbom", required=True, type=Path)
    parser.add_argument("--published-image", required=True)
    parser.add_argument("--arch", required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    digest = platform_digest(args.published_image, args.arch)
    published_sbom = pull_sbom(discover_sbom(args.published_image, digest))
    if has_diff(rpm_packages(published_sbom), rpm_packages(args.candidate_sbom)):
        print("changed=true")
    else:
        print("changed=false")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except RuntimeError as exc:
        print(f"error: {exc}", file=sys.stderr)
        sys.exit(1)
