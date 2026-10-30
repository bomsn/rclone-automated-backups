#!/usr/bin/env bash
set -euo pipefail
test "$(id -u)" = 0 || exit 1
source_dir=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d /var/tmp/rclone-literal-test.XXXXXXXXXX)
remote="rclone-literal-$$"
cleanup() {
    local rc=$?
    trap - EXIT
    rclone config delete "$remote" >/dev/null 2>&1 || true
    case "$work" in /var/tmp/rclone-literal-test.*) rm -rf -- "$work" ;; esac
    exit "$rc"
}
trap cleanup EXIT
cd "$work"
source "$source_dir/lib/domains.sh"
source "$source_dir/lib/definitions.sh"
source "$source_dir/lib/backup-create.sh"
source "$source_dir/lib/restore.sh"
literal='space $(touch MUST-NOT-RUN) `touch ALSO-NOT` "quote'
mkdir -p "$work/$literal/source" "$work/$literal/remote" "$work/$literal/restored"
chmod 700 "$work/$literal"
printf 'literal paths work\n' > "$work/$literal/source/content"
rclone config create "$remote" local >/dev/null
DOMAINS=(lab.example) PATHS=("$work/$literal/source")
BACKUP_DOMAIN=lab.example BACKUP_FREQUENCY=daily BACKUP_DAY='' BACKUP_TIME=02:00
RETENTION_PERIOD=7 EXCLUDED_ITEMS='' REMOTE_BACKUP_LOCATION="$work/$literal/remote"
BACKUP_TYPE=files BACKUP_REMOTE="$remote" SKIP_INITIAL=true DB_DRIVER=wpcli
LOCK_TIMEOUT=1 WP_CLI_PATH=/usr/bin/wp
CRON_SCRIPTS_DIR=cron_scripts TMP_DIR="$work/tmp" DEFINITIONS_FILE=definitions
LOG_FILE="$work/$literal/backup.log" LOCK_FILE="$work/$literal/backup.lock" COMPAT_LOCK_FILE="$work/$literal/compat.lock"
CRON_FILE="$work/cron" COMPAT_CRON_FILE="$work/compat-cron"
RED='' RESET='' YELLOW='' GREEN='' BOLD='' NOTIFY_EMAIL=''
set +u
create_backup_from_settings headless >/dev/null
set -u
script=$(find "$work/cron_scripts" -type f -print -quit)
test "$(read_backup_setting "$script" domain_path)" = "${PATHS[0]}"
bash "$script" initial
test ! -e MUST-NOT-RUN && test ! -e ALSO-NOT
archive=$(find "$work/$literal/remote" -name '*.tar.gz' -print -quit)
RESTORE_TARGET_PATH="$work/$literal/restored" RESTORE_PRESERVE_WPCONFIG=''
capture_restore_identity
restore_archive_files "$archive" true
cmp "$work/$literal/source/content" "$work/$literal/restored/content"
test ! -e MUST-NOT-RUN && test ! -e ALSO-NOT
printf 'domain="literal$(touch MUST-NOT-RUN)"\n' > "$work/legacy"
test "$(read_backup_setting "$work/legacy" domain)" = 'literal$(touch MUST-NOT-RUN)'
printf 'domain_b64=YQ==\ndomain_b64=Yg==\n' > "$work/duplicate"
if read_backup_setting "$work/duplicate" domain; then
    echo 'Duplicate encoded metadata accepted' >&2; exit 1
fi
echo 'PASS: generated jobs, logs, remote paths, archives, safe restore and legacy metadata keep shell syntax literal'
