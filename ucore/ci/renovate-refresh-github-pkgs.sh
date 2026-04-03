#!/usr/bin/env bash
#
# Post-upgrade task for Renovate: after a version or commit bump in a
# github-pkgs manifest, resolve the actual download URL for each entry
# and recompute the sha256 checksum.
#
# For release-asset entries (RPMs), this queries the GitHub Releases API
# and matches the correct asset by arch and Fedora release — the same
# approach used by the original github-release-install.sh.
#
# Usage:
#   renovate-refresh-github-pkgs.sh [MANIFEST ...]
#
# If no manifests are given, all ucore/github-pkgs-*.json files are processed.

set -euo pipefail

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
UCORE_DIR=$(dirname "${SCRIPT_DIR}")

if [[ $# -gt 0 ]]; then
	MANIFESTS=("$@")
else
	MANIFESTS=("${UCORE_DIR}"/github-pkgs-*.json)
fi

fail() {
	echo "ERROR: $*" >&2
	exit 1
}

# --- Auth token -----------------------------------------------------------
# Check common locations for a GitHub token (API calls + downloads).
GITHUB_AUTH_TOKEN=""
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
	GITHUB_AUTH_TOKEN="${GITHUB_TOKEN}"
elif [[ -n "${GITHUB_COM_TOKEN:-}" ]]; then
	GITHUB_AUTH_TOKEN="${GITHUB_COM_TOKEN}"
elif [[ -r /run/secrets/GITHUB_TOKEN ]]; then
	GITHUB_AUTH_TOKEN=$(</run/secrets/GITHUB_TOKEN)
fi

curl_auth_args=()
if [[ -n "${GITHUB_AUTH_TOKEN}" ]]; then
	curl_auth_args=(-H "Authorization: Bearer ${GITHUB_AUTH_TOKEN}")
fi

# --- URL resolution --------------------------------------------------------

# Resolve a release-asset URL by querying the GitHub Releases API, then
# filtering assets by arch and release — same logic as the original
# github-release-install.sh.
resolve_release_asset_url() {
	local repo=${1}
	local version=${2}
	local arch=${3}
	local release=${4}
	local api_json asset_filter url

	api_json=$(mktemp /tmp/release-api-XXXXXXXX.json)

	curl --fail --retry 5 --retry-delay 5 --retry-all-errors -sSL \
		"${curl_auth_args[@]}" \
		-o "${api_json}" \
		"https://api.github.com/repos/${repo}/releases/tags/${version}"

	# Build the same style of arch filter the old script used:
	#   mergerfs with release=43, arch=x86_64 → "fc43.x86_64"
	#   updex with release="", arch=x86_64    → "x86_64"
	if [[ -n "${release}" ]]; then
		asset_filter="fc${release}\\.${arch}"
	else
		asset_filter="${arch}"
	fi

	url=$(jq -r \
		--arg filter "${asset_filter}" \
		'
		.assets
		| sort_by(.created_at)
		| reverse
		| .[]
		| select(.name | test($filter))
		| select(.name | test("rpm$"))
		| .browser_download_url
		' "${api_json}" | head -1)

	if [[ -z "${url}" ]]; then
		echo "available assets:" >&2
		jq -r '.assets[].name' "${api_json}" >&2
		rm -f "${api_json}"
		fail "no matching asset for ${repo}@${version} (filter: ${asset_filter}, extension: rpm)"
	fi

	rm -f "${api_json}"
	printf '%s\n' "${url}"
}

# Resolve a codeload tarball URL — deterministic, no API call needed.
resolve_codeload_url() {
	local repo=${1}
	local version=${2}

	printf 'https://codeload.github.com/%s/tar.gz/refs/tags/%s\n' "${repo}" "${version}"
}

# Resolve a raw.githubusercontent.com URL by replacing the commit hash.
resolve_raw_commit_url() {
	local old_url=${1}
	local repo=${2}
	local new_commit=${3}

	if [[ ! "${old_url}" =~ ^https://raw\.githubusercontent\.com/${repo}/([0-9a-f]+)/ ]]; then
		fail "unsupported raw-file URL format: ${old_url}"
	fi

	local old_commit=${BASH_REMATCH[1]}
	printf '%s\n' "${old_url/${old_commit}/${new_commit}}"
}

# Dispatch to the correct resolver based on the URL shape and entry fields.
resolve_url() {
	local entry=${1}
	local arch=${2}
	local url repo version release commit

	url=$(jq -r '.url' <<<"${entry}")
	repo=$(jq -r '.repo' <<<"${entry}")
	version=$(jq -r '.version // empty' <<<"${entry}")
	release=$(jq -r '.release // empty' <<<"${entry}")
	commit=$(jq -r '.commit // empty' <<<"${entry}")

	# Commit-pinned entry (raw file URL)
	if [[ -n "${commit}" ]]; then
		resolve_raw_commit_url "${url}" "${repo}" "${commit}"
		return
	fi

	if [[ -z "${version}" ]]; then
		fail "entry must have version or commit: ${entry}"
	fi

	# Codeload tarball
	if [[ "${url}" == *"codeload.github.com"* ]]; then
		resolve_codeload_url "${repo}" "${version}"
		return
	fi

	# Release asset (RPM)
	if [[ "${url}" == */releases/download/* ]]; then
		resolve_release_asset_url "${repo}" "${version}" "${arch}" "${release}"
		return
	fi

	fail "unsupported URL format: ${url}"
}

# --- Main loop -------------------------------------------------------------

download_file=''
manifest_tmp=''
trap 'rm -f "${download_file:-}" "${manifest_tmp:-}"' EXIT

for manifest in "${MANIFESTS[@]}"; do
	# Derive arch from manifest filename: github-pkgs-x86_64.json → x86_64
	arch=$(basename "${manifest}" .json)
	arch=${arch#github-pkgs-}

	manifest_tmp=$(mktemp)
	cp "${manifest}" "${manifest_tmp}"

	mapfile -t entries < <(jq -c 'to_entries[]' "${manifest}")

	for wrapped_entry in "${entries[@]}"; do
		index=$(jq -r '.key' <<<"${wrapped_entry}")
		entry=$(jq -c '.value' <<<"${wrapped_entry}")
		name=$(jq -r '.name // "unknown"' <<<"${entry}")

		url=$(resolve_url "${entry}" "${arch}")

		download_file=$(mktemp)
		curl --fail --retry 5 --retry-delay 5 --retry-all-errors -sSL \
			"${curl_auth_args[@]}" \
			-o "${download_file}" \
			"${url}"

		sha256=$(sha256sum "${download_file}" | awk '{print $1}')

		echo "  ${name}: ${url} (sha256: ${sha256})" >&2

		jq \
			--argjson index "${index}" \
			--arg url "${url}" \
			--arg sha256 "${sha256}" \
			'.[$index].url = $url | .[$index].sha256 = $sha256' \
			"${manifest_tmp}" >"${manifest_tmp}.next"
		mv "${manifest_tmp}.next" "${manifest_tmp}"
		rm -f "${download_file}"
		download_file=''
	done

	mv "${manifest_tmp}" "${manifest}"
	manifest_tmp=''
done
