#!/usr/bin/env bash
# Headless --password-file / --db-pass-file: the secret is read from a root-only
# file instead of an argument, which every local user can read in /proc while
# the command runs. Unsafe files are refused.
set -euo pipefail
test "$(id -u)" = 0 || { echo 'Run as root ( the secret file must be owned by root ).' >&2; exit 1; }
source_dir=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d /var/tmp/rclone-password-test.XXXXXXXXXX)
trap 'rm -rf -- "$work"' EXIT
source "$source_dir/lib/locking.sh"
source "$source_dir/lib/headless.sh"
RED='' RESET='' YELLOW='' GREEN='' BOLD='' RESTIC_AVAILABLE=true
resolve_domain_path() { printf '%s' "$work/site"; }
create_backup_from_settings() { printf '%s|%s' "$BACKUP_PASS" "$DB_PASS" > "$work/received"; }
secret='correct horse $(touch MUST-NOT-RUN) "battery"'
(umask 077; printf '%s\n' "$secret" > "$work/restic.txt"; printf '%s' 'db-secret' > "$work/db.txt")
headless() {
    rm -f "$work/received"
    run_headless --domain lab.example --frequency daily --time 02:00 --retention 7 \
        --remote lab --location backups/lab --exclude none --yes "$@" 2> "$work/error"
}

headless --type incremental --password-file "$work/restic.txt"
test "$(cat "$work/received")" = "$secret|"
headless --type database --db-driver mysqldump --db-name lab --db-user lab --db-pass-file "$work/db.txt"
test "$(cat "$work/received")" = '|db-secret'
# The argument form still works for older scripts.
headless --type incremental --password 'from-argument'
test "$(cat "$work/received")" = 'from-argument|'

refused() {
    if headless "$@"; then echo "Accepted: $*" >&2; exit 1; fi
    test ! -e "$work/received"
}
chmod 640 "$work/restic.txt"
refused --type incremental --password-file "$work/restic.txt"           # readable by its group
grep -q 'password-file must be' "$work/error"
chmod 600 "$work/restic.txt"
chown 65534 "$work/restic.txt"
refused --type incremental --password-file "$work/restic.txt"           # not owned by root
chown 0 "$work/restic.txt"
ln -s "$work/restic.txt" "$work/link.txt"
refused --type incremental --password-file "$work/link.txt"             # a link
(umask 077; : > "$work/empty.txt")
refused --type incremental --password-file "$work/empty.txt"            # empty
refused --type incremental --password-file "$work/missing.txt"          # missing
refused --type incremental --password-file "$work/restic.txt" --password other
grep -q 'not both' "$work/error"
test ! -e MUST-NOT-RUN && test ! -e "$work/MUST-NOT-RUN"
echo 'PASS: --password-file and --db-pass-file read root-only files literally and refuse unsafe ones'
