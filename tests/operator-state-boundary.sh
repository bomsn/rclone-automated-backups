#!/usr/bin/env bash
# Executable jobs and sourced inventory must remain in an operator-owned tree.
set -euo pipefail
test "$(id -u)" = 0 || exit 1
source_dir=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d /var/tmp/rclone-operator-state.XXXXXXXXXX)
cleanup() {
    local rc=$?
    trap - EXIT
    case "$work" in /var/tmp/rclone-operator-state.*) test ! -L "$work" && rm -rf -- "$work" ;; esac
    exit "$rc"
}
trap cleanup EXIT
chmod 755 "$work"
mkdir "$work/site" "$work/trusted"
chmod 755 "$work/trusted"
chown nobody:nogroup "$work/site"
printf 'touch %q\nDOMAINS=()\nPATHS=()\n' "$work/should-not-execute" > "$work/site/definitions"
chown nobody:nogroup "$work/site/definitions"
source "$source_dir/lib/locking.sh"
if prepare_operator_directory "$work/site/jobs" > "$work/refused.log" 2>&1; then
    echo 'FAIL: website-controlled ancestor accepted' >&2
    exit 1
fi
test ! -e "$work/site/jobs"
prepare_operator_directory "$work/trusted/jobs"
test "$(stat -c %a "$work/trusted")" = 755
test "$(stat -c %a "$work/trusted/jobs")" = 700
before=$(stat -c %a /tmp)
if prepare_operator_directory /tmp > "$work/refused.log" 2>&1; then
    echo 'FAIL: shared writable directory accepted as job storage' >&2
    exit 1
fi
test "$(stat -c %a /tmp)" = "$before"
(cd "$work/site" && RCLONE_BACKUP_STATE_DIR="$work/private" bash "$source_dir/config.sh" --help > "$work/help.log" 2>&1)
test ! -e "$work/should-not-execute"
test -f "$work/private/definitions"
test ! -e "$work/site/cron_scripts"
echo 'PASS: protected job ancestry, private new state, no unsafe working-directory inventory, no shared-directory permission changes'
