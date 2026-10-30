#!/usr/bin/env bash
# Real generator/tar/rclone round trip using a dedicated local remote. No existing
# cron file, site, storage remote or database is changed by this test.
set -euo pipefail
test "$(id -u)" = 0 || { echo 'Run in an isolated Linux lab as root.' >&2; exit 1; }
source_dir=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d /var/tmp/rclone-backup-test.XXXXXXXXXX)
remote="rclone-lab-$(basename "$work" | tr -cd 'a-zA-Z0-9')"
cleanup() {
    local rc=$?
    trap - EXIT
    rclone config delete "$remote" >/dev/null 2>&1 || true
    case "$work" in /var/tmp/rclone-backup-test.*) rm -rf -- "$work" ;; esac
    exit "$rc"
}
trap cleanup EXIT
mkdir -p "$work/source/nested" "$work/remote" "$work/restored"
printf 'restore-verification\n' > "$work/source/nested/important.txt"
rclone config create "$remote" local >/dev/null
cd "$work"
source "$source_dir/lib/domains.sh"
source "$source_dir/lib/definitions.sh"
source "$source_dir/lib/backup-create.sh"
DOMAINS=(lab.example)
PATHS=("$work/source")
BACKUP_DOMAIN=lab.example BACKUP_FREQUENCY=daily BACKUP_DAY='' BACKUP_TIME=02:00
RETENTION_PERIOD=7 EXCLUDED_ITEMS='' REMOTE_BACKUP_LOCATION="$work/remote"
BACKUP_TYPE=files BACKUP_REMOTE="$remote" SKIP_INITIAL=true DB_DRIVER=wpcli
LOCK_TIMEOUT=1 WP_CLI_PATH=/usr/bin/wp
CRON_SCRIPTS_DIR=cron_scripts TMP_DIR="$work/tmp" DEFINITIONS_FILE=definitions
LOG_FILE="$work/backup.log" LOCK_FILE="$work/backup.lock" COMPAT_LOCK_FILE="$work/compat.lock"
CRON_FILE="$work/cron" COMPAT_CRON_FILE="$work/compat-cron"
RED='' RESET='' YELLOW='' GREEN='' BOLD='' NOTIFY_EMAIL=''
# Interactive constants are unused, but the legacy generator is not nounset-clean.
set +u
create_backup_from_settings headless >/dev/null
set -u
script=$(find "$work/cron_scripts" -type f -print -quit)
test "$(stat -c %a "$script")" = 700
bash -n "$script"
bash "$script" initial
archive=$(find "$work/remote" -name '*.tar.gz' -print -quit)
test -n "$archive"
tar -xzf "$archive" -C "$work/restored"
cmp "$work/source/nested/important.txt" "$work/restored/nested/important.txt"
# A busy lock must report a missed backup, not pretend to have succeeded.
flock "$LOCK_FILE" sleep 5 &
lock_pid=$!
sleep 0.2
set +e
bash "$script" initial
status=$?
set -e
wait "$lock_pid"
test "$status" = 75
rm -- "$COMPAT_LOCK_FILE"
printf 'must-not-be-truncated\n' > "$work/untouched"
ln -s "$work/untouched" "$COMPAT_LOCK_FILE"
if bash "$script" initial; then
    echo 'Unsafe symlink lock was accepted' >&2
    exit 1
fi
test "$(cat "$work/untouched")" = must-not-be-truncated
rm -- "$COMPAT_LOCK_FILE" "$LOG_FILE"
ln -s "$work/untouched" "$LOG_FILE"
if bash "$script" initial; then
    echo 'Unsafe symlink log was accepted' >&2
    exit 1
fi
test "$(cat "$work/untouched")" = must-not-be-truncated
echo 'PASS: generated script permissions, archive round trip, lock-timeout failure and symlink-log denial'
