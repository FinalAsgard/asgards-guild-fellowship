#!/usr/bin/env bash
# Tests tools/check-release-tag.sh and tools/apply-interfaces.sh against
# temporary copies of the four manifests. The repository files are only read.
# Usage: tests/tools/release-tools.test.sh
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tag_check="$repo_root/tools/check-release-tag.sh"
apply="$repo_root/tools/apply-interfaces.sh"
addon="AsgardsGuildFellowship"
manifests=("${addon}_Camelot.toc" "${addon}_Mainline.toc" "${addon}Dev_Camelot.toc" "${addon}Dev_Mainline.toc")
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

passed=0
failed=0
copy=""
output=""
status=0

# Copies the manifests into a fresh folder; `mutate` changes the copy.
fresh_copy() {
    copy="$work_dir/$1"
    rm -rf "$copy"
    mkdir -p "$copy"
    local manifest
    for manifest in "${manifests[@]}"; do
        cp "$repo_root/$manifest" "$copy/$manifest"
    done
    (cd "$copy" && eval "${2:-:}")
}

# run <tool> [VARIABLE=value...] -- [argument...]
run() {
    local tool="$1" assignments=()
    shift
    while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
        assignments+=("$1")
        shift
    done
    [ "$#" -gt 0 ] && shift
    set +e
    output="$(env -u FOREVER_INTERFACE -u RETAIL_INTERFACE AGF_REPO_ROOT="$copy" "${assignments[@]+"${assignments[@]}"}" "$tool" "$@" 2>&1)"
    status=$?
    set -e
}

check() {
    local name="$1" condition="$2"
    if eval "$condition"; then
        passed=$((passed + 1)); echo "PASS $name"
    else
        failed=$((failed + 1)); echo "FAIL $name ($condition)"
        printf '%s\n' "$output" | sed 's/^/    /'
    fi
}

interface_of() {
    tr -d '\r' < "$copy/$1" | sed -n 's/^## Interface: //p'
}

version_of() {
    tr -d '\r' < "$copy/$1" | sed -n 's/^## Version: //p'
}

same_as_repo() {
    cmp -s "$repo_root/$1" "$copy/$1"
}

unchanged() {
    local manifest
    for manifest in "${manifests[@]}"; do
        same_as_repo "$manifest" || return 1
    done
}

# Release tag check -------------------------------------------------------

fresh_copy tags
for tag in v0.1.0 v0.1.0-beta1 v1.2.3-alpha.2 v10.20.30 v0.1.0-rc.1; do
    run "$tag_check" -- "$tag"
    check "accepts tag $tag" '[ "$status" -eq 0 ] && printf "%s" "$output" | grep -Fq "versioned $tag"'
done
for tag in 0.1.0 v0.1 v0.1.0.1 V0.1.0 v0.1.0- "v0.1.0-beta 1" v0.1.0_beta1 vx.y.z "" release; do
    run "$tag_check" -- "$tag"
    check "rejects tag '$tag'" '[ "$status" -ne 0 ] && printf "%s" "$output" | grep -Fq "Release tags look like"'
done

fresh_copy hard-coded "perl -pi -e 's/^## Version:.*/## Version: 0.1.0/' ${addon}_Mainline.toc"
run "$tag_check" -- v0.1.0
check "rejects a manifest with a hard-coded version" '[ "$status" -ne 0 ] && printf "%s" "$output" | grep -Fq "${addon}_Mainline.toc declares version '"'"'0.1.0'"'"'"'
check "names only the hard-coded manifest" '! printf "%s" "$output" | grep -Fq "${addon}_Camelot.toc"'

fresh_copy missing-manifest "rm ${addon}_Camelot.toc"
run "$tag_check" -- v0.1.0
check "rejects a missing production manifest" '[ "$status" -ne 0 ] && printf "%s" "$output" | grep -Fq "${addon}_Camelot.toc is missing"'

# Interface application ---------------------------------------------------

fresh_copy apply
run "$apply" "FOREVER_INTERFACE=16001,16002" "RETAIL_INTERFACE= 120100 , 120200 " --
check "applies valid game versions" '[ "$status" -eq 0 ]'
check "writes Forever into its production manifest" '[ "$(interface_of ${addon}_Camelot.toc)" = "16001, 16002" ]'
check "writes Retail into its production manifest" '[ "$(interface_of ${addon}_Mainline.toc)" = "120100, 120200" ]'
check "leaves the dev manifests untouched" 'same_as_repo ${addon}Dev_Camelot.toc && same_as_repo ${addon}Dev_Mainline.toc'
check "keeps the production version token" '[ "$(version_of ${addon}_Camelot.toc)" = "@project-version@" ] && [ "$(version_of ${addon}_Mainline.toc)" = "@project-version@" ]'
check "dev manifests keep version dev" '[ "$(version_of ${addon}Dev_Camelot.toc)" = dev ] && [ "$(version_of ${addon}Dev_Mainline.toc)" = dev ]'

# Each broken value fails with a clear message naming the variable, and
# nothing is written.
bad_case() {
    local name="$1" message="$2"
    shift 2
    fresh_copy "bad"
    run "$apply" "$@" --
    check "$name" '[ "$status" -ne 0 ] && printf "%s" "$output" | grep -Fq -- "$message" && unchanged'
}
bad_case "fails when FOREVER_INTERFACE is missing" "The FOREVER_INTERFACE repository variable is not set" "RETAIL_INTERFACE=120100"
bad_case "fails when RETAIL_INTERFACE is missing" "The RETAIL_INTERFACE repository variable is not set" "FOREVER_INTERFACE=16001"
bad_case "fails when FOREVER_INTERFACE is empty" "The FOREVER_INTERFACE repository variable is not set" "FOREVER_INTERFACE=" "RETAIL_INTERFACE=120100"
bad_case "fails when RETAIL_INTERFACE is only spaces and commas" "The RETAIL_INTERFACE repository variable is not set" "FOREVER_INTERFACE=16001" "RETAIL_INTERFACE= , "
bad_case "fails on a short number" "FOREVER_INTERFACE has '1600'" "FOREVER_INTERFACE=1600" "RETAIL_INTERFACE=120100"
bad_case "fails on a long number" "RETAIL_INTERFACE has '1201000'" "FOREVER_INTERFACE=16001" "RETAIL_INTERFACE=1201000"
bad_case "fails on letters" "RETAIL_INTERFACE has '12o100'" "FOREVER_INTERFACE=16001" "RETAIL_INTERFACE=12o100"
bad_case "fails on a leading zero" "FOREVER_INTERFACE has '01600'" "FOREVER_INTERFACE=01600" "RETAIL_INTERFACE=120100"
bad_case "fails on a trailing comma" "FOREVER_INTERFACE has an empty entry" "FOREVER_INTERFACE=16001," "RETAIL_INTERFACE=120100"
bad_case "fails on a doubled comma" "RETAIL_INTERFACE has an empty entry" "FOREVER_INTERFACE=16001" "RETAIL_INTERFACE=120100,,120200"
bad_case "fails on a space-separated list" "RETAIL_INTERFACE has '120100120200'" "FOREVER_INTERFACE=16001" "RETAIL_INTERFACE=120100 120200"
# A bad Retail value must not leave Forever half-applied.
bad_case "writes nothing when only the second value is bad" "RETAIL_INTERFACE has 'abc'" "FOREVER_INTERFACE=16002" "RETAIL_INTERFACE=abc"

fresh_copy apply-missing "rm ${addon}_Mainline.toc"
run "$apply" "FOREVER_INTERFACE=16001" "RETAIL_INTERFACE=120100" --
check "fails when a production manifest is missing" '[ "$status" -ne 0 ] && printf "%s" "$output" | grep -Fq "${addon}_Mainline.toc is missing"'
check "writes nothing when a production manifest is missing" 'same_as_repo ${addon}_Camelot.toc'

echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
