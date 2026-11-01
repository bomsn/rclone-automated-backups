#!/usr/bin/env bash
# Restoring a WordPress backup to another site with a restored object-cache drop-in:
#  - `wp option update siteurl` failed ("Could not update option") after search-replace,
#    because the cache still held the old value;
#  - a repeat restore read the destination's previous URL from the cache, skipped the
#    rewrite and finished "successfully" with the copy configured as the live site;
#  - JSON-escaped references (https:\/\/live...) were never rewritten.
set -euo pipefail
source_dir=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d /var/tmp/rclone-url-test.XXXXXXXXXX)
trap 'rm -rf -- "$work"' EXIT
source "$source_dir/lib/restore.sh"
RED='' RESET='' YELLOW='' GREEN='' BOLD=''
mkdir -p "$work/target/wp-content" "$work/db" "$work/cache"
: > "$work/target/wp-content/object-cache.php"
# Stand-in for WP-CLI with a persistent object cache: reads come from the cache when
# it has the key, search-replace writes the database directly (SQL), and option
# update refuses a value that is already stored, as WordPress does.
run_wp_cli() {
    printf '%s\n' "$*" >> "$work/calls"
    case "$1 $2" in
        "option get")
            [ -f "$work/cache/$3" ] || cp "$work/db/$3" "$work/cache/$3"
            cat "$work/cache/$3" ;;
        "option update")
            [ "$(cat "$work/db/$3")" != "$4" ] || return 1
            printf '%s\n' "$4" | tee "$work/db/$3" > "$work/cache/$3" ;;
        "cache flush") rm -f "$work/cache/"* ;;
        "search-replace "*)
            local file
            for file in $SEARCH_REPLACE_REACHES; do sed -i "s#$2#$3#" "$work/db/$file"; done ;;
        *) return 0 ;;
    esac
}
RESTORE_MODE=staging RESTORE_DB_MODE=wpconfig RESTORE_TARGET_PATH="$work/target"
RESTORE_URL_NEW=https://copy.example RESTORE_SOURCE_PATH="$work/target"
start() {  # freshly imported live values; the cache still holds the copy's earlier URL
    printf 'https://live.example\n' > "$work/db/siteurl"; printf 'https://live.example\n' > "$work/db/home"
    printf 'https://copy.example\n' > "$work/cache/siteurl"; printf 'https://copy.example\n' > "$work/cache/home"
    : > "$work/calls"
}

# 1. Search-replace reaches both options: the rewrite runs and no update is attempted.
start
SEARCH_REPLACE_REACHES='siteurl home' maybe_wp_search_replace > "$work/output"
test "$(cat "$work/db/siteurl")" = https://copy.example && test "$(cat "$work/db/home")" = https://copy.example
grep -q '^search-replace https://live.example https://copy.example' "$work/calls"
grep -Fq 'search-replace https:\/\/live.example https:\/\/copy.example' "$work/calls"
! grep -q '^option update' "$work/calls" || { echo 'Updated an option search-replace had already changed' >&2; exit 1; }
grep -q 'object-cache drop-in' "$work/output"

# 2. Search-replace misses one option: it is still set explicitly.
start
SEARCH_REPLACE_REACHES='siteurl' maybe_wp_search_replace > /dev/null
test "$(cat "$work/db/home")" = https://copy.example
test "$(grep -c '^option update' "$work/calls")" = 1
echo 'PASS: restore URL rewrite ignores a stale object cache, covers JSON-escaped URLs and updates only options that still differ'
