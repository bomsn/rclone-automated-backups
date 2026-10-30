#!/usr/bin/env bash
# Read a disposable WordPress fixture and restore into private temporary storage.
set -euo pipefail
test "$(id -u)" = 0 || exit 1
admin=${MYSQL_TEST_DEFAULTS:-/etc/mysql/debian.cnf}
source_dir=$(cd "$(dirname "$0")/.." && pwd)
fixture=${1:?Supply a disposable WordPress fixture, never a production site}
work=$(mktemp -d /var/tmp/rclone-incremental-test.XXXXXXXXXX)
remote="rclone-lab-$(basename "$work" | tr -cd 'a-zA-Z0-9')"
dump_path=''
test_db="rclone_incremental_test_$$"
cleanup() {
    local rc=$?
    trap - EXIT
    rclone config delete "$remote" >/dev/null 2>&1 || true
    mysql --defaults-extra-file="$admin" -e "DROP DATABASE IF EXISTS \`$test_db\`; DROP USER IF EXISTS '$test_db'@'localhost';" || true
    if [[ "$dump_path" =~ ^/var/lib/rclone-automated-backups/dumps/[a-f0-9]{32}/database\.sql$ ]]; then
        rm -f -- "$dump_path"
        rmdir -- "${dump_path%/*}" || true
    fi
    if [[ "${RESTORE_SQL_FILE:-}" == /var/tmp/rclone-restore-db.* ]]; then
        rm -f -- "$RESTORE_SQL_FILE"
    fi
    case "$work" in /var/tmp/rclone-incremental-test.*) rm -rf -- "$work" ;; esac
    exit "$rc"
}
trap cleanup EXIT
mkdir -p "$work/remote" "$work/restored"
rclone config create "$remote" local >/dev/null
cd "$work"
source "$source_dir/lib/domains.sh"
source "$source_dir/lib/definitions.sh"
source "$source_dir/lib/backup-create.sh"
source "$source_dir/lib/restore.sh"
DOMAINS=(lab.example)
PATHS=("$fixture")
BACKUP_DOMAIN=lab.example BACKUP_FREQUENCY=daily BACKUP_DAY='' BACKUP_TIME=02:00
RETENTION_PERIOD=7 EXCLUDED_ITEMS='' REMOTE_BACKUP_LOCATION="$work/remote"
BACKUP_TYPE=incremental BACKUP_REMOTE="$remote" SKIP_INITIAL=true DB_DRIVER=wpcli
BACKUP_PASS='spaces = quotes " and $literal kept safe'
LOCK_TIMEOUT=1 WP_CLI_PATH=${TEST_WP_CLI_PATH:-/usr/bin/wp}
BACKUP_PHP_BINARY=${TEST_PHP_BINARY:-/usr/bin/php8.3}
CRON_SCRIPTS_DIR=cron_scripts TMP_DIR="$work/tmp" DEFINITIONS_FILE=definitions
LOG_FILE="$work/backup.log" LOCK_FILE="$work/backup.lock" COMPAT_LOCK_FILE="$work/compat.lock"
CRON_FILE="$work/cron" COMPAT_CRON_FILE="$work/compat-cron"
RED='' RESET='' YELLOW='' GREEN='' BOLD='' NOTIFY_EMAIL=''
set +u
create_backup_from_settings headless > "$work/generate.log"
set -u
script=$(find "$work/cron_scripts" -type f -print -quit)
test "$(stat -c %a "$script")" = 700
bash -n "$script"
test "$(read_restic_password "$script")" = "$BACKUP_PASS"
if ! bash "$script" initial; then
    tail -30 "$LOG_FILE"
    exit 1
fi
dump_path=$(sed -n 's/^db_snapshot_path="\([^"]*\)"$/\1/p' "$script")
test -n "$dump_path"
test ! -e "$dump_path"
repository="rclone:$remote:$work/remote"
RESTIC_PASSWORD="$BACKUP_PASS" restic -r "$repository" check >/dev/null
RESTIC_PASSWORD="$BACKUP_PASS" restic -r "$repository" restore "latest:$fixture" --target "$work/restored" >/dev/null
cmp "$fixture/wp-includes/version.php" "$work/restored/wp-includes/version.php"
test -z "$(find "$fixture" -maxdepth 1 -name '*_incremental.sql' -print -quit)"
restore_incremental_database_file "$script" latest "$repository" "$BACKUP_PASS"
test "$(stat -c %a "$RESTORE_SQL_FILE")" = 600
test -s "$RESTORE_SQL_FILE"
grep -q 'CREATE TABLE' "$RESTORE_SQL_FILE"
RESTORE_TARGET_PATH="$work/db-only"
mkdir "$RESTORE_TARGET_PATH"
RESTORE_DB_MODE=explicit RESTORE_DB_NAME="$test_db" RESTORE_DB_USER="$test_db" RESTORE_DB_HOST=localhost
RESTORE_DB_PASS=$(openssl rand -hex 24)
mysql --defaults-extra-file="$admin" -e "CREATE DATABASE \`$test_db\`; CREATE USER '$test_db'@'localhost' IDENTIFIED BY '$RESTORE_DB_PASS'; GRANT ALL ON \`$test_db\`.* TO '$test_db'@'localhost';"
run_restore_db_import incremental "$script" unused
table_count=$(mysql --defaults-extra-file="$admin" -Nse "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$test_db'")
test "$table_count" -gt 0
echo 'PASS: encrypted incremental snapshot, literal password, private SQL, checked repository, isolated files and actual database import'
