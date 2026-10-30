#!/usr/bin/env bash
# A generated full archive and the actual safe restore/database-import path.
set -euo pipefail
test "$(id -u)" = 0 || exit 1
fixture=${1:?Supply the disposable WordPress fixture}
admin=${MYSQL_TEST_DEFAULTS:-/etc/mysql/debian.cnf}
source_dir=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d /home/cmcptest/.rclone-full-test.XXXXXXXXXX)
chmod 711 "$work"
remote="rclone-full-$$" test_db="rclone_full_test_$$"
cleanup() {
    local rc=$?
    trap - EXIT
    rclone config delete "$remote" >/dev/null 2>&1 || true
    mysql --defaults-extra-file="$admin" -e "DROP DATABASE IF EXISTS \`$test_db\`; DROP USER IF EXISTS '$test_db'@'localhost';" || true
    if [[ "${RESTORE_SQL_FILE:-}" == /var/tmp/rclone-restore-db.* ]]; then rm -f -- "$RESTORE_SQL_FILE"; fi
    case "$work" in /home/cmcptest/.rclone-full-test.*) rm -rf -- "$work" ;; esac
    exit "$rc"
}
trap cleanup EXIT
mkdir "$work/remote" "$work/restored"
chown --reference="$fixture" "$work/restored"
rclone config create "$remote" local >/dev/null
cd "$work"
source "$source_dir/lib/domains.sh"
source "$source_dir/lib/definitions.sh"
source "$source_dir/lib/backup-create.sh"
source "$source_dir/lib/restore.sh"
DOMAINS=(lab.example) PATHS=("$fixture")
BACKUP_DOMAIN=lab.example BACKUP_FREQUENCY=daily BACKUP_DAY='' BACKUP_TIME=02:00
RETENTION_PERIOD=7 EXCLUDED_ITEMS='' REMOTE_BACKUP_LOCATION="$work/remote"
BACKUP_TYPE=full BACKUP_REMOTE="$remote" SKIP_INITIAL=true DB_DRIVER=wpcli
LOCK_TIMEOUT=1 WP_CLI_PATH=${TEST_WP_CLI_PATH:-/usr/bin/wp}
WP_PHP_BIN=${TEST_PHP_BINARY:-/usr/bin/php8.3} BACKUP_PHP_BINARY=${TEST_PHP_BINARY:-/usr/bin/php8.3}
CRON_SCRIPTS_DIR=cron_scripts TMP_DIR="$work/tmp" DEFINITIONS_FILE=definitions
LOG_FILE="$work/backup.log" LOCK_FILE="$work/backup.lock" COMPAT_LOCK_FILE="$work/compat.lock"
CRON_FILE="$work/cron" COMPAT_CRON_FILE="$work/compat-cron"
RED='' RESET='' YELLOW='' GREEN='' BOLD='' NOTIFY_EMAIL=''
set +u
create_backup_from_settings headless > "$work/generate.log"
set -u
script=$(find "$work/cron_scripts" -type f -print -quit)
hash=$(read_backup_setting "$script" hash)
printf 'unrelated backup\n' > "$work/remote/unrelated_old.tar.gz"
printf 'expired owned backup\n' > "$work/remote/${hash}_old.tar.gz"
touch -d '20 days ago' "$work/remote/unrelated_old.tar.gz" "$work/remote/${hash}_old.tar.gz"
if ! bash "$script" initial; then tail -25 "$LOG_FILE"; exit 1; fi
test -f "$work/remote/unrelated_old.tar.gz"
test ! -e "$work/remote/${hash}_old.tar.gz"
archive=$(find "$work/remote" -name "${hash}_site_*.tar.gz" -print -quit)
RESTORE_TARGET_PATH="$work/restored" RESTORE_PRESERVE_WPCONFIG=''
capture_restore_identity
restore_archive_files "$archive" true "$hash"
cmp "$fixture/wp-includes/version.php" "$work/restored/wp-includes/version.php"
test -z "$(find "$work/restored" -maxdepth 1 -name '*.sql' -print -quit)"
test -s "$RESTORE_SQL_FILE" && test "$(stat -c %a "$RESTORE_SQL_FILE")" = 600
test "$(stat -c %u "$work/restored/wp-config.php")" = "$(stat -c %u "$fixture")"
RESTORE_DB_MODE=explicit RESTORE_DB_NAME="$test_db" RESTORE_DB_USER="$test_db" RESTORE_DB_HOST=localhost
RESTORE_DB_PASS=$(openssl rand -hex 24)
mysql --defaults-extra-file="$admin" -e "CREATE DATABASE \`$test_db\`; CREATE USER '$test_db'@'localhost' IDENTIFIED BY '$RESTORE_DB_PASS'; GRANT ALL ON \`$test_db\`.* TO '$test_db'@'localhost';"
run_restore_db_import full "$script" "$hash"
table_count=$(mysql --defaults-extra-file="$admin" -Nse "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$test_db'")
test "$table_count" -gt 0
test "$(run_wp_cli config get DB_NAME --path="$work/restored")" = "$test_db"
echo 'PASS: generated full backup, owner-isolated files, private SQL, real restore/import, target credentials and job-scoped retention'
