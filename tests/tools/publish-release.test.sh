#!/usr/bin/env bash
# Tests that tools/publish-release.sh refuses to run, with a message naming
# what is missing, before it downloads or uploads anything. A stand-in curl
# records whether the packager would have been downloaded.
# Usage: tests/tools/publish-release.test.sh
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
publish="$repo_root/tools/publish-release.sh"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

# Stand-ins: curl records that it ran; svn exists unless a case removes it.
mkdir -p "$work_dir/bin" "$work_dir/no-svn"
printf '#!/bin/sh\n: > "%s/downloaded"\nexit 1\n' "$work_dir" > "$work_dir/bin/curl"
printf '#!/bin/sh\nexit 0\n' > "$work_dir/bin/svn"
cp "$work_dir/bin/curl" "$work_dir/no-svn/curl"
chmod +x "$work_dir/bin/curl" "$work_dir/bin/svn" "$work_dir/no-svn/curl"
# The no-svn folder is the whole PATH for that case, so an svn installed on
# the machine can't be found; the script needs only dirname before its checks.
ln -s "$(command -v dirname)" "$work_dir/no-svn/dirname"

# PATH for each stand-in folder.
search_path() {
    case "$1" in
        no-svn) printf '%s' "$work_dir/no-svn" ;;
        *) printf '%s' "$work_dir/$1:/usr/bin:/bin" ;;
    esac
}

passed=0
failed=0

# expect <name> <message> <bin folder> [VARIABLE=value...]
expect() {
    local name="$1" message="$2" bin="$3" output status
    shift 3
    rm -f "$work_dir/downloaded"
    set +e
    output="$(env -u CF_API_KEY -u CURSEFORGE_PROJECT_ID PATH="$(search_path "$bin")" "$@" "$BASH" "$publish" 2>&1)"
    status=$?
    set -e
    if [ "$status" -ne 0 ] && printf '%s' "$output" | grep -Fq -- "$message" && [ ! -e "$work_dir/downloaded" ]; then
        passed=$((passed + 1)); echo "PASS $name"
    else
        failed=$((failed + 1)); echo "FAIL $name (expected '$message' and no download)"
        printf '%s\n' "$output" | sed 's/^/    /'
    fi
}

expect "names a missing project ID" "needs the CURSEFORGE_PROJECT_ID repository variable" bin "CF_API_KEY=token"
expect "names a missing API key" "needs the CF_API_KEY repository secret" bin "CURSEFORGE_PROJECT_ID=123456"
expect "names both when both are missing" "needs the CURSEFORGE_PROJECT_ID repository variable" bin
expect "names the API key too when both are missing" "needs the CF_API_KEY repository secret" bin
expect "an empty API key counts as missing" "needs the CF_API_KEY repository secret" bin "CF_API_KEY=" "CURSEFORGE_PROJECT_ID=123456"
expect "rejects a non-numeric project ID" "must be the numeric CurseForge project ID; got 'my-addon'" bin "CF_API_KEY=token" "CURSEFORGE_PROJECT_ID=my-addon"
expect "rejects project ID 0" "must be the numeric CurseForge project ID; got '0'" bin "CF_API_KEY=token" "CURSEFORGE_PROJECT_ID=0"
expect "needs an svn client" "needs an svn client" no-svn "CF_API_KEY=token" "CURSEFORGE_PROJECT_ID=123456"

# With everything set, the script goes on to download the packager.
rm -f "$work_dir/downloaded"
set +e
env PATH="$(search_path bin)" CF_API_KEY=token CURSEFORGE_PROJECT_ID=123456 "$BASH" "$publish" > /dev/null 2>&1
set -e
if [ -e "$work_dir/downloaded" ]; then
    passed=$((passed + 1)); echo "PASS downloads the packager once setup is complete"
else
    failed=$((failed + 1)); echo "FAIL downloads the packager once setup is complete"
fi

echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
