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
