#!/usr/bin/env bash
# Tests tools/check-package.sh against small hand-built zips: a well-formed
# package passes, and each broken rule fails on its own. Everything happens
# in a temporary folder; the repository files are only read.
# Usage: tests/tools/check-package.test.sh
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check="$repo_root/tools/check-package.sh"
addon="AsgardsGuildFellowship"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

passed=0
failed=0

# Lays out a well-formed package folder: both production manifests (copied
# from the repository), every file they load, LICENSE, and README.
well_formed() {
    local root="$1/$addon"
    mkdir -p "$root"
    local manifest
    for manifest in "${addon}_Camelot.toc" "${addon}_Mainline.toc"; do
        cp "$repo_root/$manifest" "$root/$manifest"
        local loaded
        while IFS= read -r loaded; do
            [ -z "$loaded" ] && continue
            mkdir -p "$root/$(dirname "$loaded")"
            : > "$root/$loaded"
        done < <(tr -d '\r' < "$root/$manifest" | grep -v '^##' | grep -E '\.(lua|xml)$')
    done
    : > "$root/LICENSE"
    : > "$root/README.md"
}

# Builds a zip from a package folder; `mutate` changes the folder first.
build_zip() {
    local name="$1" mutate="$2"
    local dir="$work_dir/$name"
    rm -rf "$dir"
    mkdir -p "$dir"
    well_formed "$dir"
    (cd "$dir" && eval "$mutate")
    (cd "$dir" && zip -qr "$work_dir/$name.zip" .)
    printf '%s' "$work_dir/$name.zip"
}

expect() {
    local outcome="$1" name="$2" mutate="$3" message="${4:-}"
    local zip output status
    zip="$(build_zip "$name" "$mutate")"
    set +e
    output="$("$check" "$zip" 2>&1)"
    status=$?
    set -e
    if [ "$outcome" = pass ] && [ "$status" -eq 0 ]; then
        passed=$((passed + 1)); echo "PASS $name"
    elif [ "$outcome" = fail ] && [ "$status" -ne 0 ] && printf '%s' "$output" | grep -Fq -- "$message"; then
        passed=$((passed + 1)); echo "PASS $name"
    else
        failed=$((failed + 1)); echo "FAIL $name (expected $outcome${message:+ with '$message'})"
        printf '%s\n' "$output" | sed 's/^/    /'
    fi
}

expect pass "well-formed package" ":"
expect fail "missing Forever manifest" "rm $addon/${addon}_Camelot.toc" "missing production manifest $addon/${addon}_Camelot.toc"
expect fail "missing Retail manifest" "rm $addon/${addon}_Mainline.toc" "missing production manifest $addon/${addon}_Mainline.toc"
expect fail "missing add-on module" "rm $addon/Core/ScanScheduler.lua" "loads Core/ScanScheduler.lua, which is not in the package"
expect fail "missing library load file" "rm $addon/Libs/LibDBIcon-1.0/lib.xml" "loads Libs/LibDBIcon-1.0/lib.xml, which is not in the package"
expect fail "packaged dev manifest" ": > $addon/${addon}Dev_Mainline.toc" "development-only files packaged"
expect fail "packaged tests" "mkdir -p $addon/tests && : > $addon/tests/run.lua" "development-only files packaged"
expect fail "packaged tools" "mkdir -p $addon/tools && : > $addon/tools/libraries.txt" "development-only files packaged"
expect fail "packaged docs" "mkdir -p $addon/docs && : > $addon/docs/packaging.md" "development-only files packaged"
expect fail "packaged ai folder" "mkdir -p $addon/ai && : > $addon/ai/PIPELINE.md" "development-only files packaged"
expect fail "packaged CI files" "mkdir -p $addon/.github && : > $addon/.github/x.yml" "development-only files packaged"
expect fail "packaged .pkgmeta" ": > $addon/.pkgmeta" "development-only files packaged"
expect fail "extra manifest" ": > $addon/${addon}_Vanilla.toc" "unsupported manifests packaged"
expect fail "file outside the add-on folder" ": > stray.txt" "files outside the $addon/ folder"
expect fail "missing LICENSE" "rm $addon/LICENSE" "missing LICENSE"
expect fail "missing README" "rm $addon/README.md" "missing README.md"

echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
