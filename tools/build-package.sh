#!/usr/bin/env bash
# Builds the multi-client release zip locally with the BigWigs packager, never
# uploading, then validates its contents.
# Usage: tools/build-package.sh [release-dir]   (default: .release)
#
# The packager needs bash 4.3+. macOS ships 3.2, so point PACKAGER_BASH at a
# newer bash (for example from `brew install bash`). It also needs an svn
# client for the CurseForge svn library externals (`brew install subversion`,
# or `sudo apt-get install subversion`).
#
# The package is built from a fresh clone of the committed history, so a
# fetched, git-ignored Libs/ folder (or any uncommitted file) can never be
# packaged in place of the pinned externals the packager fetches itself.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
release_dir="${1:-$repo_root/.release}"
packager_bash="${PACKAGER_BASH:-bash}"
# The pinned packager revision every build and release shares.
# shellcheck source=tools/packager.env
source "$repo_root/tools/packager.env"
packager_url="https://raw.githubusercontent.com/BigWigsMods/packager/${PACKAGER_COMMIT}/release.sh"

if ! "$packager_bash" -c '(( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 3) ))'; then
    echo "The packager needs bash 4.3 or newer; '$packager_bash' is older. Set PACKAGER_BASH to a newer bash." >&2
    exit 1
fi

if ! command -v svn >/dev/null 2>&1; then
    echo "The packager needs an svn client to fetch the CurseForge library externals, and none was found." >&2
    echo "Install one (macOS: brew install subversion; Debian/Ubuntu: sudo apt-get install subversion) and try again." >&2
    exit 1
fi

if [ -n "$(git -C "$repo_root" status --porcelain --untracked-files=no)" ]; then
    echo "Note: uncommitted changes are not packaged; the build uses the committed history only." >&2
fi

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
checkout_dir="$work_dir/checkout"
# Build into an empty staging directory so an older zip can never be the one
# that gets validated.
staging_dir="$work_dir/release"

git clone --quiet "$repo_root" "$checkout_dir"
curl -fsSL "$packager_url" -o "$work_dir/release.sh"
# -d: never upload anywhere. The result is only a local zip.
"$packager_bash" "$work_dir/release.sh" -d -t "$checkout_dir" -r "$staging_dir" | tee "$work_dir/packager.log"

# The packager tags game versions from the manifest suffixes. A suffix it does
# not recognize silently drops that client from the release.
if ! grep -q '^Build type: multi-version' "$work_dir/packager.log"; then
    echo "The packager did not tag this build for both Forever and Retail. Check the manifest suffixes." >&2
    exit 1
fi

shopt -s nullglob
staged_zips=("$staging_dir"/AsgardsGuildFellowship-*.zip)
shopt -u nullglob
if [ "${#staged_zips[@]}" -ne 1 ]; then
    echo "Expected exactly one AsgardsGuildFellowship-*.zip in $staging_dir, found ${#staged_zips[@]}." >&2
    exit 1
fi
"$repo_root/tools/check-package.sh" "${staged_zips[0]}"

mkdir -p "$release_dir"
zip_path="$release_dir/$(basename "${staged_zips[0]}")"
mv -f "${staged_zips[0]}" "$zip_path"
echo "Inspect the package with: unzip -l \"$zip_path\""
