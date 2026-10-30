#!/usr/bin/env bash
set -euo pipefail
source_dir=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d /var/tmp/rclone-probe-test.XXXXXXXXXXXX)
trap 'rm -f -- "$work/remote/wpali.com.txt" "$work/remote/important.backup"; rmdir -- "$work/remote" "$work"' EXIT
mkdir "$work/remote"
printf 'keep-existing-test-name' > "$work/remote/wpali.com.txt"
printf 'keep-backup' > "$work/remote/important.backup"
source "$source_dir/lib/remote-probe.sh"
verify_rclone_destination ':local' "$work/remote"
test "$(cat "$work/remote/wpali.com.txt")" = keep-existing-test-name
test "$(cat "$work/remote/important.backup")" = keep-backup
test "$(find "$work/remote" -maxdepth 1 -type f | wc -l)" = 2
echo 'Unique remote write/read/delete probe preserves unrelated objects.'
