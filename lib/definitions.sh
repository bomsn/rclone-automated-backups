#!/bin/bash

# Definitions file persistence and derived state variables

# Function to save definitions to the file
update_definitions() {

    # Remove leading and trailing spaces from elements and copy to new arrays
    local new_domains=()
    local new_paths=()
    for domain in "${DOMAINS[@]}"; do
        new_domains+=("\"${domain#"${domain%%[![:space:]]*}"}\"") # trip spaces and add inside double quote
    done
    for path in "${PATHS[@]}"; do
        new_paths+=("\"${path#"${path%%[![:space:]]*}"}\"") # trip spaces and add inside double quote
    done

    # Overwrite the definitions file
    cat <<EOL >"$DEFINITIONS_FILE"
# Definitions

# Indexed arrays for domains and paths
EOL

    if [ ${#new_domains[@]} -eq 0 ]; then
        echo "DOMAINS=()" >>"$DEFINITIONS_FILE"
    else
        echo "DOMAINS=(${new_domains[@]})" >>"$DEFINITIONS_FILE"
    fi

    if [ ${#new_paths[@]} -eq 0 ]; then
        echo "PATHS=()" >>"$DEFINITIONS_FILE"
    else
        echo "PATHS=(${new_paths[@]})" >>"$DEFINITIONS_FILE"
    fi

    # Notification settings
    cat <<EOL >>"$DEFINITIONS_FILE"

# Email address for backup failure alerts ( empty = notifications disabled )
NOTIFY_EMAIL="${NOTIFY_EMAIL}"
EOL

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
    local lock_file="/tmp/rclone-automated-backups-by-alikhallad-definitions.lock"
    local i exists=false

    exec 9>"$lock_file"
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
