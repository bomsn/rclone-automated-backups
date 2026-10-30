#!/usr/bin/env bash
# Exercise the real restore helper against an isolated, disposable MySQL database.
set -euo pipefail
test "$(id -u)" = 0 || exit 1
admin=${MYSQL_TEST_DEFAULTS:-/etc/mysql/debian.cnf}
source_dir=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d /var/tmp/rclone-restore-test.XXXXXXXXXX)
test_db="rclone_restore_test_$$"
cleanup() {
    local rc=$?
    trap - EXIT
    mysql --defaults-extra-file="$admin" -e "DROP DATABASE IF EXISTS \`$test_db\`; DROP USER IF EXISTS '$test_db'@'localhost';" || true
    case "$work" in /var/tmp/rclone-restore-test.*) rm -rf -- "$work" ;; esac
    exit "$rc"
}
trap cleanup EXIT
source "$source_dir/lib/restore.sh"
RED='' YELLOW='' RESET=''
RESTORE_TARGET_PATH="$work" RESTORE_DB_MODE=explicit
RESTORE_DB_NAME="$test_db" RESTORE_DB_USER="$test_db" RESTORE_DB_HOST=localhost
RESTORE_DB_PASS=$(openssl rand -hex 24)
mysql --defaults-extra-file="$admin" -e "CREATE DATABASE \`$test_db\`; CREATE USER '$test_db'@'localhost' IDENTIFIED BY '$RESTORE_DB_PASS'; GRANT ALL ON \`$test_db\`.* TO '$test_db'@'localhost';"
if run_restore_db_import full unused testhash; then
    echo 'Missing SQL incorrectly reported success.' >&2
    exit 1
fi
printf 'THIS IS INVALID SQL;\n' > "$work/testhash_invalid.sql"
if run_restore_db_import full unused testhash; then
    echo 'Invalid SQL incorrectly reported success.' >&2
    exit 1
fi
test -f "$work/testhash_invalid.sql"
rm "$work/testhash_invalid.sql"
printf "CREATE TABLE roundtrip (value varchar(32)); INSERT INTO roundtrip VALUES ('verified');\n" > "$work/testhash_valid.sql"
run_restore_db_import full unused testhash
test ! -e "$work/testhash_valid.sql"
test "$(mysql --defaults-extra-file="$admin" -Nse "SELECT value FROM \`$test_db\`.roundtrip")" = verified
echo 'PASS: missing dump fails, failed SQL remains for diagnosis, successful SQL imports and cleans up'
