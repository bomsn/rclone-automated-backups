#!/bin/bash

# WordPress configuration and MU plugins are site-controlled executable PHP.
# A privileged backup/restore process must never bootstrap them as root.
wp_runtime_path() {
    local argument next=false result=''
    for argument in "$@"; do
        if [ "$next" = true ]; then result="$argument"; next=false; continue; fi
        case "$argument" in
            --path=*) result="${argument#--path=}" ;;
            --path) next=true ;;
        esac
    done
    [ -n "$result" ] && [ "$next" = false ] || return 1
    realpath -e -- "$result"
}

run_wp_cli_as() {
    local wp_user="$1"; shift
    local uid site_path argument
    uid=$(id -u "$wp_user") || return 1
    [ "$uid" -ne 0 ] || { echo 'Refusing to execute site PHP as root.' >&2; return 1; }
    site_path=$(wp_runtime_path "$@") || return 1
    local -a arguments=() command=()
    for argument in "$@"; do
        [ "$argument" = --allow-root ] || arguments+=("$argument")
    done
    if [ -n "${WP_PHP_BIN:-}" ]; then command=("$WP_PHP_BIN" "$WP_CLI_PATH");
    else command=("$WP_CLI_PATH"); fi
    (
        cd "$site_path" || exit 1
        if [ "$(id -u)" -eq "$uid" ]; then
            "${command[@]}" "${arguments[@]}"
        else
            sudo -u "$wp_user" -- "${command[@]}" "${arguments[@]}"
        fi
    )
}

run_wp_cli() {
    local site_path uid wp_user
    site_path=$(wp_runtime_path "$@") || { echo 'An explicit WordPress --path is required.' >&2; return 1; }
    uid=$(stat -c %u -- "$site_path") || return 1
    if [ "$uid" -eq 0 ] && [ -f "$site_path/wp-config.php" ]; then
        uid=$(stat -c %u -- "$site_path/wp-config.php") || return 1
    fi
    [ "$uid" -ne 0 ] || { echo 'A non-root WordPress site owner is required; restore its ownership before continuing.' >&2; return 1; }
    wp_user=$(getent passwd "$uid" | cut -d: -f1)
    [ -n "$wp_user" ] || return 1
    run_wp_cli_as "$wp_user" "$@"
}
