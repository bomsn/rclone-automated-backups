#!/bin/bash

# Read backup metadata as data. Never source a generated job to inspect it.
read_backup_setting() {
    local file="$1" key="$2" encoded value
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
    [ -f "$file" ] && [ ! -L "$file" ] || return 1
    local -a matches=()
    mapfile -t matches < <(sed -n "s/^${key}_b64=//p" "$file")
    if [ "${#matches[@]}" -gt 0 ]; then
        [ "${#matches[@]}" -eq 1 ] || return 1
        encoded="${matches[0]}"
        [[ "$encoded" =~ ^[A-Za-z0-9+/]*={0,2}$ ]] || return 1
        printf '%s' "$encoded" | base64 -d
    else
        # Existing jobs used plain quoted assignments (and unquoted numeric
        # retention). Reading them preserves recovery without executing them.
        value=$(sed -n "s/^${key}=\"\(.*\)\"$/\1/p" "$file")
        if [ -n "$value" ]; then
            printf '%s' "$value"
        else
            sed -n "s/^${key}=\([0-9][0-9]*\)$/\1/p" "$file"
        fi
    fi
}
