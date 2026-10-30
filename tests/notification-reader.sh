#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../lib/notifications.sh"
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
for value in 'NOTIFY_EMAIL=ops+backup@example.com' 'NOTIFY_EMAIL="ops+backup@example.com"'; do
    printf '%s\n' "$value" > "$work/definitions"
    test "$(read_notification_email "$work/definitions")" = ops+backup@example.com
done
for value in 'NOTIFY_EMAIL=' 'NOTIFY_EMAIL=$(touch never-execute)' 'NOTIFY_EMAIL="bad@example.com' 'NOTIFY_EMAIL=a@example.com b@example.com'; do
    printf '%s\n' "$value" > "$work/definitions"
    if read_notification_email "$work/definitions"; then
        echo 'Unsafe email definition was accepted' >&2
        exit 1
    fi
done
printf 'NOTIFY_EMAIL=ops@example.com\nNOTIFY_EMAIL=other@example.com\n' > "$work/definitions"
if read_notification_email "$work/definitions"; then exit 1; fi
ln -s "$work/definitions" "$work/link"
if read_notification_email "$work/link"; then exit 1; fi
echo 'PASS: current and historical email definitions; unsafe values rejected without execution'
