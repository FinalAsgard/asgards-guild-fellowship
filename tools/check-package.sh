#!/usr/bin/env bash
# Validates a built release zip: both production manifests and every file
# they load (the library files included) must be present, every pinned
# library must have been fetched at its pin, and nothing development-only may
# ship.
# Usage: tools/check-package.sh <package.zip> <packager.log>
#   packager.log is the packager's output for this build; it records the tag
#   and source each library was fetched from.
# With EXPECTED_VERSION set (the release tag), the packaged manifests must
# declare exactly that version. With FOREVER_INTERFACE and RETAIL_INTERFACE
# set (the release's game versions), each manifest must declare exactly those.
set -euo pipefail

zip_path="${1:?usage: tools/check-package.sh <package.zip> <packager.log>}"
log_path="${2:?usage: tools/check-package.sh <package.zip> <packager.log>}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
library_list="$repo_root/tools/libraries.txt"
addon="AsgardsGuildFellowship"
production_manifests=("${addon}_Camelot.toc" "${addon}_Mainline.toc")
forbidden_patterns=(
    "^${addon}/${addon}Dev_"
    "^${addon}/tests/"
    "^${addon}/tools/"
    "^${addon}/docs/"
    "^${addon}/ai/"
    "^${addon}/\.github/"
    "^${addon}/\.pkgmeta$"
    # Pin markers and staging folders left by tools/Fetch-Libraries.ps1.
    "/\.pin$"
    "/\.staging-"
)

entries="$(unzip -Z1 "$zip_path")"
# The packager prefixes grouped lines with "##[group]" on GitHub Actions.
fetched="$(tr -d '\r' < "$log_path" | sed 's/^##\[group\]//')"
failures=0

fail() {
    echo "FAIL $1"
    failures=$((failures + 1))
}

has_entry() {
    grep -Fxq -- "$1" <<< "$entries"
}

manifest_versions=()
for manifest in "${production_manifests[@]}"; do
    path="${addon}/${manifest}"
    if ! has_entry "$path"; then
        fail "missing production manifest $path"
        continue
    fi

    contents="$(unzip -p "$zip_path" "$path" | tr -d '\r')"
    manifest_versions+=("$(printf '%s\n' "$contents" | sed -n 's/^## Version:[[:space:]]*//p')")

    expected_interface=""
    case "$manifest" in
        *_Camelot.toc) expected_interface="${FOREVER_INTERFACE:-}" ;;
        *_Mainline.toc) expected_interface="${RETAIL_INTERFACE:-}" ;;
    esac
    if [ -n "$expected_interface" ]; then
        packaged_interface="$(printf '%s\n' "$contents" | sed -n 's/^## Interface:[[:space:]]*//p' | tr -d '[:space:]')"
        if [ "$packaged_interface" != "$(printf '%s' "$expected_interface" | tr -d '[:space:]')" ]; then
            fail "$manifest declares interface $packaged_interface, not the release's $expected_interface"
        fi
    fi

    # Every line that names a file is loaded by the client: the add-on's own
    # modules and the library files under Libs/.
    while IFS= read -r loaded; do
        [ -z "$loaded" ] && continue
        has_entry "${addon}/${loaded//\\//}" || fail "$manifest loads ${loaded}, which is not in the package"
    done < <(printf '%s\n' "$contents" | grep -v '^##' | grep -E '\.(lua|xml)$' || true)
done

if [ "${#manifest_versions[@]}" -eq 2 ] && [ "${manifest_versions[0]}" != "${manifest_versions[1]}" ]; then
    fail "production manifests disagree on version: ${manifest_versions[0]} vs ${manifest_versions[1]}"
fi
for version in "${manifest_versions[@]}"; do
    case "$version" in
        *@*@*) fail "packaged manifest still has an unreplaced placeholder: $version" ;;
    esac
    if [ -n "${EXPECTED_VERSION:-}" ] && [ "$version" != "$EXPECTED_VERSION" ]; then
        fail "packaged manifest declares version $version, not the release tag $EXPECTED_VERSION"
    fi
done

# Each pinned library must be in the package at its target, with its load
# file, and the packager must have fetched exactly its pinned tag from its
# pinned source. For svn libraries the source is the pinned tag folder.
libraries=0
while IFS='|' read -r name _major target load _type url tag; do
    name="$(printf '%s' "$name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    case "$name" in "" | "#"*) continue ;; esac
    target="$(printf '%s' "$target" | tr -d '[:space:]')"
    load="$(printf '%s' "$load" | tr -d '[:space:]')"
    url="$(printf '%s' "$url" | tr -d '[:space:]')"
    tag="$(printf '%s' "$tag" | tr -d '[:space:]')"
    libraries=$((libraries + 1))

    if ! grep -Fq -- "${addon}/${target}/" <<< "$entries"; then
        fail "library $name is missing: no ${target}/ folder in the package"
        continue
    fi
    has_entry "${addon}/${target}/${load}" || fail "library $name is missing its load file ${target}/${load}"
    grep -Fxq -- "Fetching tag \"${tag}\" from external ${url}" <<< "$fetched" ||
        fail "library $name was not fetched at its pin ${tag} from ${url}"
done < "$library_list"
[ "$libraries" -gt 0 ] || fail "no libraries read from $library_list"

for pattern in "${forbidden_patterns[@]}"; do
    matches="$(printf '%s\n' "$entries" | grep -E -- "$pattern" || true)"
    [ -n "$matches" ] && fail "development-only files packaged: $(printf '%s' "$matches" | tr '\n' ' ')"
done

# Only the supported production manifests may ship; any other manifest would
# claim a client this release was not verified on.
extra_manifests="$(printf '%s\n' "$entries" | grep -E "^${addon}/[^/]+\.toc$" |
    grep -vFx -e "${addon}/${production_manifests[0]}" -e "${addon}/${production_manifests[1]}" || true)"
[ -n "$extra_manifests" ] && fail "unsupported manifests packaged: $(printf '%s' "$extra_manifests" | tr '\n' ' ')"

outside="$(printf '%s\n' "$entries" | grep -v "^${addon}/" || true)"
[ -n "$outside" ] && fail "files outside the ${addon}/ folder: $(printf '%s' "$outside" | tr '\n' ' ')"

for shipped in LICENSE README.md; do
    has_entry "${addon}/${shipped}" || fail "missing ${shipped}"
done

if [ "$failures" -gt 0 ]; then
    echo "$failures package check(s) failed for $zip_path"
    exit 1
fi
echo "Package $zip_path passed: both production manifests, every loaded file, all $libraries libraries at their pins, no development files."
