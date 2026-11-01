#!/usr/bin/env bash
# New installs keep cron scripts and definitions under an absolute state directory
# (/var/lib/rclone-automated-backups). The cron line and the job's notification lookup
# once prefixed those absolute paths with $PWD, producing a path cron could never run.
set -euo pipefail
test "$(id -u)" = 0 || exit 1
source_dir=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d /var/tmp/rclone-state-test.XXXXXXXXXX)
remote="rclone-state-$$"
cleanup() {
    local rc=$?
    trap - EXIT
    rclone config delete "$remote" >/dev/null 2>&1 || true
    case "$work" in /var/tmp/rclone-state-test.*) rm -rf -- "$work" ;; esac
    exit "$rc"
}
trap cleanup EXIT
install -d -m 700 "$work/state" "$work/state/cron_scripts" "$work/source" "$work/remote" "$work/elsewhere"
printf 'state paths\n' > "$work/source/content"
# Run from an unrelated directory, as an operator's shell or cron would.
cd "$work/elsewhere"
source "$source_dir/lib/domains.sh"
source "$source_dir/lib/definitions.sh"
source "$source_dir/lib/backup-create.sh"
rclone config create "$remote" local >/dev/null
DOMAINS=(lab.example) PATHS=("$work/source")
BACKUP_DOMAIN=lab.example BACKUP_FREQUENCY=daily BACKUP_DAY='' BACKUP_TIME=02:00
RETENTION_PERIOD=7 EXCLUDED_ITEMS='' REMOTE_BACKUP_LOCATION="$work/remote"
BACKUP_TYPE=files BACKUP_REMOTE="$remote" SKIP_INITIAL=true DB_DRIVER=wpcli
LOCK_TIMEOUT=1 WP_CLI_PATH=/usr/bin/wp
CRON_SCRIPTS_DIR="$work/state/cron_scripts" TMP_DIR="$work/state/tmp" DEFINITIONS_FILE="$work/state/definitions"
LOG_FILE="$work/state/backup.log" LOCK_FILE="$work/state/backup.lock" COMPAT_LOCK_FILE="$work/state/compat.lock"
CRON_FILE="$work/cron" COMPAT_CRON_FILE="$work/compat-cron"
RED='' RESET='' YELLOW='' GREEN='' BOLD='' NOTIFY_EMAIL=''
update_definitions
set +u
create_backup_from_settings headless >/dev/null
set -u
script=$(find "$work/state/cron_scripts" -type f -print -quit)
scheduled=$(awk '{print $NF}' "$work/cron")
test "$scheduled" = "$script" || { echo "Cron runs '$scheduled', not the generated job '$script'" >&2; exit 1; }
encoded=$(sed -n 's/^definitions_file_b64=//p' "$script")
test "$(printf '%s' "$encoded" | base64 -d)" = "$work/state/definitions"
test "$(operator_path relative/job)" = "$work/elsewhere/relative/job"
echo 'PASS: cron entries and job notification lookups use the absolute state paths'
