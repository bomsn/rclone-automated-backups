#!/usr/bin/env bash
# Restoring a WordPress backup to another site with a restored object-cache drop-in:
#  - `wp option update siteurl` failed ("Could not update option") after search-replace,
#    because the cache still held the old value;
#  - a repeat restore read the destination's previous URL from the cache, skipped the
#    rewrite and finished "successfully" with the copy configured as the live site;
#  - JSON-escaped references (https:\/\/live...) were never rewritten;
#  - the fix flushed the destination's object cache, which on CloudPanel's default
#    Redis ( shared by every site ) emptied every other site's cache too.
set -euo pipefail
source_dir=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d /var/tmp/rclone-url-test.XXXXXXXXXX)
trap 'rm -rf -- "$work"' EXIT
source "$source_dir/lib/restore.sh"
RED='' RESET='' YELLOW='' GREEN='' BOLD=''
dropin="$work/target/wp-content/object-cache.php"
# Stand-in for WP-CLI with a persistent object cache: while the drop-in is in place,
# reads come from the cache when it has the key; search-replace writes the database
# directly (SQL), and option update refuses a value that is already stored, as
# WordPress does. wp-config.php settings are files in $work/config.
run_wp_cli() {
    printf '%s\n' "$*" >> "$work/calls"
    case "$1 $2" in
        "config get")
            [ -f "$work/config/$3" ] || return 1
            cat "$work/config/$3" ;;
        "option get")
            if [ -e "$dropin" ]; then
                [ -f "$work/cache/$3" ] || cp "$work/db/$3" "$work/cache/$3"
                cat "$work/cache/$3"
            else
                cat "$work/db/$3"
            fi ;;
        "option update")
            [ "$(cat "$work/db/$3")" != "$4" ] || return 1
            printf '%s\n' "$4" > "$work/db/$3"
            if [ -e "$dropin" ]; then printf '%s\n' "$4" > "$work/cache/$3"; fi ;;
        "cache flush") rm -f "$work/cache/"* ;;
        "search-replace "*)
            local file
            for file in $SEARCH_REPLACE_REACHES; do sed -i "s#$2#$3#" "$work/db/$file"; done ;;
        *) return 0 ;;
    esac
}
RESTORE_MODE=staging RESTORE_DB_MODE=wpconfig RESTORE_TARGET_PATH="$work/target"
RESTORE_URL_NEW=https://copy.example RESTORE_SOURCE_PATH="$work/target"
# Freshly imported live values; the cache still holds the copy's earlier URL.
start() {
    rm -rf "$work/target" "$work/db" "$work/cache" "$work/config"
    mkdir -p "$work/target/wp-content" "$work/db" "$work/cache" "$work/config"
    : > "$dropin"
    printf 'https://live.example\n' > "$work/db/siteurl"; printf 'https://live.example\n' > "$work/db/home"
    printf 'https://copy.example\n' > "$work/cache/siteurl"; printf 'https://copy.example\n' > "$work/cache/home"
    : > "$work/calls"
    local name
    for name in "$@"; do printf '%s' "${name#*=}" > "$work/config/${name%%=*}"; done
}
rewritten() {
    test "$(cat "$work/db/siteurl")" = https://copy.example && test "$(cat "$work/db/home")" = https://copy.example
}

# 1. A cache with its own key prefix and selective flush: flushed, never bypassed.
#    Search-replace reaches both options: the rewrite runs and no update is attempted.
start WP_REDIS_PREFIX=copy: WP_REDIS_SELECTIVE_FLUSH=1
SEARCH_REPLACE_REACHES='siteurl home' maybe_wp_search_replace > "$work/output"
rewritten
grep -q '^search-replace https://live.example https://copy.example' "$work/calls"
grep -Fq 'search-replace https:\/\/live.example https:\/\/copy.example' "$work/calls"
! grep -q '^option update' "$work/calls" || { echo 'Updated an option search-replace had already changed' >&2; exit 1; }
grep -q '^cache flush' "$work/calls" && test -e "$dropin"

# 2. Search-replace misses one option: it is still set explicitly.
start WP_REDIS_PREFIX=copy: WP_REDIS_SELECTIVE_FLUSH=true
SEARCH_REPLACE_REACHES='siteurl' maybe_wp_search_replace > /dev/null
test "$(cat "$work/db/home")" = https://copy.example
test "$(grep -c '^option update' "$work/calls")" = 1

# 3. A Redis socket only the site can reach is private too.
start WP_REDIS_SCHEME=unix WP_REDIS_PATH="$work/redis/cache.sock"
mkdir -m 750 "$work/redis"
SEARCH_REPLACE_REACHES='siteurl home' maybe_wp_search_replace > /dev/null
rewritten && grep -q '^cache flush' "$work/calls" && test -e "$dropin"

# 4. CloudPanel's default local Redis (no settings), a prefix without selective
#    flush, or a socket other users can reach: never flushed. The drop-in is set
#    aside, so the rewrite reads the database and the copy can't use shared keys.
for settings in '' 'WP_REDIS_PREFIX=copy:' "WP_REDIS_SCHEME=unix WP_REDIS_PATH=$work/open/cache.sock"; do
    # shellcheck disable=SC2086
    start $settings
    mkdir -p -m 755 "$work/open"
    SEARCH_REPLACE_REACHES='siteurl home' maybe_wp_search_replace > "$work/output"
    rewritten
    ! grep -q '^cache flush' "$work/calls" || { echo "Flushed a shared object cache ( $settings )" >&2; exit 1; }
    test ! -e "$dropin" && test -e "$dropin.disabled-by-restore"
    grep -q 'disabled-by-restore' "$work/output"
done
echo 'PASS: restore URL rewrite ignores a stale object cache, covers JSON-escaped URLs, updates only options that still differ and never flushes a shared cache'
