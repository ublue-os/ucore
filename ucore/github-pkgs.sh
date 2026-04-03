#!/bin/bash

set ${SET_X:+-x} -euo pipefail

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
MODE=${1:-}
TEMP_FILE=''

usage() {
	echo "Usage:"
	echo "  $0 download NAME [--manifest PATH] [--release RELEASE] [--arch ARCH]    # download and verify manifest checksum"
	echo "  $0 verify-checksum NAME [--manifest PATH] [--release RELEASE] [--arch ARCH] # verify URL and manifest checksum matches download"
	echo "  $0 entry NAME [--manifest PATH] [--release RELEASE] [--arch ARCH]       # print selected manifest row"
	echo "  $0 list [--manifest PATH] [--arch ARCH]                                 # print effective manifest entries"
	echo "  $0 resolve NAME [--manifest PATH] [--release RELEASE] [--arch ARCH]     # print resolved URL"
}

fail() {
	echo "$*" >&2
	exit 1
}

cleanup() {
	if [[ -n "${TEMP_FILE:-}" && -f "${TEMP_FILE}" ]]; then
		rm -f "${TEMP_FILE}"
	fi
}

if [[ -z "${MODE}" ]]; then
	usage
	exit 1
fi

create_temp_file() {
	local suffix=${1:-}

	if [[ -n "${suffix}" ]]; then
		TEMP_FILE=$(mktemp "/tmp/github-download-XXXXXXXX${suffix}")
	else
		TEMP_FILE=$(mktemp /tmp/github-download-XXXXXXXX)
	fi
}

get_curl_auth_args() {
	if [[ -r /run/secrets/GITHUB_TOKEN ]]; then
		local github_token
		github_token=$(</run/secrets/GITHUB_TOKEN)
		printf '%s\n%s\n' "-H" "Authorization: Bearer ${github_token}"
	fi
}

download_file() {
	local url=${1}
	local suffix=${2:-}
	local curl_auth_args=()

	create_temp_file "${suffix}"

	while IFS= read -r line; do
		curl_auth_args+=("${line}")
	done < <(get_curl_auth_args)

	curl --fail --retry 5 --retry-delay 5 --retry-all-errors -sSL \
		"${curl_auth_args[@]}" \
		-o "${TEMP_FILE}" \
		"${url}"
}

verify_sha256() {
	local expected=${1}
	local actual

	actual=$(sha256sum "${TEMP_FILE}" | awk '{print $1}')
	if [[ "${actual}" != "${expected}" ]]; then
		fail "sha256 mismatch for downloaded file: expected ${expected}, got ${actual}"
	fi
}

calculate_sha256() {
	sha256sum "${TEMP_FILE}" | awk '{print $1}'
}

get_url_suffix() {
	local url=${1}
	local filename

	case "${url}" in
	*/tar.gz/*)
		printf '%s\n' '.tar.gz'
		return
		;;
	*/zip/*)
		printf '%s\n' '.zip'
		return
		;;
	esac

	filename=${url##*/}
	filename=${filename%%\?*}

	case "${filename}" in
	*.tar.gz)
		printf '%s\n' '.tar.gz'
		;;
	*.*)
		printf '.%s\n' "${filename##*.}"
		;;
	*)
		printf '\n'
		;;
	esac
}

parse_common_args() {
	MANIFEST=''
	RELEASE=''
	ARCH=''
	RELEASE_SET=0
	ARCH_SET=0

	while [[ $# -gt 0 ]]; do
		case "${1}" in
		--manifest)
			MANIFEST=${2}
			shift 2
			;;
		--release)
			RELEASE=${2}
			RELEASE_SET=1
			shift 2
			;;
		--arch)
			ARCH=${2}
			ARCH_SET=1
			shift 2
			;;
		*)
			fail "unknown option: ${1}"
			;;
		esac
	done

	if [[ ${RELEASE_SET} -eq 0 ]]; then
		RELEASE=$(rpm -E %fedora)
	fi

	if [[ ${ARCH_SET} -eq 0 ]]; then
		ARCH=$(rpm -E %_arch)
	fi
}

manifest_paths_for_arch() {
	local arch=${1}

	case "${arch}" in
	x86_64 | aarch64)
		printf '%s/github-pkgs-%s.json\n' "${SCRIPT_DIR}" "${arch}"
		printf '%s/github-pkgs-noarch.json\n' "${SCRIPT_DIR}"
		;;
	*)
		fail "unsupported architecture for manifest selection: ${arch}"
		;;
	esac
}

load_manifest_json() {
	local manifest_json
	local manifest_paths=()

	if [[ -n "${MANIFEST}" ]]; then
		jq -c '.' "${MANIFEST}"
		return
	fi

	while IFS= read -r manifest_path; do
		manifest_paths+=("${manifest_path}")
	done < <(manifest_paths_for_arch "${ARCH}")

	manifest_json=$(jq -cs 'add' "${manifest_paths[@]}")
	printf '%s\n' "${manifest_json}"
}

select_manifest_entry() {
	local manifest_json=${1}
	local name=${2}
	local release=${3}

	jq -cer \
		--arg name "${name}" \
		--arg release "${release}" \
		'
		def release_rank($release):
		  if (.release // "") == $release then 0
		  elif (.release // "") == "" then 1
		  else 100 end;
		[
		  .[]
		  | select(.name == $name)
		  | . as $entry
		  | ($entry | release_rank($release)) as $release_rank
		  | select($release_rank < 100)
		  | {entry: $entry, release_rank: $release_rank}
		]
		| if length == 0 then
		    error("no matching manifest entry")
		  else
		    sort_by(.release_rank)
		    | . as $matches
		    | $matches[0] as $best
		    | [ $matches[] | select(.release_rank == $best.release_rank) ] as $best_matches
		    | if ($best_matches | length) != 1 then
		        error("ambiguous manifest entry")
		      else
		        $best_matches[0].entry
		      end
		  end
		' <<<"${manifest_json}"
}

resolve_named_entry() {
	local name=${1}
	shift
	local manifest_json
	local entry

	parse_common_args "$@"
	manifest_json=$(load_manifest_json)
	entry=$(select_manifest_entry "${manifest_json}" "${name}" "${RELEASE}")
	jq -r '.url' <<<"${entry}"
}

download_named_entry() {
	local name=${1}
	shift
	verify_download_checksum_for_entry "${name}" "$@" >/dev/null
	printf '%s\n' "${TEMP_FILE}"
}

verify_download_checksum_for_entry() {
	local name=${1}
	shift
	local manifest_json
	local entry
	local url
	local expected_sha256
	local actual_sha256
	local suffix

	parse_common_args "$@"
	manifest_json=$(load_manifest_json)
	entry=$(select_manifest_entry "${manifest_json}" "${name}" "${RELEASE}")
	url=$(jq -r '.url' <<<"${entry}")
	expected_sha256=$(jq -r '.sha256' <<<"${entry}")
	suffix=$(get_url_suffix "${url}")

	trap cleanup EXIT
	download_file "${url}" "${suffix}"
	actual_sha256=$(calculate_sha256)
	if [[ "${actual_sha256}" != "${expected_sha256}" ]]; then
		fail "sha256 mismatch for ${name}: expected ${expected_sha256}, got ${actual_sha256}"
	fi
	trap - EXIT
	printf '{"sha256":"%s","url":"%s"}\n' "$actual_sha256" "$url"
}

verify_checksum_named_entry() {
	local name=${1}
	shift
	local manifest_json
	local entry
	local sha256

	parse_common_args "$@"
	manifest_json=$(load_manifest_json)
	entry=$(select_manifest_entry "${manifest_json}" "${name}" "${RELEASE}")
  result=$(verify_download_checksum_for_entry "${name}" "$@")
  sha256=$(jq -r '.sha256' <<<"$result")
  url=$(jq -r '.url' <<<"$result")

	if jq -e 'has("commit")' >/dev/null <<<"${entry}"; then
		printf 'OK: %s commit=%s sha256=%s url=%s\n' \
			"${name}" \
			"$(jq -r '.commit' <<<"${entry}")" \
			"${sha256}" \
			"${url}"
	else
		printf 'OK: %s version=%s release=%s sha256=%s url=%s\n' \
			"${name}" \
			"$(jq -r '.version' <<<"${entry}")" \
			"$(jq -r '.release // empty' <<<"${entry}")" \
			"${sha256}" \
			"${url}"
	fi
}

list_entries() {
	parse_common_args "$@"
	load_manifest_json | jq -c '.[]'
}

case "${MODE}" in
download)
	NAME=${2:-}
	if [[ -z "${NAME}" ]]; then
		usage
		exit 2
	fi
	shift 2
	download_named_entry "${NAME}" "$@"
	;;
verify-checksum)
	NAME=${2:-}
	if [[ -z "${NAME}" ]]; then
		usage
		exit 2
	fi
	shift 2
	verify_checksum_named_entry "${NAME}" "$@"
	;;
list)
	shift 1
	list_entries "$@"
	;;
entry)
	NAME=${2:-}
	if [[ -z "${NAME}" ]]; then
		usage
		exit 2
	fi
	shift 2
	parse_common_args "$@"
	select_manifest_entry "$(load_manifest_json)" "${NAME}" "${RELEASE}"
	;;
resolve)
	NAME=${2:-}
	if [[ -z "${NAME}" ]]; then
		usage
		exit 2
	fi
	shift 2
	resolve_named_entry "${NAME}" "$@"
	;;
*)
	usage
	exit 1
	;;
esac
