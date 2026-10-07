#!/usr/bin/env bash
# Validates a built release zip: both production manifests and every file
# they load (the library files included) must be present, and nothing
# development-only may ship.
# Usage: tools/check-package.sh <package.zip>
set -euo pipefail

zip_path="${1:?usage: tools/check-package.sh <package.zip>}"
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
)

entries="$(unzip -Z1 "$zip_path")"
failures=0

fail() {
    echo "FAIL $1"
    failures=$((failures + 1))
}

has_entry() {
    printf '%s\n' "$entries" | grep -Fxq -- "$1"
}

for manifest in "${production_manifests[@]}"; do
    path="${addon}/${manifest}"
    if ! has_entry "$path"; then
        fail "missing production manifest $path"
        continue
    fi

    contents="$(unzip -p "$zip_path" "$path" | tr -d '\r')"
    # Every line that names a file is loaded by the client: the add-on's own
    # modules and the library files under Libs/.
    while IFS= read -r loaded; do
        [ -z "$loaded" ] && continue
        has_entry "${addon}/${loaded//\\//}" || fail "$manifest loads ${loaded}, which is not in the package"
    done < <(printf '%s\n' "$contents" | grep -v '^##' | grep -E '\.(lua|xml)$' || true)
done

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
echo "Package $zip_path passed: both production manifests, every loaded file, no development files."
