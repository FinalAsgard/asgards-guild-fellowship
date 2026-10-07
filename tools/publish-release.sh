#!/usr/bin/env bash
# Builds the tagged release with the pinned BigWigs packager and uploads it to
# CurseForge, tagged for both WoW Forever and WoW Retail. Run by the Release
# workflow when a GitHub release is published, after tools/build-package.sh
# has built and validated the same checkout without uploading.
# Needs: CF_API_KEY (secret, a CurseForge API token) and CURSEFORGE_PROJECT_ID
# (variable, the numeric project ID), plus an svn client for the library
# externals. PUBLISH_DIR, when set, receives a copy of the uploaded zip.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Every setup problem is reported before anything is downloaded or uploaded.
missing=()
[ -n "${CURSEFORGE_PROJECT_ID:-}" ] || missing+=("the CURSEFORGE_PROJECT_ID repository variable")
[ -n "${CF_API_KEY:-}" ] || missing+=("the CF_API_KEY repository secret")
if [ "${#missing[@]}" -gt 0 ]; then
    for item in "${missing[@]}"; do
        echo "Publishing needs $item, which is not set. Nothing was uploaded." >&2
    done
    exit 1
fi
# The packager silently skips CurseForge for a non-numeric ID and treats 0 as
# "no project", which would publish nothing.
if [[ ! "$CURSEFORGE_PROJECT_ID" =~ ^[1-9][0-9]*$ ]]; then
    echo "CURSEFORGE_PROJECT_ID must be the numeric CurseForge project ID; got '$CURSEFORGE_PROJECT_ID'. Nothing was uploaded." >&2
    exit 1
fi
if ! command -v svn >/dev/null 2>&1; then
    echo "Publishing needs an svn client to fetch the CurseForge library externals. Nothing was uploaded." >&2
    exit 1
fi

# The packager would rewrite the GitHub release's title and notes with its
# own changelog, so it never gets a GitHub token; the workflow attaches the
# zip to the release itself. No other upload targets are configured either.
unset GITHUB_OAUTH GITHUB_API_TOKEN WOWI_API_TOKEN WAGO_API_TOKEN

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
"$repo_root/tools/fetch-packager.sh" "$work_dir/release.sh"
bash "$work_dir/release.sh" -t "$repo_root" -r "$work_dir/release" -p "$CURSEFORGE_PROJECT_ID" \
    | tee "$work_dir/packager.log"

# The packager tags game versions from the manifest suffixes; a build tagged
# for only one client would hide the release from the other.
if ! grep -q '^Build type: multi-version' "$work_dir/packager.log"; then
    echo "The packager did not tag this release for both Forever and Retail." >&2
    exit 1
fi

shopt -s nullglob
published_zips=("$work_dir"/release/AsgardsGuildFellowship-*.zip)
shopt -u nullglob
if [ "${#published_zips[@]}" -ne 1 ]; then
    echo "Expected exactly one AsgardsGuildFellowship-*.zip from the packager, found ${#published_zips[@]}." >&2
    exit 1
fi
"$repo_root/tools/check-package.sh" "${published_zips[0]}" "$work_dir/packager.log"

if [ -n "${PUBLISH_DIR:-}" ]; then
    mkdir -p "$PUBLISH_DIR"
    cp "${published_zips[0]}" "$PUBLISH_DIR"/
fi
