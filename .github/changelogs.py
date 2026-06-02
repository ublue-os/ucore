#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import re
import shlex
import subprocess
import sys
import tempfile
from collections import Counter
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from pathlib import Path
from urllib.parse import parse_qs, urlparse


SBOM_ARTIFACT_TYPE = "application/vnd.spdx+json"
DATE_RE = re.compile(r"^(?P<prefix>.+)-(?P<date>\d{8})$")


@dataclass(frozen=True)
class Variant:
    image_name: str
    display_name: str
    tag_suffix: str

    @property
    def moving_tag(self) -> str:
        return f"{ARGS.stream}{self.tag_suffix}"

    @property
    def section_name(self) -> str:
        if self.tag_suffix == "-nvidia":
            return f"{self.display_name} NVIDIA"
        if self.tag_suffix == "-nvidia-lts":
            return f"{self.display_name} NVIDIA LTS"
        return self.display_name


@dataclass(frozen=True)
class ChildManifest:
    arch: str
    digest: str


@dataclass
class ImageRef:
    repository: str
    tag: str
    digest: str
    labels: dict[str, str]
    manifests: list[ChildManifest]
    matched_dated_tag: str | None
    previous_dated_tag: str | None

    @property
    def ref(self) -> str:
        return f"{self.repository}:{self.tag}"


@dataclass(frozen=True)
class PackageEntry:
    name: str
    version: str


@dataclass
class ArtifactSbom:
    image_ref: str
    image_digest: str
    arch: str
    path: Path


@dataclass(frozen=True)
class AddedEntry:
    name: str
    version: str

    def render(self) -> str:
        return f"{self.name} {self.version}"


@dataclass(frozen=True)
class RemovedEntry:
    name: str
    version: str

    def render(self) -> str:
        return f"{self.name} {self.version}"


@dataclass(frozen=True)
class ChangedEntry:
    name: str
    previous_version: str
    current_version: str

    def render(self) -> str:
        return f"{self.name} {self.previous_version} -> {self.current_version}"


@dataclass
class PackageDiff:
    added: list[AddedEntry]
    removed: list[RemovedEntry]
    changed: list[ChangedEntry]

    def is_empty(self) -> bool:
        return not self.added and not self.removed and not self.changed


VARIANTS = [
    Variant("ucore-minimal", "uCore Minimal", ""),
    Variant("ucore", "uCore", ""),
    Variant("ucore-hci", "uCore HCI", ""),
    Variant("ucore-minimal", "uCore Minimal", "-nvidia"),
    Variant("ucore", "uCore", "-nvidia"),
    Variant("ucore-hci", "uCore HCI", "-nvidia"),
    Variant("ucore-minimal", "uCore Minimal", "-nvidia-lts"),
    Variant("ucore", "uCore", "-nvidia-lts"),
    Variant("ucore-hci", "uCore HCI", "-nvidia-lts"),
]

KEY_PACKAGE_NAMES = [
    "bootc",
    "containerd",
    "ignition",
    "kernel",
    "podman",
    "rpm-ostree",
    "systemd",
    "zfs",
]

ARCH_ORDER = ["amd64", "arm64"]

ARGS: argparse.Namespace
INSPECT_CACHE: dict[str, dict] = {}
RAW_MANIFEST_CACHE: dict[str, dict] = {}
LIST_TAGS_CACHE: dict[str, list[str]] = {}
SBOM_CACHE: dict[str, dict[str, PackageEntry]] = {}
ARTIFACT_SBOMS: dict[tuple[str, str], ArtifactSbom] = {}


def run_command(command: list[str], *, cwd: Path | None = None) -> str:
    result = subprocess.run(
        command,
        cwd=str(cwd) if cwd else None,
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        stderr = result.stderr.strip()
        stdout = result.stdout.strip()
        detail = stderr or stdout or f"command failed with exit code {result.returncode}"
        raise RuntimeError(f"{' '.join(shlex.quote(part) for part in command)}: {detail}")
    return result.stdout


def run_json(command: list[str], *, cwd: Path | None = None) -> dict:
    output = run_command(command, cwd=cwd)
    try:
        return json.loads(output)
    except json.JSONDecodeError as exc:
        raise RuntimeError(
            f"{' '.join(shlex.quote(part) for part in command)}: invalid JSON output"
        ) from exc


def log(message: str) -> None:
    print(f"changelog: {message}", file=sys.stderr, flush=True)


def ensure_command(name: str) -> None:
    result = subprocess.run(
        ["bash", "-lc", f"command -v {shlex.quote(name)} >/dev/null 2>&1"],
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(f"required command not found: {name}")


def image_repository(image_name: str) -> str:
    return f"{ARGS.image_registry}/{image_name}"


def inspect_reference(reference: str) -> dict:
    if reference not in INSPECT_CACHE:
        INSPECT_CACHE[reference] = run_json(["skopeo", "inspect", f"docker://{reference}"])
    return INSPECT_CACHE[reference]


def inspect_raw(reference: str) -> dict:
    if reference not in RAW_MANIFEST_CACHE:
        RAW_MANIFEST_CACHE[reference] = json.loads(
            run_command(["skopeo", "inspect", "--raw", f"docker://{reference}"])
        )
    return RAW_MANIFEST_CACHE[reference]


def list_tags(repository: str) -> list[str]:
    if repository not in LIST_TAGS_CACHE:
        tag_data = run_json(["skopeo", "list-tags", f"docker://{repository}"])
        LIST_TAGS_CACHE[repository] = sorted(tag_data.get("Tags", []))
    return LIST_TAGS_CACHE[repository]


def extract_children(reference: str) -> list[ChildManifest]:
    raw = inspect_raw(reference)
    manifests = raw.get("manifests")
    if not manifests:
        inspect_data = inspect_reference(reference)
        arch = normalize_arch(inspect_data.get("Architecture", "unknown"))
        digest = inspect_data.get("Digest")
        if not digest:
            raise RuntimeError(f"{reference}: missing digest")
        return [ChildManifest(arch=arch, digest=digest)]

    children = []
    for manifest in manifests:
        platform = manifest.get("platform", {})
        if platform.get("os") != "linux":
            continue
        digest = manifest.get("digest")
        arch = normalize_arch(platform.get("architecture", "unknown"))
        if not digest:
            continue
        children.append(ChildManifest(arch=arch, digest=digest))
    if not children:
        raise RuntimeError(f"{reference}: no linux child manifests found")
    children.sort(key=lambda item: ARCH_ORDER.index(item.arch) if item.arch in ARCH_ORDER else len(ARCH_ORDER))
    return children


def normalize_arch(arch: str) -> str:
    if arch in ("x86_64", "amd64"):
        return "amd64"
    if arch in ("aarch64", "arm64"):
        return "arm64"
    return arch


def dated_tags_for_prefix(repository: str, prefix: str) -> list[str]:
    matches = []
    for tag in list_tags(repository):
        match = DATE_RE.match(tag)
        if not match:
            continue
        if match.group("prefix") != prefix:
            continue
        matches.append(tag)
    matches.sort(reverse=True)
    if ARGS.max_dated_tags > 0:
        matches = matches[:ARGS.max_dated_tags]
    return matches


def dated_tags_from_release_date(prefix: str) -> list[str]:
    if not ARGS.release_date:
        return []

    try:
        start_date = datetime.strptime(ARGS.release_date, "%Y%m%d").date()
    except ValueError as exc:
        raise RuntimeError(f"release date must use YYYYMMDD format: {ARGS.release_date}") from exc

    tag_count = ARGS.max_dated_tags
    if tag_count <= 0:
        tag_count = 20

    return [
        f"{prefix}-{(start_date - timedelta(days=offset)).strftime('%Y%m%d')}"
        for offset in range(tag_count)
    ]


def inspect_reference_or_none(reference: str) -> dict | None:
    try:
        return inspect_reference(reference)
    except RuntimeError:
        return None


def resolve_image_ref(repository: str, tag: str) -> ImageRef:
    inspect_data = inspect_reference(f"{repository}:{tag}")
    digest = inspect_data.get("Digest")
    if not digest:
        raise RuntimeError(f"{repository}:{tag}: missing digest")

    dated_tags = dated_tags_from_release_date(tag)
    if not dated_tags:
        dated_tags = dated_tags_for_prefix(repository, tag)

    matched_dated_tag = None
    previous_dated_tag = None

    for dated_tag in dated_tags:
        dated_inspect = inspect_reference_or_none(f"{repository}:{dated_tag}")
        if not dated_inspect:
            continue
        dated_digest = dated_inspect.get("Digest")
        if dated_digest == digest and matched_dated_tag is None:
            matched_dated_tag = dated_tag
            continue
        if dated_digest != digest:
            previous_dated_tag = dated_tag
            break

    return ImageRef(
        repository=repository,
        tag=tag,
        digest=digest,
        labels=inspect_data.get("Labels", {}),
        manifests=extract_children(f"{repository}:{tag}"),
        matched_dated_tag=matched_dated_tag,
        previous_dated_tag=previous_dated_tag,
    )


def discover_sbom_artifact(subject_ref: str) -> str:
    discover_data = run_json(
        [
            "oras",
            "discover",
            "--format",
            "json",
            "--depth",
            "1",
            "--artifact-type",
            SBOM_ARTIFACT_TYPE,
            subject_ref,
        ]
    )
    referrers = discover_data.get("referrers")
    if referrers is None:
        referrers = discover_data.get("manifests")
    if not referrers:
        raise RuntimeError(f"{subject_ref}: no SPDX SBOM referrer found")

    for referrer in referrers:
        artifact_type = referrer.get("artifactType") or referrer.get("mediaType")
        if artifact_type and artifact_type != SBOM_ARTIFACT_TYPE:
            continue
        digest = referrer.get("digest")
        if not digest:
            continue
        repository = subject_ref.split("@", 1)[0]
        return f"{repository}@{digest}"
    raise RuntimeError(f"{subject_ref}: unable to determine SPDX SBOM artifact reference")


def parse_spdx_sbom(path: Path) -> dict[str, PackageEntry]:
    with path.open("r", encoding="utf-8") as handle:
        data = json.load(handle)

    packages: dict[str, PackageEntry] = {}
    for package in data.get("packages", []):
        purl = package_purl(package)
        if not purl or not purl.startswith("pkg:rpm/"):
            continue
        qualifiers = parse_purl_qualifiers(purl)
        arch = normalize_arch(qualifiers.get("arch", ""))
        if not arch:
            arch = normalize_arch(infer_arch_from_filename(package.get("packageFileName", "")))
        if not arch:
            continue
        name = package.get("name")
        version = package.get("versionInfo")
        if not name or not version:
            continue
        key = f"{name}|{arch or 'unknown'}"
        packages[key] = PackageEntry(name=name, version=version)
    if not packages:
        raise RuntimeError(f"{path}: no RPM packages found in SPDX SBOM")
    return packages


def package_purl(package: dict) -> str | None:
    for ref in package.get("externalRefs", []):
        locator = ref.get("referenceLocator")
        if locator and locator.startswith("pkg:"):
            return locator
    return None


def parse_purl_qualifiers(purl: str) -> dict[str, str]:
    parsed = urlparse(purl)
    qualifiers = parse_qs(parsed.query, keep_blank_values=True)
    return {key: values[-1] for key, values in qualifiers.items()}


def infer_arch_from_filename(filename: str) -> str:
    if filename.endswith(".x86_64.rpm"):
        return "amd64"
    if filename.endswith(".aarch64.rpm"):
        return "arm64"
    if filename.endswith(".noarch.rpm"):
        return "noarch"
    return ""


def sbom_packages_for_child(repository: str, digest: str) -> dict[str, PackageEntry]:
    key = f"{repository}@{digest}"
    if key in SBOM_CACHE:
        return SBOM_CACHE[key]

    artifact_ref = discover_sbom_artifact(key)
    with tempfile.TemporaryDirectory(prefix="ucore-changelog-sbom-") as tempdir:
        log(f"pulling SBOM {artifact_ref}")
        run_command(["oras", "pull", "--output", tempdir, artifact_ref])
        temp_path = Path(tempdir)
        candidates = sorted(temp_path.rglob("*.json"))
        if not candidates:
            raise RuntimeError(f"{artifact_ref}: no JSON file pulled from SBOM artifact")
        SBOM_CACHE[key] = parse_spdx_sbom(candidates[0])
    return SBOM_CACHE[key]


def resolve_packages(image_ref: ImageRef, *, prefer_current_artifacts: bool = False) -> dict[str, dict[str, PackageEntry]]:
    packages_by_arch: dict[str, dict[str, PackageEntry]] = {}
    for manifest in image_ref.manifests:
        subject = f"{image_ref.repository}@{manifest.digest}"
        if prefer_current_artifacts:
            artifact = ARTIFACT_SBOMS.get((image_ref.repository, manifest.digest))
            if artifact:
                if artifact.arch != manifest.arch:
                    raise RuntimeError(
                        f"{artifact.path}: artifact arch {artifact.arch} does not match "
                        f"{subject} ({manifest.arch})"
                    )
                log(f"using current artifact SBOM {artifact.path}")
                packages_by_arch[manifest.arch] = parse_spdx_sbom(artifact.path)
                continue

        packages_by_arch[manifest.arch] = sbom_packages_for_child(image_ref.repository, manifest.digest)
        if not packages_by_arch[manifest.arch]:
            raise RuntimeError(f"{subject}: no packages resolved from SBOM")
    return packages_by_arch


def diff_packages(
    previous: dict[str, PackageEntry], current: dict[str, PackageEntry]
) -> PackageDiff:
    previous_keys = set(previous)
    current_keys = set(current)

    added = [
        AddedEntry(name=current[key].name, version=current[key].version)
        for key in sorted(current_keys - previous_keys)
    ]
    removed = [
        RemovedEntry(name=previous[key].name, version=previous[key].version)
        for key in sorted(previous_keys - current_keys)
    ]
    changed = []
    for key in sorted(previous_keys & current_keys):
        prev_entry = previous[key]
        cur_entry = current[key]
        if prev_entry.version == cur_entry.version:
            continue
        changed.append(
            ChangedEntry(
                name=cur_entry.name,
                previous_version=prev_entry.version,
                current_version=cur_entry.version,
            )
        )
    return PackageDiff(added=added, removed=removed, changed=changed)


def common_entries_across_arches(entries_by_arch: dict[str, list]) -> tuple[list, dict[str, list]]:
    if not entries_by_arch:
        return [], {}

    signature_sets = {
        arch: {entry.render() for entry in entries}
        for arch, entries in entries_by_arch.items()
    }
    common_signatures = set.intersection(*signature_sets.values()) if signature_sets else set()

    common = []
    arch_specific: dict[str, list] = {}
    for arch, entries in entries_by_arch.items():
        filtered = []
        for entry in entries:
            if entry.render() in common_signatures:
                if arch == next(iter(entries_by_arch)):
                    common.append(entry)
            else:
                filtered.append(entry)
        arch_specific[arch] = filtered

    common.sort(key=lambda entry: entry.render())
    for values in arch_specific.values():
        values.sort(key=lambda entry: entry.render())
    return common, arch_specific


def key_package_versions(
    packages_by_arch: dict[str, dict[str, PackageEntry]],
    package_names: list[str],
) -> list[tuple[str, str]]:
    if not packages_by_arch:
        return []

    versions = []
    for package_name in package_names:
        rendered_versions = []
        seen = set()
        for arch in ARCH_ORDER:
            arch_packages = packages_by_arch.get(arch)
            if not arch_packages:
                continue
            for key, entry in sorted(arch_packages.items()):
                if not key.startswith(f"{package_name}|"):
                    continue
                value = f"{entry.name} {entry.version}"
                if value in seen:
                    continue
                seen.add(value)
                rendered_versions.append(value)
        if rendered_versions:
            versions.append((package_name, ", ".join(rendered_versions)))
    return versions


def package_version(
    packages_by_arch: dict[str, dict[str, PackageEntry]],
    package_name: str,
) -> str | None:
    for name, version in key_package_versions(packages_by_arch, [package_name]):
        if name == package_name:
            return strip_package_names(version, package_name)
    return None


def strip_package_names(version: str, package_name: str) -> str:
    parts = []
    for value in version.split(", "):
        prefix = f"{package_name} "
        if value.startswith(prefix):
            value = value[len(prefix):]
        value = strip_rpm_epoch(value)
        parts.append(value)
    return ", ".join(parts)


def strip_rpm_epoch(version: str) -> str:
    if ":" not in version:
        return version
    epoch, rest = version.split(":", 1)
    if not epoch.isdigit():
        return version
    return rest


def short_revision(labels: dict[str, str]) -> str | None:
    revision = labels.get("org.opencontainers.image.revision")
    if not revision:
        return None
    return revision[:7]


def release_date(primary_ref: ImageRef) -> str:
    tag = primary_ref.matched_dated_tag
    if tag:
        match = DATE_RE.match(tag)
        if match:
            return match.group("date")
    return datetime.now(UTC).strftime("%Y%m%d")


def previous_release_tag(primary_ref: ImageRef) -> str | None:
    return primary_ref.previous_dated_tag


def render_section_header(title: str, current_ref: ImageRef, previous_tag: str | None) -> list[str]:
    lines = [f"## {title}", ""]
    if previous_tag:
        lines.append(
            f"Compared `{current_ref.repository}:{current_ref.tag}` against "
            f"`{current_ref.repository}:{previous_tag}`."
        )
    else:
        lines.append(
            f"Compared `{current_ref.repository}:{current_ref.tag}` with no earlier dated tag available."
        )
    lines.append("")
    return lines


def render_package_table(diff: PackageDiff) -> list[str]:
    lines = ["| Name | Previous | New |", "| --- | --- | --- |"]
    for entry in diff.added:
        lines.append(f"| + {entry.name} |  | `{entry.version}` |")
    for entry in diff.removed:
        lines.append(f"| - {entry.name} | `{entry.version}` |  |")
    for entry in diff.changed:
        lines.append(f"| {entry.name} | `{entry.previous_version}` | `{entry.current_version}` |")
    lines.append("")
    return lines


def render_diff(
    title: str,
    current_ref: ImageRef,
    previous_tag: str | None,
    diff_by_arch: dict[str, PackageDiff],
    *,
    empty_message: str = "No RPM changes detected.",
) -> list[str]:
    lines = render_section_header(title, current_ref, previous_tag)
    if previous_tag is None:
        lines.append("No previous comparable dated tag was found for this image family.")
        lines.append("")
        return lines

    if not diff_by_arch:
        lines.append(empty_message)
        lines.append("")
        return lines

    if all(diff.is_empty() for diff in diff_by_arch.values()):
        lines.append(empty_message)
        lines.append("")
        return lines

    added_common, added_by_arch = common_entries_across_arches(
        {arch: diff.added for arch, diff in diff_by_arch.items()}
    )
    removed_common, removed_by_arch = common_entries_across_arches(
        {arch: diff.removed for arch, diff in diff_by_arch.items()}
    )
    changed_common, changed_by_arch = common_entries_across_arches(
        {arch: diff.changed for arch, diff in diff_by_arch.items()}
    )

    common_diff = PackageDiff(
        added=added_common,
        removed=removed_common,
        changed=changed_common,
    )
    if not common_diff.is_empty():
        lines.extend(render_package_table(common_diff))

    for arch in ARCH_ORDER:
        if arch not in diff_by_arch:
            continue
        arch_diff = PackageDiff(
            added=added_by_arch.get(arch, []),
            removed=removed_by_arch.get(arch, []),
            changed=changed_by_arch.get(arch, []),
        )
        if arch_diff.is_empty():
            continue
        lines.append(f"Architecture-specific changes for `{arch}`:")
        lines.append("")
        lines.extend(render_package_table(arch_diff))
    return lines


def intersect_diffs(diffs: list[dict[str, PackageDiff]]) -> dict[str, PackageDiff]:
    intersection: dict[str, PackageDiff] = {}
    for arch in ARCH_ORDER:
        if not diffs or any(arch not in diff_by_arch for diff_by_arch in diffs):
            continue
        arch_diffs = [diff_by_arch[arch] for diff_by_arch in diffs]
        if not arch_diffs:
            continue
        added = intersect_entries([set(diff.added) for diff in arch_diffs])
        removed = intersect_entries([set(diff.removed) for diff in arch_diffs])
        changed = intersect_entries([set(diff.changed) for diff in arch_diffs])
        if added or removed or changed:
            intersection[arch] = PackageDiff(
                added=sorted(added, key=lambda entry: entry.render()),
                removed=sorted(removed, key=lambda entry: entry.render()),
                changed=sorted(changed, key=lambda entry: entry.render()),
            )
    return intersection


def intersect_entries(entry_sets: list[set]) -> set:
    if not entry_sets:
        return set()
    result = set(entry_sets[0])
    for entry_set in entry_sets[1:]:
        result &= entry_set
    return result


def union_diffs(diffs: list[dict[str, PackageDiff]]) -> dict[str, PackageDiff]:
    union: dict[str, PackageDiff] = {}
    for arch in ARCH_ORDER:
        added: set[AddedEntry] = set()
        removed: set[RemovedEntry] = set()
        changed: set[ChangedEntry] = set()
        for diff_by_arch in diffs:
            diff = diff_by_arch.get(arch)
            if not diff:
                continue
            added.update(diff.added)
            removed.update(diff.removed)
            changed.update(diff.changed)
        if added or removed or changed:
            union[arch] = PackageDiff(
                added=sorted(added, key=lambda entry: entry.render()),
                removed=sorted(removed, key=lambda entry: entry.render()),
                changed=sorted(changed, key=lambda entry: entry.render()),
            )
    return union


def subtract_diffs(
    diff_by_arch: dict[str, PackageDiff],
    *excluded_diff_maps: dict[str, PackageDiff],
) -> dict[str, PackageDiff]:
    result: dict[str, PackageDiff] = {}
    for arch, diff in diff_by_arch.items():
        excluded_added: set[AddedEntry] = set()
        excluded_removed: set[RemovedEntry] = set()
        excluded_changed: set[ChangedEntry] = set()
        for excluded in excluded_diff_maps:
            excluded_diff = excluded.get(arch)
            if not excluded_diff:
                continue
            excluded_added.update(excluded_diff.added)
            excluded_removed.update(excluded_diff.removed)
            excluded_changed.update(excluded_diff.changed)

        added = [entry for entry in diff.added if entry not in excluded_added]
        removed = [entry for entry in diff.removed if entry not in excluded_removed]
        changed = [entry for entry in diff.changed if entry not in excluded_changed]
        if added or removed or changed:
            result[arch] = PackageDiff(added=added, removed=removed, changed=changed)
    return result


def top_change_counts(diffs: list[dict[str, PackageDiff]]) -> list[str]:
    counter = Counter()
    for diff_by_arch in diffs:
        for diff in diff_by_arch.values():
            for entry in diff.changed:
                counter[entry.name] += 1
            for entry in diff.added:
                counter[entry.name] += 1
            for entry in diff.removed:
                counter[entry.name] += 1
    return [name for name, _count in counter.most_common(10)]


def read_notes(path: Path | None) -> str:
    if not path:
        return ""
    return path.read_text(encoding="utf-8").strip()


def read_env_file(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key] = value
    return values


def load_current_artifacts(path: Path | None) -> None:
    if not path:
        return
    if not path.exists():
        raise RuntimeError(f"current artifacts directory does not exist: {path}")

    for env_file in sorted(path.rglob("image.env")):
        sbom_file = env_file.parent / "sbom.json"
        if not sbom_file.exists():
            continue

        values = read_env_file(env_file)
        image_ref = values.get("IMAGE_REF", "")
        image_digest = values.get("IMAGE_DIGEST", "")
        arch = normalize_arch(values.get("IMAGE_ARCH", ""))
        if not image_ref or not image_digest or not arch:
            raise RuntimeError(f"{env_file}: missing IMAGE_REF, IMAGE_DIGEST, or IMAGE_ARCH")

        repository, _tag = split_image_ref(image_ref)
        ARTIFACT_SBOMS[(repository, image_digest)] = ArtifactSbom(
            image_ref=image_ref,
            image_digest=image_digest,
            arch=arch,
            path=sbom_file,
        )

    log(f"indexed {len(ARTIFACT_SBOMS)} current SBOM artifact(s)")


def split_image_ref(image_ref: str) -> tuple[str, str]:
    if "@" in image_ref:
        image_ref = image_ref.split("@", 1)[0]
    if ":" not in image_ref:
        raise RuntimeError(f"image reference does not include a tag: {image_ref}")
    repository, tag = image_ref.rsplit(":", 1)
    return repository, tag


def shell_assignment(key: str, value: str) -> str:
    return f"{key}={shlex.quote(value)}"


def render_intro(current_date: str, previous_tag: str | None, notes: str) -> list[str]:
    lines = [
        f"This is an automatically generated changelog for release `{ARGS.stream}-{current_date}`.",
        "",
    ]
    if previous_tag:
        lines.append(
            f"From previous `{ARGS.stream}` version `{previous_tag}` there have been the following changes. "
            "One package per new version shown."
        )
    else:
        lines.append(
            f"No previous `{ARGS.stream}` version was found for comparison. "
            "The package sections below may be empty until another build is available."
        )
    lines.append("")

    if notes:
        lines.append(notes)
        lines.append("")
    return lines


def render_major_packages(packages_by_variant: dict[Variant, dict[str, dict[str, PackageEntry]]]) -> list[str]:
    primary_packages = packages_by_variant[Variant("ucore", "uCore", "")]
    lines = [
        "### Major packages",
        "",
        "| Name | Version |",
        "| --- | --- |",
    ]
    for package_name, version in key_package_versions(primary_packages, KEY_PACKAGE_NAMES):
        lines.append(f"| {package_name} | `{strip_package_names(version, package_name)}` |")

    nvidia_open_driver = package_version(
        packages_by_variant[Variant("ucore", "uCore", "-nvidia")],
        "nvidia-driver-cuda",
    )
    if nvidia_open_driver:
        lines.append(f"| NVIDIA Open Driver | `{nvidia_open_driver}` |")

    nvidia_lts_driver = package_version(
        packages_by_variant[Variant("ucore", "uCore", "-nvidia-lts")],
        "nvidia-driver-cuda",
    )
    if nvidia_lts_driver:
        lines.append(f"| NVIDIA LTS Driver | `{nvidia_lts_driver}` |")

    nvidia_toolkits = nvidia_toolkit_versions(packages_by_variant)
    if nvidia_toolkits:
        lines.append(f"| NVIDIA Container Toolkit | `{', '.join(nvidia_toolkits)}` |")
    lines.append("")
    return lines


def nvidia_toolkit_versions(
    packages_by_variant: dict[Variant, dict[str, dict[str, PackageEntry]]],
) -> list[str]:
    versions = []
    for variant in (
        Variant("ucore", "uCore", "-nvidia"),
        Variant("ucore", "uCore", "-nvidia-lts"),
    ):
        toolkit_version = package_version(packages_by_variant[variant], "nvidia-container-toolkit")
        if toolkit_version and toolkit_version not in versions:
            versions.append(toolkit_version)
    return versions


def render_build_metadata(
    primary_ref: ImageRef,
    current_date: str,
    previous_tag: str | None,
    variant_diffs: dict[Variant, dict[str, PackageDiff]],
) -> list[str]:
    current_version = primary_ref.labels.get("org.opencontainers.image.version", "unknown")
    current_revision = short_revision(primary_ref.labels)
    current_revision_full = primary_ref.labels.get("org.opencontainers.image.revision")
    previous_revision = None
    previous_revision_full = None
    if previous_tag:
        previous_labels = inspect_reference(f"{primary_ref.repository}:{previous_tag}").get("Labels", {})
        previous_revision = short_revision(previous_labels)
        previous_revision_full = previous_labels.get("org.opencontainers.image.revision")

    lines = [
        "### Build metadata",
        "",
        "| Name | Value |",
        "| --- | --- |",
        f"| Stream | `{ARGS.stream}` |",
        f"| Release date | `{current_date}` |",
        f"| Current image | `{primary_ref.ref}` |",
    ]
    if primary_ref.matched_dated_tag:
        lines.append(f"| Matched dated tag | `{primary_ref.repository}:{primary_ref.matched_dated_tag}` |")
    if previous_tag:
        lines.append(f"| Previous dated tag | `{primary_ref.repository}:{previous_tag}` |")
    lines.append(f"| Fedora CoreOS version | `{current_version}` |")
    if current_revision:
        lines.append(f"| Source revision | `{current_revision}` |")
    if previous_revision and current_revision and previous_revision != current_revision:
        lines.append(
            f"| Source compare | `https://github.com/{ARGS.github_repo}/compare/{previous_revision_full}...{current_revision_full}` |"
        )
    hot_packages = top_change_counts(list(variant_diffs.values()))
    if hot_packages:
        lines.append(f"| Frequent package changes | `{', '.join(hot_packages)}` |")
    lines.append("")
    return lines


def variants_for(image_name: str | None = None, tag_suffix: str | None = None) -> list[Variant]:
    variants = VARIANTS
    if image_name is not None:
        variants = [variant for variant in variants if variant.image_name == image_name]
    if tag_suffix is not None:
        variants = [variant for variant in variants if variant.tag_suffix == tag_suffix]
    return variants


def render_tiered_diffs(
    primary_ref: ImageRef,
    refs_by_variant: dict[Variant, ImageRef],
    variant_diffs: dict[Variant, dict[str, PackageDiff]],
) -> list[str]:
    minimal_common = intersect_diffs([variant_diffs[variant] for variant in variants_for(image_name="ucore-minimal")])
    ucore_common = intersect_diffs([variant_diffs[variant] for variant in variants_for(image_name="ucore")])
    hci_common = intersect_diffs([variant_diffs[variant] for variant in variants_for(image_name="ucore-hci")])

    ucore_increment = subtract_diffs(ucore_common, minimal_common)
    hci_increment = subtract_diffs(hci_common, minimal_common, ucore_increment)
    displayed_common = union_diffs([minimal_common, ucore_increment, hci_increment])

    lines = []
    minimal_ref = refs_by_variant[Variant("ucore-minimal", "uCore Minimal", "")]
    lines.extend(render_diff("All ucore-minimal Images", minimal_ref, minimal_ref.previous_dated_tag, minimal_common))
    lines.extend(
        render_diff(
            "All ucore Images (include changes from `ucore-minimal`)",
            primary_ref,
            primary_ref.previous_dated_tag,
            ucore_increment,
            empty_message="No further RPM changes detected.",
        )
    )

    hci_ref = refs_by_variant[Variant("ucore-hci", "uCore HCI", "")]
    lines.extend(
        render_diff(
            "All ucore-hci Images (include changes from `ucore`)",
            hci_ref,
            hci_ref.previous_dated_tag,
            hci_increment,
            empty_message="No further RPM changes detected.",
        )
    )

    nvidia_specific = nvidia_specific_diffs(variant_diffs, displayed_common)
    if nvidia_specific:
        sample_ref = refs_by_variant[Variant("ucore", "uCore", "-nvidia")]
        lines.extend(
            render_diff(
                "All NVIDIA Images",
                sample_ref,
                sample_ref.previous_dated_tag,
                nvidia_specific,
                empty_message="No further RPM changes detected.",
            )
        )
    return lines


def nvidia_specific_diffs(
    variant_diffs: dict[Variant, dict[str, PackageDiff]],
    displayed_common: dict[str, PackageDiff],
) -> dict[str, PackageDiff]:
    nvidia_common = union_diffs(
        [
            intersect_diffs([variant_diffs[variant] for variant in variants_for(tag_suffix="-nvidia")]),
            intersect_diffs([variant_diffs[variant] for variant in variants_for(tag_suffix="-nvidia-lts")]),
        ]
    )
    return subtract_diffs(nvidia_common, displayed_common)


def render_rebase(current_date: str) -> list[str]:
    repository = image_repository("ucore")
    return [
        "## Rebase",
        "",
        f"- Stream tag: `sudo bootc switch --enforce-container-sigpolicy {repository}:{ARGS.stream}`",
        f"- Exact dated tag: `sudo bootc switch --enforce-container-sigpolicy {repository}:{ARGS.stream}-{current_date}`",
        "",
    ]


def render_markdown(
    primary_ref: ImageRef,
    refs_by_variant: dict[Variant, ImageRef],
    variant_diffs: dict[Variant, dict[str, PackageDiff]],
    packages_by_variant: dict[Variant, dict[str, dict[str, PackageEntry]]],
    notes: str,
) -> str:
    current_date = release_date(primary_ref)
    previous_tag = previous_release_tag(primary_ref)
    lines = render_intro(current_date, previous_tag, notes)
    lines.extend(render_major_packages(packages_by_variant))
    lines.extend(render_build_metadata(primary_ref, current_date, previous_tag, variant_diffs))
    lines.extend(render_tiered_diffs(primary_ref, refs_by_variant, variant_diffs))
    lines.extend(render_rebase(current_date))

    return "\n".join(lines).rstrip() + "\n"


def write_env(path: Path, primary_ref: ImageRef) -> None:
    current_date = release_date(primary_ref)
    current_version = primary_ref.labels.get("org.opencontainers.image.version", "unknown")
    release_tag = f"{ARGS.stream}-{current_date}"
    title = f"{release_tag}: {ARGS.stream.capitalize()} (FCOS {current_version}"
    revision = short_revision(primary_ref.labels)
    if revision:
        title = f"{title}, #{revision})"
    else:
        title = f"{title})"

    previous_tag = previous_release_tag(primary_ref) or ""
    lines = [
        shell_assignment("RELEASE_TAG", release_tag),
        shell_assignment("RELEASE_TITLE", title),
        shell_assignment("RELEASE_STREAM", ARGS.stream),
        shell_assignment("RELEASE_DATE", current_date),
        shell_assignment("PREVIOUS_RELEASE_TAG", previous_tag),
    ]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Generate uCore RPM changelogs from published images and SBOMs.")
    parser.add_argument("--stream", required=True, choices=["stable", "testing", "lts"])
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--env-output", required=True, type=Path)
    parser.add_argument("--notes-file", type=Path)
    parser.add_argument("--image-registry", default="ghcr.io/ublue-os")
    parser.add_argument("--github-repo", default="ublue-os/ucore")
    parser.add_argument("--max-dated-tags", type=int, default=20)
    parser.add_argument("--current-artifacts-dir", type=Path)
    parser.add_argument("--release-date")
    return parser.parse_args()


def main() -> int:
    global ARGS
    ARGS = parse_args()

    for command in ("python3", "skopeo", "oras"):
        ensure_command(command)

    notes = read_notes(ARGS.notes_file)
    load_current_artifacts(ARGS.current_artifacts_dir)

    packages_by_variant: dict[Variant, dict[str, dict[str, PackageEntry]]] = {}
    variant_diffs: dict[Variant, dict[str, PackageDiff]] = {}
    refs_by_variant: dict[Variant, ImageRef] = {}

    primary_variant = Variant("ucore", "uCore", "")
    primary_ref = resolve_image_ref(image_repository(primary_variant.image_name), primary_variant.moving_tag)

    for variant in VARIANTS:
        repository = image_repository(variant.image_name)
        log(f"resolving {repository}:{variant.moving_tag}")
        current_ref = resolve_image_ref(repository, variant.moving_tag)
        refs_by_variant[variant] = current_ref
        packages_by_variant[variant] = resolve_packages(current_ref, prefer_current_artifacts=True)
        previous_tag = current_ref.previous_dated_tag
        if previous_tag is None:
            log(f"no previous dated tag for {repository}:{variant.moving_tag}")
            variant_diffs[variant] = {}
            continue

        log(f"comparing {repository}:{variant.moving_tag} with {repository}:{previous_tag}")
        previous_ref = resolve_image_ref(repository, previous_tag)
        previous_packages = resolve_packages(previous_ref)
        diffs: dict[str, PackageDiff] = {}
        for arch in sorted(set(packages_by_variant[variant]) | set(previous_packages)):
            if arch not in packages_by_variant[variant] or arch not in previous_packages:
                continue
            diffs[arch] = diff_packages(previous_packages[arch], packages_by_variant[variant][arch])
        variant_diffs[variant] = diffs

    markdown = render_markdown(primary_ref, refs_by_variant, variant_diffs, packages_by_variant, notes)

    ARGS.output.parent.mkdir(parents=True, exist_ok=True)
    ARGS.output.write_text(markdown, encoding="utf-8")

    ARGS.env_output.parent.mkdir(parents=True, exist_ok=True)
    write_env(ARGS.env_output, primary_ref)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except RuntimeError as exc:
        print(f"error: {exc}", file=sys.stderr)
        sys.exit(1)
