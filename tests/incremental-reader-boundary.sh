#!/usr/bin/env bash
# Real owner reads, root-private materialization, restic backup and restore.
set -euo pipefail
test "$(id -u)" = 0 || exit 1
source_dir=$(cd "$(dirname "$0")/.." && pwd)
actor=${TEST_SITE_USER:-nobody}
actor_uid=$(id -u "$actor")
actor_gid=$(id -g "$actor")
test "$actor_uid" != 0
work=$(mktemp -d /var/tmp/rclone-reader-boundary.XXXXXXXXXX)
cleanup() {
    local rc=$?
    trap - EXIT
    case "$work" in /var/tmp/rclone-reader-boundary.*) test ! -L "$work" && rm -rf -- "$work" ;; esac
    exit "$rc"
}
trap cleanup EXIT
chmod 755 "$work"
mkdir "$work/site" "$work/site/nested" "$work/site/cache"
printf 'original website file' > "$work/site/nested/data.txt"
printf 'hidden file' > "$work/site/.hidden"
printf 'excluded cache' > "$work/site/cache/omit.txt"
touch -m -d @1700000000 "$work/site/nested/data.txt"
chown -R "$actor_uid:$actor_gid" "$work/site"
mkdir -m 700 "$work/root-private" "$work/snapshot" "$work/refused"
printf 'root-only synthetic canary' > "$work/root-private/data.txt"
cp "$source_dir/lib/restore-files.py" "$work/extractor.py"
chmod 600 "$work/extractor.py"
source "$source_dir/lib/archive.sh"
create_incremental_tree "$work/site" "$work/snapshot" "$work/extractor.py" --exclude=cache
copied="$work/snapshot/incremental-tree/${work#/}/site"
test ! -e "$copied/cache/omit.txt"
test "$(stat -c %Y "$copied/nested/data.txt")" = 1700000000
if sudo -u "#$actor_uid" -- test -e "$copied/nested/data.txt"; then
    echo 'FAIL: website identity can access the protected snapshot' >&2
    exit 1
fi
# Mutating the live parent after preparation cannot affect the privileged reader.
sudo -u "#$actor_uid" -- rm -rf -- "$work/site/nested"
sudo -u "#$actor_uid" -- ln -s "$work/root-private" "$work/site/nested"
export RESTIC_PASSWORD='isolated reader fixture only' RESTIC_REPOSITORY="$work/repository"
restic init --quiet >/dev/null
(cd "$work/snapshot/incremental-tree" && restic backup --quiet "${work#/}/site")
restic restore "latest:$work/site" --target "$work/restored" --quiet
test "$(cat "$work/restored/nested/data.txt")" = 'original website file'
test "$(cat "$work/restored/.hidden")" = 'hidden file'
if create_incremental_tree "$work/site" "$work/refused" "$work/extractor.py" > "$work/rejection.log" 2>&1; then
    echo 'FAIL: external link accepted into an immutable snapshot' >&2
    exit 1
fi
echo 'PASS: owner read boundary, private immutable tree, live parent replacement, original restic selector, timestamps, hidden files, exclusions and unsafe-link refusal'
