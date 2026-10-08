#!/usr/bin/env bash
# Writes the game versions a release supports into the production manifests
# just before packaging. The versions come from the FOREVER_INTERFACE and
# RETAIL_INTERFACE repository variables, each a comma-separated list such as
# "120100, 120200" (keep the previous version while a patch rolls out).
# The Release workflow runs this; the committed manifests are only used by the
# development install and CI. The development manifests are never touched.
#
# AGF_REPO_ROOT points the tool at another copy of the manifests; the tests
# use it so they never touch the real repository.
set -euo pipefail

repo_root="${AGF_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# Prints the list as "a, b" or fails when it is missing or malformed.
normalize() {
    local name="$1" value="$2" item result=()
    if [ -z "$(printf '%s' "$value" | tr -d '[:space:],')" ]; then
        echo "The $name repository variable is not set." >&2
        return 1
    fi
    # read drops a trailing empty entry, so catch a trailing comma here.
    case "$(printf '%s' "$value" | tr -d '[:space:]')" in
        *,)
            echo "$name has an empty entry in '$value'; list versions like 120100, 120200." >&2
            return 1
            ;;
    esac
    IFS=',' read -r -a items <<< "$value"
    for item in "${items[@]}"; do
        item="$(printf '%s' "$item" | tr -d '[:space:]')"
        # An empty entry (",," or a leading comma) is rejected rather than
        # dropped, so the package check compares against the same list.
        if [ -z "$item" ]; then
            echo "$name has an empty entry in '$value'; list versions like 120100, 120200." >&2
            return 1
        fi
        if [[ ! "$item" =~ ^[1-9][0-9]{4,5}$ ]]; then
            echo "$name has '$item'; interface versions are 5 or 6 digit numbers such as 16001 or 120100." >&2
            return 1
        fi
        result+=("$item")
    done
    local joined
    joined="$(printf '%s, ' "${result[@]}")"
    printf '%s' "${joined%, }"
}

# Both values are checked before either manifest is written.
forever="$(normalize FOREVER_INTERFACE "${FOREVER_INTERFACE:-}")"
retail="$(normalize RETAIL_INTERFACE "${RETAIL_INTERFACE:-}")"

for manifest in AsgardsGuildFellowship_Camelot.toc AsgardsGuildFellowship_Mainline.toc; do
    [ -f "$repo_root/$manifest" ] || { echo "Could not set the interface: $manifest is missing." >&2; exit 1; }
done

set_interface() {
    local manifest="$repo_root/$1" value="$2"
    INTERFACE_VALUE="$value" perl -pi -e 's/^## Interface:.*$/## Interface: $ENV{INTERFACE_VALUE}/' "$manifest"
    grep -qxF "## Interface: $value" "$manifest" || { echo "Could not set the interface in $1." >&2; exit 1; }
}

set_interface AsgardsGuildFellowship_Camelot.toc "$forever"
set_interface AsgardsGuildFellowship_Mainline.toc "$retail"
echo "Release supports WoW Forever $forever and WoW Retail $retail."
