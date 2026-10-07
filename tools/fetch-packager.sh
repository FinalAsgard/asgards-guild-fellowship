#!/usr/bin/env bash
# Downloads the pinned BigWigs packager (tools/packager.env) to <destination>
# and checks its SHA-256 against PACKAGER_SHA256. A mismatch deletes the
# download and fails, so a changed script is never run.
# Usage: tools/fetch-packager.sh <destination>
#
# PACKAGER_SHA256 may be set in the environment to override the pinned
# digest; the tests use it.
set -euo pipefail

destination="${1:?usage: tools/fetch-packager.sh <destination>}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
expected_sha256="${PACKAGER_SHA256:-}"
# shellcheck source=tools/packager.env
source "$repo_root/tools/packager.env"
[ -z "$expected_sha256" ] || PACKAGER_SHA256="$expected_sha256"

curl -fsSL "https://raw.githubusercontent.com/BigWigsMods/packager/${PACKAGER_COMMIT}/release.sh" \
    -o "$destination"

if command -v sha256sum >/dev/null 2>&1; then
    actual_sha256="$(sha256sum "$destination" | cut -d ' ' -f 1)"
else
    actual_sha256="$(shasum -a 256 "$destination" | cut -d ' ' -f 1)"
fi
if [ "$actual_sha256" != "$PACKAGER_SHA256" ]; then
    rm -f "$destination"
    echo "The downloaded packager's SHA-256 is $actual_sha256, not the pinned $PACKAGER_SHA256 from tools/packager.env. It was not run." >&2
    exit 1
fi
