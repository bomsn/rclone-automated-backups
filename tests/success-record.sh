#!/usr/bin/env bash
# Every successful run of a generated job replaces its success record
# ( status/<job>.json ), which monitoring reads to detect a missed backup; a failed
# run leaves the previous record untouched.
set -euo pipefail
test "$(id -u)" = 0 || exit 1
source_dir=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d /var/tmp/rclone-status-test.XXXXXXXXXX)
remote="rclone-status-$$"
cleanup() {
    local rc=$?
    trap - EXIT
    rclone config delete "$remote" >/dev/null 2>&1 || true
    case "$work" in /var/tmp/rclone-status-test.*) rm -rf -- "$work" ;; esac
    exit "$rc"
}
trap cleanup EXIT
cd "$work"
source "$source_dir/lib/locking.sh"
source "$source_dir/lib/domains.sh"
source "$source_dir/lib/definitions.sh"
source "$source_dir/lib/backup-create.sh"
mkdir -p "$work/source" "$work/remote"
printf 'content\n' > "$work/source/file"
rclone config create "$remote" local >/dev/null
DOMAINS=(status.example) PATHS=("$work/source")
BACKUP_DOMAIN=status.example BACKUP_FREQUENCY=daily BACKUP_DAY='' BACKUP_TIME=04:30
RETENTION_PERIOD=7 EXCLUDED_ITEMS='' REMOTE_BACKUP_LOCATION="$work/remote"
BACKUP_TYPE=files BACKUP_REMOTE="$remote" SKIP_INITIAL=true DB_DRIVER=wpcli
LOCK_TIMEOUT=1 WP_CLI_PATH=/usr/bin/wp
CRON_SCRIPTS_DIR="$work/cron_scripts" TMP_DIR="$work/tmp" DEFINITIONS_FILE="$work/definitions"
LOG_FILE="$work/backup.log" LOCK_FILE="$work/backup.lock" COMPAT_LOCK_FILE="$work/compat.lock"
CRON_FILE="$work/cron" COMPAT_CRON_FILE="$work/compat-cron" STATUS_DIR="$work/status"
RED='' RESET='' YELLOW='' GREEN='' BOLD='' NOTIFY_EMAIL=''
set +u
create_backup_from_settings headless >/dev/null
set -u
script=$(find "$work/cron_scripts" -type f -print -quit)
job=$(basename "$script")
grep -q "^30 04 \* \* \* root /bin/bash $script$" "$work/cron"
test ! -e "$work/status/$job.json"

before=$(date +%s)
bash "$script"
record="$work/status/$job.json"
python3 - "$record" "$job" "$before" <<'PY'
import json, sys, time
record = json.load(open(sys.argv[1]))
assert record['job'] == sys.argv[2] and record['domain'] == 'status.example', record
assert record['type'] == 'files' and record['schedule'] == 'daily' and record['cron'] == '30 04 * * *', record
assert int(sys.argv[3]) <= record['started_at'] <= record['finished_at'] <= time.time(), record
PY
test "$(stat -c %a "$work/status")" = 700 && test "$(stat -c %a "$record")" = 600
first=$(cat "$record")

# A failed run ( the remote location is gone ) keeps the last success.
rclone config delete "$remote"
if bash "$script"; then echo 'A run without its remote succeeded' >&2; exit 1; fi
test "$(cat "$record")" = "$first"
test -z "$(find "$work/status" -name '.*' -print -quit)"
echo 'PASS: successful runs record their time for monitoring; a failed run leaves the last success'
