#!/bin/bash

# Definitions file persistence and derived state variables
source "$(dirname "${BASH_SOURCE[0]}")/locking.sh"

# Function to save definitions to the file
update_definitions() {
    # This file is sourced by later runs. Serialize values as literal Bash data,
    # and replace atomically so interrupted writes cannot truncate the inventory.
    local candidate value
    if [[ -L "$DEFINITIONS_FILE" || ( -e "$DEFINITIONS_FILE" && ! -f "$DEFINITIONS_FILE" ) ]]; then
        echo 'Definitions must be a regular file, not a symbolic link.' >&2
        return 1
    fi
    candidate=$(mktemp "${DEFINITIONS_FILE}.XXXXXXXXXX") || return 1
    if ! (
        set -e
        printf '# Definitions\nDOMAINS=('
        for value in "${DOMAINS[@]}"; do
            printf '%q ' "${value#"${value%%[![:space:]]*}"}"
        done
        printf ')\nPATHS=('
        for value in "${PATHS[@]}"; do
            printf '%q ' "${value#"${value%%[![:space:]]*}"}"
        done
        printf ')\nNOTIFY_EMAIL=%q\n' "${NOTIFY_EMAIL}"
    ) >"$candidate"; then
        rm -f -- "$candidate"
        return 1
    fi
    if ! chmod 600 "$candidate" || ! mv -f -- "$candidate" "$DEFINITIONS_FILE"; then
        rm -f -- "$candidate"
        return 1
    fi

    # Update definitions state variables
    update_definitions_state
}
# Function to update the variables that represent the state of our definitions
update_definitions_state() {

    # Check if DOMAINS array is empty
    ARE_DOMAINS_EMPTY=false
    if [ ${#DOMAINS[@]} -eq 0 ]; then
        ARE_DOMAINS_EMPTY=true
    fi

    # Check if rclone is configured by listing remotes
    IS_RCLONE_CONFIGURED=false
    if sudo rclone listremotes --long 2>&1 | grep -qEv 'NOTICE:'; then
        IS_RCLONE_CONFIGURED=true
    fi

    # Check if there are existing backups in the "cron_scripts" directory
    HAS_AUTOMATED_BACKUPS=false
    if [[ -d "$CRON_SCRIPTS_DIR" && -n "$(find "$CRON_SCRIPTS_DIR" -type f)" ]]; then
        HAS_AUTOMATED_BACKUPS=true
    fi

    # Update ARE_DOMAINS_EMPTY based on the value of HAS_AUTOMATED_BACKUPS to indicate automated backup exist, but domains don't
    if [[ $ARE_DOMAINS_EMPTY == true && $HAS_AUTOMATED_BACKUPS == true ]]; then
        ARE_DOMAINS_EMPTY=-1
    fi
}

# Add a new domain + path to the definitions under an exclusive lock, re-reading
# the on-disk file first. This lets several headless runs each add a different
# site at the same time without losing one another's writes.
persist_new_domain() {
    local new_domain="$1"
    local new_path="$2"
    # Only one config.sh exists on disk at a time, so a single lock file is
    # sufficient ( no compat lock needed after the rename ).
    local lock_file="/tmp/rclone-automated-backups-definitions.lock"
    local i exists=false

    prepare_backup_lock "$lock_file" || return 1
    exec 9<>"$lock_file"
    flock 9

    # Re-read the freshest on-disk state ( a concurrent run may have added sites )
    [ -f "$DEFINITIONS_FILE" ] && source "$DEFINITIONS_FILE"

    # Append the domain only if it is still absent
    for ((i = 0; i < ${#DOMAINS[@]}; i++)); do
        if [ "${DOMAINS[$i]}" == "$new_domain" ]; then
            exists=true
            break
        fi
    done
    if [ "$exists" == false ]; then
        DOMAINS+=("$new_domain")
        PATHS+=("$new_path")
    fi
    update_definitions

    flock -u 9
    exec 9>&-
}
