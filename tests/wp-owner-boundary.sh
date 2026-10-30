#!/usr/bin/env bash
set -euo pipefail
test "$(id -u)" = 0 || exit 1
fixture=${1:?Supply the disposable WordPress fixture}
source_dir=$(cd "$(dirname "$0")/.." && pwd)
source "$source_dir/lib/wp-runtime.sh"
WP_PHP_BIN=${TEST_PHP_BINARY:-/usr/bin/php8.3}
WP_CLI_PATH=${TEST_WP_CLI_PATH:-/usr/bin/wp}
expected=$(stat -c %u -- "$fixture")
test "$expected" != 0
actual=$(run_wp_cli eval 'echo posix_geteuid();' --path="$fixture" --skip-plugins --skip-themes --allow-root)
test "$actual" = "$expected"
if run_wp_cli_as root eval 'echo posix_geteuid();' --path="$fixture"; then
    echo 'Root PHP execution accepted' >&2; exit 1
fi
if run_wp_cli eval 'echo posix_geteuid();'; then
    echo 'Implicit site path accepted' >&2; exit 1
fi
echo 'PASS: actual WordPress runs as the site owner; root and implicit paths are denied'
