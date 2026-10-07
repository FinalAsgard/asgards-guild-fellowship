#!/usr/bin/env bash
# Tests that tools/fetch-packager.sh keeps a download only when its SHA-256
# matches the pinned digest. A stand-in curl writes a known file instead of
# downloading anything.
# Usage: tests/tools/fetch-packager.test.sh
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fetch="$repo_root/tools/fetch-packager.sh"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

# The stand-in curl writes "stand-in packager" to the file after -o.
mkdir -p "$work_dir/bin"
cat > "$work_dir/bin/curl" <<'EOF'
#!/bin/sh
while [ "$#" -gt 0 ]; do
    if [ "$1" = "-o" ]; then printf 'stand-in packager\n' > "$2"; exit 0; fi
    shift
done
exit 1
EOF
chmod +x "$work_dir/bin/curl"
printf 'stand-in packager\n' > "$work_dir/expected"
if command -v sha256sum >/dev/null 2>&1; then
    digest="$(sha256sum "$work_dir/expected" | cut -d ' ' -f 1)"
else
    digest="$(shasum -a 256 "$work_dir/expected" | cut -d ' ' -f 1)"
fi
search_path="$work_dir/bin:$PATH"

passed=0
failed=0

check() {
    local name="$1" condition="$2"
    if eval "$condition"; then
        passed=$((passed + 1)); echo "PASS $name"
    else
        failed=$((failed + 1)); echo "FAIL $name"
        printf '%s\n' "$output" | sed 's/^/    /'
    fi
}

run() {
    rm -f "$work_dir/release.sh"
    set +e
    output="$(env PATH="$search_path" "$@" "$BASH" "$fetch" "$work_dir/release.sh" 2>&1)"
    status=$?
    set -e
}

run PACKAGER_SHA256="$digest"
check "keeps a download that matches the pinned digest" '[ "$status" -eq 0 ] && cmp -s "$work_dir/release.sh" "$work_dir/expected"'

run PACKAGER_SHA256="0000000000000000000000000000000000000000000000000000000000000000"
check "rejects a download that doesn't match" '[ "$status" -ne 0 ] && printf "%s" "$output" | grep -Fq "not the pinned"'
check "deletes the rejected download" '[ ! -e "$work_dir/release.sh" ]'

# The committed digest is the real packager's, so the stand-in never matches it.
run
check "checks against the digest in tools/packager.env by default" '[ "$status" -ne 0 ] && printf "%s" "$output" | grep -Fq "59b15a8d851b09e6d0fdec702aec91331b9b49d84dbe778da6c621b48f268703"'

echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
