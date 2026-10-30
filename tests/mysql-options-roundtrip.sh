#!/usr/bin/env bash
# Exercise MariaDB's actual option-file parser with punctuation and whitespace.
set -euo pipefail
admin=${1:?Supply a private administrator defaults file on an isolated lab}
source_dir=$(cd "$(dirname "$0")/.." && pwd)
source "$source_dir/lib/mysql-options.sh"
work=$(mktemp -d /var/tmp/backup-mysql-options.XXXXXXXXXX)
name="backup_options_${RANDOM}_$$"
cleanup() {
    local rc=$?
    trap - EXIT
    mysql --defaults-extra-file="$admin" -e "DROP USER IF EXISTS '$name'@'localhost'; DROP DATABASE IF EXISTS \`$name\`;" >/dev/null
    rm -f -- "$work/client.cnf" "$work/dump.sql"
    rmdir -- "$work"
    exit "$rc"
}
trap cleanup EXIT
password=$' leading # ; quote" single\x27 back\\slash\nline\ttab trailing '
sql_password=${password//\'/\'\'}
mysql --defaults-extra-file="$admin" <<SQL
SET SESSION sql_mode='NO_BACKSLASH_ESCAPES';
CREATE DATABASE \`$name\`;
CREATE USER '$name'@'localhost' IDENTIFIED BY '$sql_password';
GRANT ALL ON \`$name\`.* TO '$name'@'localhost';
CREATE TABLE \`$name\`.proof (value INT);
INSERT INTO \`$name\`.proof VALUES (42);
SQL
(umask 077; mysql_client_options "$name" "$password" localhost > "$work/client.cnf")
test "$(mysql --defaults-extra-file="$work/client.cnf" -NBe "SELECT value FROM \`$name\`.proof")" = 42
mysqldump --defaults-extra-file="$work/client.cnf" --single-transaction "$name" > "$work/dump.sql"
grep -q '42' "$work/dump.sql"
echo 'PASS: actual database authentication and dump with quoted, backslash, whitespace and newline credentials'
