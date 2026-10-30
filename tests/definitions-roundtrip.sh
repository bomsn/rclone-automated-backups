#!/usr/bin/env bash
set -euo pipefail
source_dir=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
source "$source_dir/lib/definitions.sh"
# The state refresher probes rclone; this test targets inventory serialization.
update_definitions_state() { :; }
DEFINITIONS_FILE="$work/definitions"
DOMAINS=('one.example' 'two.example')
PATHS=('/home/site with spaces' '/home/literal$(touch SHOULD-NOT-EXIST)`touch ALSO-NOT`"quote')
NOTIFY_EMAIL='literal$(touch MAIL-NOT)"@example.invalid'
original_path=${PATHS[1]}
original_email=$NOTIFY_EMAIL
cd "$work"
update_definitions
test "$(stat -c %a "$DEFINITIONS_FILE")" = 600
unset DOMAINS PATHS NOTIFY_EMAIL
source "$DEFINITIONS_FILE"
test "${PATHS[1]}" = "$original_path"
test "$NOTIFY_EMAIL" = "$original_email"
test ! -e SHOULD-NOT-EXIST
test ! -e ALSO-NOT
test ! -e MAIL-NOT
DOMAINS=() PATHS=() NOTIFY_EMAIL=''
update_definitions
source "$DEFINITIONS_FILE"
test "${#DOMAINS[@]}" = 0
test "${#PATHS[@]}" = 0
mv "$DEFINITIONS_FILE" "$work/original"
ln -s "$work/original" "$DEFINITIONS_FILE"
if update_definitions; then
    echo 'Symlink inventory unexpectedly accepted' >&2
    exit 1
fi
echo 'PASS: literal inventory round trip, empty arrays, private mode and symlink rejection'
