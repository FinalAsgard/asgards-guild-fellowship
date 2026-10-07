#!/usr/bin/env bash
# Tests tools/set-interface.sh against temporary copies of the four manifests
# and the bootstrap spec. The repository files are only read.
# Usage: tests/tools/set-interface.test.sh
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tool="$repo_root/tools/set-interface.sh"
addon="AsgardsGuildFellowship"
spec="tests/spec/bootstrap_spec.lua"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

passed=0
failed=0
copy=""
output=""
status=0

# Copies the files the tool edits into a fresh folder; `mutate` changes the
# copy before the tool runs.
fresh_copy() {
    copy="$work_dir/$1"
    rm -rf "$copy"
    mkdir -p "$copy/tests/spec"
    local manifest
    for manifest in "${addon}_Camelot.toc" "${addon}_Mainline.toc" "${addon}Dev_Camelot.toc" "${addon}Dev_Mainline.toc"; do
        cp "$repo_root/$manifest" "$copy/$manifest"
    done
    cp "$repo_root/$spec" "$copy/$spec"
    (cd "$copy" && eval "${2:-:}")
}

run_tool() {
    set +e
    output="$(AGF_REPO_ROOT="$copy" "$tool" "$@" 2>&1)"
    status=$?
    set -e
}

interface_of() {
    tr -d '\r' < "$copy/$1" | sed -n 's/^## Interface: //p'
}

spec_interface_of() {
    sed -n "s/.*{ name = \"$1\", label = \"[^\"]*\", interface = \"\([^\"]*\)\" }.*/\1/p" "$copy/$spec"
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

unchanged() {
    local manifest
    for manifest in "${addon}_Camelot.toc" "${addon}_Mainline.toc" "${addon}Dev_Camelot.toc" "${addon}Dev_Mainline.toc" "$spec"; do
        cmp -s "$repo_root/$manifest" "$copy/$manifest" || return 1
    done
}

retail_before="$(sed -n 's/^## Interface: //p' "$repo_root/${addon}_Mainline.toc" | tr -d '\r')"
forever_before="$(sed -n 's/^## Interface: //p' "$repo_root/${addon}_Camelot.toc" | tr -d '\r')"

# Forever: both _Camelot manifests and the spec; Retail is left alone.
fresh_copy forever
run_tool forever 16002
check "forever exits zero" '[ "$status" -eq 0 ]'
check "forever production manifest" '[ "$(interface_of ${addon}_Camelot.toc)" = 16002 ]'
check "forever dev manifest" '[ "$(interface_of ${addon}Dev_Camelot.toc)" = 16002 ]'
check "forever spec expectation" '[ "$(spec_interface_of Forever)" = 16002 ]'
check "forever leaves retail alone" '[ "$(interface_of ${addon}_Mainline.toc)" = "$retail_before" ] && [ "$(spec_interface_of Retail)" = "$retail_before" ]'

# Retail: both _Mainline manifests and the spec; the client name is not case sensitive.
fresh_copy retail
run_tool Retail 120200
check "retail exits zero" '[ "$status" -eq 0 ]'
check "retail production manifest" '[ "$(interface_of ${addon}_Mainline.toc)" = 120200 ]'
check "retail dev manifest" '[ "$(interface_of ${addon}Dev_Mainline.toc)" = 120200 ]'
check "retail spec expectation" '[ "$(spec_interface_of Retail)" = 120200 ]'
check "retail leaves forever alone" '[ "$(interface_of ${addon}_Camelot.toc)" = "$forever_before" ] && [ "$(spec_interface_of Forever)" = "$forever_before" ]'

# Several interfaces become one comma-separated list everywhere.
fresh_copy several
run_tool forever 16001 16002
check "several interfaces exit zero" '[ "$status" -eq 0 ]'
check "several interfaces in the production manifest" '[ "$(interface_of ${addon}_Camelot.toc)" = "16001, 16002" ]'
check "several interfaces in the dev manifest" '[ "$(interface_of ${addon}Dev_Camelot.toc)" = "16001, 16002" ]'
check "several interfaces in the spec" '[ "$(spec_interface_of Forever)" = "16001, 16002" ]'

# Malformed numbers are rejected before anything is written.
for bad in 1600 1234567 01600 16a01 "16001,16002" ""; do
    fresh_copy "malformed"
    run_tool retail 120100 "$bad"
    check "rejects '$bad'" '[ "$status" -ne 0 ] && printf "%s" "$output" | grep -Fq "5 or 6 digit numbers" && unchanged'
done

fresh_copy unknown-client
run_tool classic 11507
check "rejects an unknown client" '[ "$status" -ne 0 ] && printf "%s" "$output" | grep -Fq "Usage:" && unchanged'

fresh_copy no-interface
run_tool retail
check "rejects a missing interface" '[ "$status" -ne 0 ] && printf "%s" "$output" | grep -Fq "Usage:" && unchanged'

# Drift: a file whose format no longer matches is named, and the exit is non-zero.
fresh_copy drifted-spec "perl -pi -e 's/name = \"Retail\", label/name = \"Retail\", title/' $spec"
run_tool retail 120200
check "names a drifted spec" '[ "$status" -ne 0 ] && printf "%s" "$output" | grep -Fq "Not updated: $spec"'
check "still updates the manifests beside a drifted spec" '[ "$(interface_of ${addon}_Mainline.toc)" = 120200 ]'

fresh_copy drifted-manifest "perl -pi -e 's/^## Interface:/## Interfaces:/' ${addon}Dev_Mainline.toc"
run_tool retail 120200
check "names a drifted manifest" '[ "$status" -ne 0 ] && printf "%s" "$output" | grep -Fq "Not updated: ${addon}Dev_Mainline.toc"'
check "does not name the files it updated" '! printf "%s" "$output" | grep -Fq "Not updated: ${addon}_Mainline.toc"'

fresh_copy missing-manifest "rm ${addon}_Camelot.toc"
run_tool forever 16002
check "names a missing manifest" '[ "$status" -ne 0 ] && printf "%s" "$output" | grep -Fq "Not updated: ${addon}_Camelot.toc"'

# Setting the current values changes nothing.
fresh_copy current
run_tool retail $(printf '%s' "$retail_before" | tr -d ',')
check "current retail value is a no-op" '[ "$status" -eq 0 ] && unchanged'
run_tool forever $(printf '%s' "$forever_before" | tr -d ',')
check "current forever value is a no-op" '[ "$status" -eq 0 ] && unchanged'

echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
