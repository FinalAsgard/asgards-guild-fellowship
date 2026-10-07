#!/usr/bin/env bash
# Sets the game interface version(s) in the repository for one client: its
# production and development manifests and the test expectation in
# tests/spec/bootstrap_spec.lua. Releases do not use these values; they take
# the FOREVER_INTERFACE and RETAIL_INTERFACE repository variables instead.
# Use this to keep the development install and the tests current after a
# game patch.
#
# Usage: tools/set-interface.sh <forever|retail> <interface> [interface...]
#   tools/set-interface.sh retail 120200
#   tools/set-interface.sh forever 16001 16002
#
# Read a client's interface in game with: /dump (select(4, GetBuildInfo()))
#
# AGF_REPO_ROOT points the tool at another copy of the files; the tests use it
# so they never touch the real repository.
set -euo pipefail

repo_root="${AGF_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
addon="AsgardsGuildFellowship"
spec="tests/spec/bootstrap_spec.lua"

usage() {
    echo "Usage: tools/set-interface.sh <forever|retail> <interface> [interface...]" >&2
    exit 1
}

[ "$#" -ge 2 ] || usage
client="$(echo "$1" | tr '[:upper:]' '[:lower:]')"
shift

case "$client" in
    forever)
        suffix="_Camelot"
        test_name="Forever"
        variable_name="FOREVER_INTERFACE"
        ;;
    retail)
        suffix="_Mainline"
        test_name="Retail"
        variable_name="RETAIL_INTERFACE"
        ;;
    *)
        usage
        ;;
esac

# Every value is checked before anything is written.
for interface in "$@"; do
    if [[ ! "$interface" =~ ^[1-9][0-9]{4,5}$ ]]; then
        echo "Interface versions are 5 or 6 digit numbers, such as 16001 or 120100; got '$interface'. Nothing was changed." >&2
        exit 1
    fi
done

# "16001, 16002" in manifests and tests.
toc_value="$(printf '%s, ' "$@")"
toc_value="${toc_value%, }"
export toc_value test_name

manifests=("${addon}${suffix}.toc" "${addon}Dev${suffix}.toc")

for manifest in "${manifests[@]}"; do
    [ -f "$repo_root/$manifest" ] || continue
    perl -pi -e 's/^## Interface:.*$/## Interface: $ENV{toc_value}/' "$repo_root/$manifest"
done

if [ -f "$repo_root/$spec" ]; then
    perl -pi -e 's/(\{ name = "\Q$ENV{test_name}\E", label = "[^"]*", interface = ")[^"]*(")/$1$ENV{toc_value}$2/' \
        "$repo_root/$spec"
fi

# Every place must now agree; a missed file means the formats have drifted.
status=0
for manifest in "${manifests[@]}"; do
    grep -qxF "## Interface: $toc_value" "$repo_root/$manifest" 2>/dev/null || {
        echo "Not updated: $manifest" >&2
        status=1
    }
done
grep -qE "\{ name = \"$test_name\", label = \"[^\"]*\", interface = \"$toc_value\" \}" "$repo_root/$spec" 2>/dev/null || {
    echo "Not updated: $spec" >&2
    status=1
}

if [ "$status" -ne 0 ]; then
    exit "$status"
fi
echo "Set the ${test_name} manifests and tests to interface ${toc_value}. Releases use the ${variable_name} variable."
