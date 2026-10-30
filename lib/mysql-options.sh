#!/usr/bin/env bash

# MySQL option files interpret quotes, comments and backslash escapes. Quote
# every credential so a valid password cannot change the connection settings.
mysql_option_quote() {
    local value="$1"
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//$'\n'/\\n}
    value=${value//$'\r'/\\r}
    value=${value//$'\t'/\\t}
    printf '"%s"' "$value"
}

mysql_client_options() {
    printf '[client]\nuser=%s\npassword=%s\nhost=%s\n' \
        "$(mysql_option_quote "$1")" "$(mysql_option_quote "$2")" "$(mysql_option_quote "$3")"
}
