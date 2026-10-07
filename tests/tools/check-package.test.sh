#!/usr/bin/env bash
# Tests tools/check-package.sh against small hand-built zips and packager
# logs: a well-formed package passes, and each broken rule fails on its own.
# Everything happens in a temporary folder; the repository files are only read.
# Usage: tests/tools/check-package.test.sh
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check="$repo_root/tools/check-package.sh"
addon="AsgardsGuildFellowship"
version="v0.1.0"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

passed=0
failed=0

# Prints each library row of tools/libraries.txt as "target|load|url|tag".
library_rows() {
    sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' -e 's/[[:space:]]*|[[:space:]]*/|/g' "$repo_root/tools/libraries.txt" |
        awk -F'|' '{ print $3 "|" $4 "|" $6 "|" $7 }'
}

# Lays out a well-formed package folder: both production manifests (copied
# from the repository, with the version the packager would stamp), every file
# they load, LICENSE, and README.
well_formed() {
    local root="$1/$addon"
    mkdir -p "$root"
    local manifest
    for manifest in "${addon}_Camelot.toc" "${addon}_Mainline.toc"; do
        sed "s/@project-version@/$version/" "$repo_root/$manifest" > "$root/$manifest"
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

# Writes the log a packager run would leave: one fetch line per library, the
# way the pinned packager prints them on GitHub Actions.
well_formed_log() {
    local target load url tag
    {
        echo "Build type: multi-version"
        while IFS='|' read -r target load url tag; do
            echo "Fetching external: $target"
            echo "##[group]Fetching tag \"$tag\" from external $url"
            echo "Checked out $tag"
            echo "##[endgroup]"
        done < <(library_rows)
    } > "$1"
}

# Builds a zip and log; `mutate` runs in the package folder first and can
# change the log through $log.
build_case() {
    local name="$1" mutate="$2"
    local dir="$work_dir/$name"
    rm -rf "$dir" "$work_dir/$name.zip"
    mkdir -p "$dir"
    well_formed "$dir"
    log="$work_dir/$name.log"
    well_formed_log "$log"
    (cd "$dir" && log="$log" eval "$mutate")
    (cd "$dir" && zip -qr "$work_dir/$name.zip" .)
}

# expect <pass|fail> <name> <mutate> [message] [VARIABLE=value...]
expect() {
    local outcome="$1" name="$2" mutate="$3" message="${4:-}"
    shift 4 2>/dev/null || shift $#
    local output status
    build_case "$name" "$mutate"
    set +e
    output="$(env "$@" "$check" "$work_dir/$name.zip" "$work_dir/$name.log" 2>&1)"
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

forever="$(sed -n 's/^## Interface:[[:space:]]*//p' "$repo_root/${addon}_Camelot.toc" | tr -d '\r')"
retail="$(sed -n 's/^## Interface:[[:space:]]*//p' "$repo_root/${addon}_Mainline.toc" | tr -d '\r')"
set_version() {
    # sed, not perl: perl would expand @project in the replacement.
    printf "sed -i.bak 's/^## Version:.*/## Version: %s/' %s/%s && rm %s/%s.bak" "$1" "$addon" "$2" "$addon" "$2"
}

# Contents
expect pass "well-formed package" ":" ""
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
expect fail "packaged library pin marker" ": > $addon/Libs/LibStub/.pin" "development-only files packaged: $addon/Libs/LibStub/.pin"
expect fail "packaged fetch staging folder" "mkdir -p $addon/Libs/.staging-LibStub && : > $addon/Libs/.staging-LibStub/LibStub.lua" "development-only files packaged"
expect fail "extra manifest" ": > $addon/${addon}_Vanilla.toc" "unsupported manifests packaged"
expect fail "file outside the add-on folder" ": > stray.txt" "files outside the $addon/ folder"
expect fail "missing LICENSE" "rm $addon/LICENSE" "missing LICENSE"
expect fail "missing README" "rm $addon/README.md" "missing README.md"

# Versions
expect fail "manifests disagree on version" "$(set_version v0.1.1 ${addon}_Mainline.toc)" "production manifests disagree on version: $version vs v0.1.1"
expect fail "unreplaced version token" "$(set_version @project-version@ ${addon}_Camelot.toc); $(set_version @project-version@ ${addon}_Mainline.toc)" "unreplaced placeholder: @project-version@"
expect pass "release version matches" ":" "" "EXPECTED_VERSION=$version"
expect fail "release version differs" ":" "declares version $version, not the release tag v0.2.0" "EXPECTED_VERSION=v0.2.0"

# Game versions
expect pass "release game versions match, ignoring whitespace" ":" "" "FOREVER_INTERFACE=$(printf '%s' "$forever" | tr -d ' ')" "RETAIL_INTERFACE= $retail "
expect fail "Forever game versions differ" ":" "${addon}_Camelot.toc declares interface" "FOREVER_INTERFACE=16009" "RETAIL_INTERFACE=$retail"
expect fail "Retail game versions differ" ":" "${addon}_Mainline.toc declares interface" "FOREVER_INTERFACE=$forever" "RETAIL_INTERFACE=$retail, 120200"

# Library pins
expect fail "library target folder missing" "rm -r $addon/Libs/LibSharedMedia-3.0" "library LibSharedMedia-3.0 is missing: no Libs/LibSharedMedia-3.0/ folder"
expect fail "library load file missing beside other files" "rm $addon/Libs/DetailsFramework/load.xml && : > $addon/Libs/DetailsFramework/fw.lua" "library Details! Framework is missing its load file Libs/DetailsFramework/load.xml"
expect fail "git library fetched at another tag" "perl -pi -e 's/\"v1\\.1\\.4\"/\"v1.1.3\"/' \"\$log\"" "library LibDataBroker-1.1 was not fetched at its pin v1.1.4"
expect fail "git library fetched from another source" "perl -pi -e 's{Tercioo/Details-Framework}{someone/Details-Framework}' \"\$log\"" "library Details! Framework was not fetched at its pin"
expect fail "svn library fetched at another tag" "perl -pi -e 's{\"1\\.0\\.3\" from external (.*)/1\\.0\\.3}{\"1.0.2\" from external \$1/1.0.2}' \"\$log\"" "library LibStub was not fetched at its pin 1.0.3"
expect fail "library never fetched" "perl -ni -e 'print unless /callbackhandler/' \"\$log\"" "library CallbackHandler-1.0 was not fetched at its pin"
expect pass "packager log without CI group markers" "perl -pi -e 's/^##\\[(end)?group\\]//' \"\$log\"" ""

echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
