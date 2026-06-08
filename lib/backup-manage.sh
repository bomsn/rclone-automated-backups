#!/bin/bash

# Automated backup management: list, enable/disable, delete, restore

# Function to manage local automated backups
manage_automated_backups() {

    # Exit on errors within this function
    set -e

    # Clear screen and display a title
    clear_screen
    echo -e "${BOLD}${UNDERLINE}Manage backups > Manage automated backups${RESET}"

    # Check if a backup index is already provided.
    # If index is provided, use it later to automatically display the selected backup instead of showing list of available backups
    backup_already_selected=false
    if [ $# -eq 1 ] && [[ $1 =~ ^[0-9]+$ ]]; then
        # Assign the index to the variable
        backup_already_selected=$1
    fi

    # Initialize arrays to store backup details
    declare -a backup_statuses
    declare -a backup_scripts
    declare -a backup_types
    declare -a backup_cron_expressions
    declare -a backup_hashes
    declare -a backup_names
    declare -a backup_schedules
    declare -a backup_domains
    declare -a backup_paths
    declare -a remote_locations
    declare -a rclone_remotes
    declare -a retention_periods

    # Loop through existing backup scripts under $CRON_SCRIPTS_DIR
    for script_file in "$CRON_SCRIPTS_DIR"/*; do
        if [ -f "$script_file" ]; then

            local script_filename=$(echo "$(basename "$script_file")")
            # Check if there is a line with our script name in either the current
            # or the legacy cron file ( back-compat after the repo rename ).
            local backup_schedule_line=$(grep -hE ".*$script_filename" "$CRON_FILE" "$COMPAT_CRON_FILE" 2>/dev/null | grep -oP '(\S+ ){4}\S+' | head -n1)

            # Check if a valid line was found
            local backup_status="Inactive"
            if [ -n "$backup_schedule_line" ]; then
                backup_status="Active"
            fi

            # Extract other details from the backup script variables
            local backup_type=$(grep -oP '(?<!\w)type="\K[^"]+' "$script_file")                                  # only double quote enclosed values
            local creation_date=$(grep -oP 'creation_date="\K[^"]+' "$script_file")                              # only double quote enclosed values
            local cron_expression=$(grep -oP 'cron_expression="\K[^"]+' "$script_file")                          # only double quote enclosed values
            local backup_hash=$(grep -oP '(?<!\w)hash="\K[^"]+' "$script_file")                                  # only double quote enclosed values
            local backup_domain=$(grep -oP 'domain="\K[^"]+' "$script_file")                                     # only double quote enclosed values
            local backup_path=$(grep -oP 'domain_path="\K[^"]+' "$script_file")                                  # only double quote enclosed values
            local remote_location=$(grep -oP 'remote_backup_location="\K[^"]+' "$script_file")                   # only double quote enclosed values
            local rclone_remote=$(grep -oP 'rclone_remote="\K[^"]+' "$script_file")                              # only double quote enclosed values
            local retention_period=$(grep -oP 'retention_period=("[^"]*"|\S+)' "$script_file" | cut -d '=' -f 2) # Extract value that doesn't have double quotes
            local schedule=$(grep -oP '(?<!\w)schedule="\K[^"]+' "$script_file")                                  # baked schedule, newer backups only
            local schedule_label=$(grep -oP 'schedule_label="\K[^"]+' "$script_file")                             # human-readable schedule, newer backups only

            # Validate the integrity of this script
            local existing_script_prefix="${script_filename%%_*}"
            local generated_script_prefix=$(echo -n "$creation_date-$backup_domain-$cron_expression-$retention_period-$remote_location-$rclone_remote-$backup_type" | md5sum | awk '{print $1}') # used to prefix the backup script

            if [ "$existing_script_prefix" != "$generated_script_prefix" ]; then
                continue # There is no match, move to next iteration
            fi

            # Extract backup_time from the cron_expression
            hour=$(echo "$cron_expression" | awk '{print $2}')
            minute=$(echo "$cron_expression" | awk '{print $1}')
            # Force base-10 interpretation to avoid octal conversion errors with 08 and 09
            backup_time=$(printf "%02d:%02d" "$((10#$hour))" "$((10#$minute))")

            # Determine the backup frequency. Newer backups bake in a "schedule"
            # value; older ones are classified from the cron expression.
            if [ -n "$schedule" ]; then
                case "$schedule" in
                monthly-last) backup_frequency="monthly" ;;
                *) backup_frequency="$schedule" ;;
                esac
            else
                # Extract backup frequency from cron_expression
                IFS=" " read -r -a cron_expression_parts <<<"$cron_expression"
                # Determine the frequency
                day="${cron_expression_parts[2]}"
                month="${cron_expression_parts[3]}"
                day_of_the_week="${cron_expression_parts[4]}"
                if [[ "$day" = "*" && "$month" = "*" && "$day_of_the_week" = "*" ]]; then
                    backup_frequency="daily"
                elif [[ "$day" = "*" && "$month" = "*" ]]; then
                    backup_frequency="weekly"
                else
                    backup_frequency="monthly"
                fi
            fi

            # Prefer the baked human-readable label for display; fall back to the
            # plain frequency for backups created before schedule metadata existed
            local display_schedule="$backup_frequency"
            if [ -n "$schedule_label" ]; then
                display_schedule="$schedule_label"
            fi

            # Store the extracted details in arrays
            backup_statuses+=("$backup_status")
            backup_scripts+=("$script_file")
            backup_types+=("$backup_type")
            backup_cron_expressions+=("$cron_expression")
            backup_hashes+=("$backup_hash")
            backup_names+=("${backup_domain} ${backup_frequency} backup at ${backup_time} to ${rclone_remote}")
            backup_schedules+=("$display_schedule")
            backup_domains+=("$backup_domain")
            backup_paths+=("$backup_path")
            remote_locations+=("$remote_location")
            rclone_remotes+=("$rclone_remote")
            retention_periods+=("$retention_period")

        fi
    done

    # Check if any backups were found
    if [ "${#backup_names[@]}" -eq 0 ]; then
        echo -e "${YELLOW}The existing backup scripts are either deleted or corrupt, check /cron_scripts folder to confirm.${RESET}"
        return
    fi

    if [ $backup_already_selected == false ]; then
        # Display the list of available backups for selection
        echo -e "${BOLD}${UNDERLINE}Available Backups: ${RESET}"
        for i in "${!backup_names[@]}"; do
            # Prepare a bullet point with a different color depending on backup status
            if [[ "${backup_statuses[i]}" == "Active" ]]; then
                bullet="${GREEN}●${RESET}"
            else
                bullet="${YELLOW}●${RESET}"
            fi
            index=$((i + 1)) # Increment the index by 1
            echo -e "$bullet $index. ${backup_names[i]} [${backup_types[i]}]"
        done

        # Ask the user to select a backup for detailed management
        read -p "$(echo -e "${BOLD}${BLUE}Select a backup to manage (or 'q' to go back): ${RESET}")" choice

        if [ "${choice,,}" == "q" ]; then
            clear_screen "force"
            return
        fi

        # Validate the user's choice
        if [[ ! "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -le 0 ] || [ "$choice" -gt "${#backup_names[@]}" ]; then
            echo -e "${RED}Invalid choice. Please enter a valid number.${RESET}"
            return
        fi
    fi

    # Display details and management options for the selected backup

    local selected_backup_index
    if [ $backup_already_selected != false ]; then
        selected_backup_index=$backup_already_selected
    else
        selected_backup_index=$((choice - 1))
    fi

    local selected_backup_status="${backup_statuses[selected_backup_index]}"
    local selected_backup_script="${backup_scripts[selected_backup_index]}"
    local selected_backup_type="${backup_types[selected_backup_index]}"
    local selected_backup_cron_expression="${backup_cron_expressions[selected_backup_index]}"
    local selected_backup_hash="${backup_hashes[selected_backup_index]}"
    local selected_backup_name="${backup_names[selected_backup_index]}"
    local selected_backup_schedule="${backup_schedules[selected_backup_index]}"
    local selected_backup_domain="${backup_domains[selected_backup_index]}"
    local selected_backup_path="${backup_paths[selected_backup_index]}"
    local selected_backup_remote_location="${remote_locations[selected_backup_index]}"
    local selected_backup_rclone_remote="${rclone_remotes[selected_backup_index]}"
    local selected_backup_retention_period="${retention_periods[selected_backup_index]}"

    save_cursor_position "alt" # Save cursor position ( used for enable/disable/return to clear everything up to this point )
    # Only clear screen if the a backup is not already selected
    if [ $backup_already_selected == false ]; then
        clear_screen "force"
    fi

    echo -e "${BOLD}${UNDERLINE}Available Backups > Backup Details:${RESET}"
    if [ "$selected_backup_status" == "Active" ]; then
        echo -e "${BOLD}Backup Status:${RESET} ${GREEN}$selected_backup_status${RESET}"
    else
        echo -e "${BOLD}Backup Status:${RESET} ${YELLOW}$selected_backup_status${RESET}"
    fi
    echo -e "${BOLD}Backup Type:${RESET} ${BLUE}$selected_backup_type${RESET}"
    echo -e "${BOLD}Backup ID:${RESET} $selected_backup_hash"
    echo -e "${BOLD}Backup Name:${RESET} ${RESET} $selected_backup_name"
    echo -e "${BOLD}Backup Schedule:${RESET} $selected_backup_schedule"
    echo -e "${BOLD}Backup Domain:${RESET} $selected_backup_domain"
    echo -e "${BOLD}Backup Path:${RESET} $selected_backup_path"
    echo -e "${BOLD}Remote Location:${RESET} $selected_backup_remote_location"
    echo -e "${BOLD}Rclone Remote:${RESET} $selected_backup_rclone_remote"
    echo -e "${BOLD}Retention Period:${RESET} $selected_backup_retention_period days"
    echo ""

    save_cursor_position

    # Save the original PS3 value
    local original_ps3="$PS3"
    while true; do
        # Ask the user for further actions (e.g., delete, enable, disable)
        options=("Enable" "Delete" "View/restore remote backups" "Return to the previous menu")
        if [ "$selected_backup_status" == "Active" ]; then
            options=("Disable" "Delete" "View/restore remote backups" "Return to the previous menu")
        fi

        PS3="$(echo -e "${BOLD}${BLUE}Type the desired option number to continue: ${RESET}")"
        select choice in "${options[@]}"; do
            case "$choice" in
            "Disable")
                # Construct the cron pattern and remove the associated cron line from
                # whichever cron file holds it ( current or legacy ).
                cron_pattern="^${selected_backup_cron_expression//\*/\\*} .*$(basename "$selected_backup_script")"
                [ -f "$CRON_FILE" ] && sudo sed -i "/$cron_pattern/d" "$CRON_FILE"
                [ -f "$COMPAT_CRON_FILE" ] && sudo sed -i "/$cron_pattern/d" "$COMPAT_CRON_FILE"

                restore_cursor_position "alt"
                clear_screen "force"
                echo -e "${BOLD}${GREEN}'$selected_backup_name'${RESET} ${GREEN}has been disabled successfully.${RESET}"
                manage_automated_backups "$selected_backup_index" # Reload this function with the current backup pre-selected
                return
                ;;
            "Enable")
                echo "$selected_backup_cron_expression root /bin/bash $PWD/$selected_backup_script" >>"$CRON_FILE"

                restore_cursor_position "alt"
                clear_screen "force"
                echo -e "${BOLD}${GREEN}'$selected_backup_name'${RESET} ${GREEN}has been enabled successfully.${RESET}"
                manage_automated_backups "$selected_backup_index" # Reload this function with the current backup pre-selected
                return
                ;;
            "Delete")
                echo ""
                echo -e "${RED_BG}---------------------------------------------------------------------------${RESET}"
                echo -e "${RED_BG}--------------------------- PROCEED WITH CAUTION --------------------------${RESET}"
                echo -e "${RED_BG}---------------------------------------------------------------------------${RESET}"
                echo -e "${RED_BG}-------------- If you choose to delete this automated backup --------------${RESET}"
                echo -e "${RED_BG}----------- you'll lose access to the backup restoration feature ----------${RESET}"
                echo -e "${RED_BG}---------- and any management features associated with the backup ---------${RESET}"
                echo -e "${RED_BG}---------------------------------------------------------------------------${RESET}"
                echo ""
                echo -e "${BOLD}${YELLOW}NOTE: ${RESET}You backup files on the remote server will not be effected.${RESET}"
                echo ""

                # Confirm with the user before deleting the backup
                read -p "$(echo -e "${BOLD}${RED}Choose an action (c: Confirm deletion, b: Bail out): ${RESET}")" confirm
                if [ "${confirm,,}" == "c" ]; then
                    # Remove the backup script file
                    sudo rm -f "$selected_backup_script"

                    # Construct the cron pattern and remove the associated cron line from
                    # whichever cron file holds it ( current or legacy ).
                    cron_pattern="^${selected_backup_cron_expression//\*/\\*} .*$(basename "$selected_backup_script")"
                    [ -f "$CRON_FILE" ] && sudo sed -i "/$cron_pattern/d" "$CRON_FILE"
                    [ -f "$COMPAT_CRON_FILE" ] && sudo sed -i "/$cron_pattern/d" "$COMPAT_CRON_FILE"

                    clear_screen "force"
                    echo -e "${BOLD}${GREEN}'$selected_backup_name'${RESET} ${GREEN}has been deleted successfully.${RESET}"
                    update_definitions_state
                    manage_automated_backups
                    return

                else
                    restore_cursor_position
                    echo -e "${BOLD}${YELLOW}'$selected_backup_name'${RESET} ${YELLOW}deletion has been aborted.${RESET}"
                    echo ""
                fi
                ;;
            "View/restore remote backups")

                if [ $selected_backup_type == "incremental" ]; then

                    echo ""
                    echo -e "${YELLOW}Pulling remote incremental backups ...${RESET}"
                    echo ""

                    # Extract repo password from backup file ( may not have double quotes )
                    local restic_password=$(grep -oP 'restic_password=("[^"]*"|\S+)' "$selected_backup_script" | cut -d '=' -f 2)

                    # List existing snapshots
                    sudo RESTIC_PASSWORD="${restic_password}" restic -r "rclone:${selected_backup_rclone_remote}:${selected_backup_remote_location}" snapshots

                    # Ask the user to select a backup for restoration
                    read -p "$(echo -e "${BOLD}${BLUE}Enter the ID of the backup you'd like to restore ( or q to go back ): ${RESET}")" selected_remote_backup

                    # Go back if the user typed q
                    if [ "${selected_remote_backup,,}" == "q" ]; then
                        restore_cursor_position
                        break # break out of the select statement to restart the while loop
                    fi

                    # Confirm with the user before restoring the backup
                    echo ""
                    echo -e "You selected: ${BOLD}$selected_remote_backup${RESET}"
                    echo -e "Choose a restore approach:"
                    echo -e "${BOLD}${YELLOW}1. ${RESET}Restore only"
                    echo -e "${BOLD}${YELLOW}2. ${RESET}Clear and restore"

                    read -p "$(echo -e "${BOLD}${BLUE}Enter the number of your choice (1/2)${RESET} ${BLUE}( or q to go back ): ${RESET}")" restore_approach_choice

                    # Go back if the user typed q
                    if [ "${restore_approach_choice,,}" == "q" ]; then
                        restore_cursor_position
                        break # break out of the select statement to restart the while loop
                    fi

                    # Handle user restore choice
                    if [[ $restore_approach_choice == "1" || $restore_approach_choice == "2" ]]; then
                        restore_cursor_position

                        # Show a pre-restore backup notice
                        echo ""
                        echo -e "${YELLOW}Taking a pre-restore backup ...${RESET}"
                        # Take a backup using backup script with the arg "restore" to indicate this is a pre-restore backup
                        # Abort the restore if the pre-restore backup did not succeed ( protects the live site )
                        if ! sudo bash "$selected_backup_script" "restore"; then
                            restore_cursor_position
                            echo -e "${RED}Pre-restore backup failed. Restore aborted to protect your site.${RESET}"
                            echo ""
                            break
                        fi

                        # Clear the destination folder if "clear and restore is selected"
                        if [[ $restore_approach_choice == "2" ]]; then
                            sudo rm -rf "${selected_backup_path%/}"/*
                        fi

                        # Show a restoration notice
                        echo ""
                        echo -e "${YELLOW}Restoring${RESET} ${BOLD}${YELLOW}$selected_remote_backup${RESET} ${YELLOW}to:${RESET} ${BOLD}${YELLOW}$selected_backup_path${RESET}"

                        # Restore to the same backed up path
                        # Use --target to manipulate the destination
                        # Use --include to only include specific folder or file from snapshot
                        # use ":path/to/folder" after the snapshot ID to restore the content of a specific folder directly
                        sudo RESTIC_PASSWORD="${restic_password}" restic -r "rclone:${selected_backup_rclone_remote}:${selected_backup_remote_location}" restore $selected_remote_backup --target "/"
                    else
                        restore_cursor_position
                        echo -e "${YELLOW}restore has been aborted.${RESET}"
                        echo ""
                    fi
                elif [ "$selected_backup_type" == "database" ]; then

                    echo ""
                    echo -e "${YELLOW}Pulling remote database backups count & total size...${RESET}"

                    # Show backups size and count
                    echo ""
                    sudo rclone size "${selected_backup_rclone_remote}":"${selected_backup_remote_location}" --include "${selected_backup_hash}_*"

                    echo ""
                    echo -e "${YELLOW}Pulling remote database backups list...${RESET}"

                    # Capture the list of backup files
                    local backup_list_output=$(sudo rclone ls "${selected_backup_rclone_remote}":"${selected_backup_remote_location}" --include "${selected_backup_hash}_*")

                    # Check if the backup list is empty
                    if [ -z "$backup_list_output" ]; then
                        restore_cursor_position
                        echo -e "${YELLOW}No remote database backups found.${RESET}"
                        echo ""
                        break # break out of the select statement to restart the while loop
                    fi

                    # Capture the list of remote backup files
                    local remote_backup_files=()
                    local remote_backup_lines=()
                    while IFS= read -r line; do
                        # Remove leading spaces from the line
                        line="${line#"${line%%[![:space:]]*}"}"

                        # Extract the size and filename from the line
                        local remote_backup_size="${line%% *}" # Extract size (everything before the first space)
                        local remote_backup_name="${line#* }"  # Extract filename (everything after the first space)

                        # Remove the MD5 prefix from remote_backup_name
                        local noprefix_remote_backup_name="${remote_backup_name#*_}"

                        # Extract the date and time from the filename ( database backups end in .sql.gz )
                        if [[ "$noprefix_remote_backup_name" =~ ([0-9]{2}-[0-9]{2}-[0-9]{4})_([0-9]{2}-[0-9]{2}).*\.sql\.gz ]]; then
                            backup_file_date="${BASH_REMATCH[1]}"
                            backup_file_time="${BASH_REMATCH[2]//-/:}"

                            # Format the time to display in 12-hour format with AM/PM
                            backup_file_time=$(date -d "$backup_file_time" +"%I:%M%p")

                            # Format the size in a human-readable format (MB, GB, etc.)
                            backup_size_readable=$(numfmt --to=iec --suffix=B --format="%.2f" "$remote_backup_size")

                            # Add the formatted line to the remote_backup_files array
                            remote_backup_files+=("$remote_backup_name")
                            remote_backup_lines+=("$backup_file_date $backup_file_time $backup_size_readable $noprefix_remote_backup_name")
                        fi
                    done <<<"$backup_list_output"

                    # Display the backup list as a table with aligned headers
                    echo ""
                    echo -e "${BOLD}${YELLOW}#   Date        Time     Size     Name${RESET}"
                    # Calculate the maximum length of the index numbers to align them properly
                    local max_index_length="${#remote_backup_lines[@]}"
                    while ((max_index_length > 0)); do
                        max_index_length=$((max_index_length / 10))
                        local index_length=$((index_length + 1))
                    done

                    for ((i = 0; i < ${#remote_backup_lines[@]}; i++)); do
                        # Calculate the padding for the index numbers
                        local padding_length=$((index_length - ${#i}))
                        local padding=""
                        for ((j = 0; j < padding_length; j++)); do
                            padding+=" "
                        done
                        local item_index=$((i + 1))
                        echo -e "${BOLD}${YELLOW}${padding}${item_index}. ${RESET}${remote_backup_lines[i]}"
                    done | column -t

                    # Ask the user to select a backup for restoration
                    read -p "$(echo -e "${BOLD}${BLUE}Enter the number of the backup to restore (1-${#remote_backup_lines[@]}) ${BLUE}( or q to go back ): ${RESET}")" restore_choice

                    # Go back if the user typed q
                    if [ "${restore_choice,,}" == "q" ]; then
                        restore_cursor_position
                        break # break out of the select statement to restart the while loop
                    fi

                    # Validate the user's choice
                    if [[ ! "$restore_choice" =~ ^[0-9]+$ ]] || [ "$restore_choice" -lt 1 ] || [ "$restore_choice" -gt "${#remote_backup_lines[@]}" ]; then
                        restore_cursor_position
                        echo -e "${RED}Invalid choice. Please enter a valid number.${RESET}"
                        break # break out of the select statement to restart the while loop
                    fi

                    # Get the selected backup based on the user's choice
                    local selected_remote_backup="${remote_backup_files[restore_choice - 1]}"

                    # Confirm with the user before restoring the database
                    echo ""
                    echo -e "You selected: ${BOLD}$selected_remote_backup${RESET}"
                    echo -e "${BOLD}${YELLOW}NOTE: ${RESET}${YELLOW}This overwrites the live database for '${selected_backup_domain}'. Site files are NOT touched.${RESET}"
                    read -p "$(echo -e "${BOLD}${BLUE}Proceed with the database restore? (y/n)${RESET} ${BLUE}( or q to go back ): ${RESET}")" db_restore_confirm

                    # Go back if the user typed q
                    if [ "${db_restore_confirm,,}" == "q" ]; then
                        restore_cursor_position
                        break # break out of the select statement to restart the while loop
                    fi

                    # Handle the user's restore choice
                    if [[ "${db_restore_confirm,,}" == "y" || "${db_restore_confirm,,}" == "yes" ]]; then
                        restore_cursor_position

                        # Show a pre-restore backup notice
                        echo ""
                        echo -e "${YELLOW}Taking a pre-restore database backup ...${RESET}"
                        # Take a backup using backup script with the arg "restore" to indicate this is a pre-restore backup
                        # Abort the restore if the pre-restore backup did not succeed ( protects the live database )
                        if ! sudo bash "$selected_backup_script" "restore"; then
                            restore_cursor_position
                            echo -e "${RED}Pre-restore backup failed. Restore aborted to protect your database.${RESET}"
                            echo ""
                            break
                        fi

                        # Show a restoration notice
                        echo ""
                        echo -e "${YELLOW}Restoring ${RESET}${BOLD}${YELLOW}$selected_remote_backup${RESET} ${YELLOW}to${RESET} ${BOLD}${YELLOW}$selected_backup_domain${RESET}"
                        # Pull the compressed database backup from remote
                        sudo rclone copyto --progress "${selected_backup_rclone_remote}":"${selected_backup_remote_location}${selected_remote_backup}" "${TMP_DIR}/${selected_remote_backup}.tmp"

                        # Decompress the dump into the site path so the shared import step below picks it up
                        sudo bash -c "gunzip -c '${TMP_DIR}/${selected_remote_backup}.tmp' > '${selected_backup_path%/}/${selected_remote_backup%.gz}'"
                        sudo rm "${TMP_DIR}/${selected_remote_backup}.tmp"

                    else
                        restore_cursor_position
                        echo -e "${BOLD}${YELLOW}'$selected_remote_backup'${RESET} ${YELLOW}restoration has been aborted.${RESET}"
                        echo ""
                        break
                    fi
                else

                    echo ""
                    echo -e "${YELLOW}Pulling remote backups count & total size...${RESET}"

                    # Show backups size and count
                    echo ""
                    sudo rclone size "${selected_backup_rclone_remote}":"${selected_backup_remote_location}" --include "${selected_backup_hash}_*"

                    echo ""
                    echo -e "${YELLOW}Pulling remote backups list...${RESET}"

                    # Capture the list of backup files
                    local backup_list_output=$(sudo rclone ls "${selected_backup_rclone_remote}":"${selected_backup_remote_location}" --include "${selected_backup_hash}_*")

                    # Check if the backup list is empty
                    if [ -z "$backup_list_output" ]; then
                        restore_cursor_position
                        echo -e "${YELLOW}No remote backups found.${RESET}"
                        echo ""
                        break # break out of the select statement to restart the while loop
                    fi

                    # Capture the list of remote backup files
                    local remote_backup_files=()
                    local remote_backup_lines=()
                    while IFS= read -r line; do
                        # Remove leading spaces from the line
                        line="${line#"${line%%[![:space:]]*}"}"

                        # Extract the size and filename from the line
                        local remote_backup_size="${line%% *}" # Extract size (everything before the first space)
                        local remote_backup_name="${line#* }"  # Extract filename (everything after the first space)

                        # Remove the MD5 prefix from remote_backup_name
                        local noprefix_remote_backup_name="${remote_backup_name#*_}"

                        # Extract the date and time from the filename
                        if [[ "$noprefix_remote_backup_name" =~ ([0-9]{2}-[0-9]{2}-[0-9]{4})_([0-9]{2}-[0-9]{2}).*\.tar\.gz ]]; then
                            backup_file_date="${BASH_REMATCH[1]}"
                            backup_file_time="${BASH_REMATCH[2]//-/:}"

                            # Format the time to display in 12-hour format with AM/PM
                            backup_file_time=$(date -d "$backup_file_time" +"%I:%M%p")

                            # Format the size in a human-readable format (MB, GB, etc.)
                            backup_size_readable=$(numfmt --to=iec --suffix=B --format="%.2f" "$remote_backup_size")

                            # Increment the index for numbering the options
                            if [ $index == 1 ]; then
                                backup_file_date="$backup_file_date-15455"
                            fi
                            # Add the formatted line to the remote_backup_files array
                            remote_backup_files+=("$remote_backup_name")
                            remote_backup_lines+=("$backup_file_date $backup_file_time $backup_size_readable $noprefix_remote_backup_name")
                        fi
                    done <<<"$backup_list_output"

                    # Display the backup list as a table with aligned headers
                    echo ""
                    echo -e "${BOLD}${YELLOW}#   Date        Time     Size     Name${RESET}"
                    # Calculate the maximum length of the index numbers to align them properly
                    local max_index_length="${#remote_backup_lines[@]}"
                    while ((max_index_length > 0)); do
                        max_index_length=$((max_index_length / 10))
                        local index_length=$((index_length + 1))
                    done

                    for ((i = 0; i < ${#remote_backup_lines[@]}; i++)); do
                        # Calculate the padding for the index numbers
                        local padding_length=$((index_length - ${#i}))
                        local padding=""
                        for ((j = 0; j < padding_length; j++)); do
                            padding+=" "
                        done
                        local item_index=$((i + 1))
                        echo -e "${BOLD}${YELLOW}${padding}${item_index}. ${RESET}${remote_backup_lines[i]}"
                    done | column -t

                    # Ask the user to select a backup for restoration
                    read -p "$(echo -e "${BOLD}${BLUE}Enter the number of the backup to restore (1-${#remote_backup_lines[@]}) ${BLUE}( or q to go back ): ${RESET}")" restore_choice

                    # Validate the user's choice
                    if [[ ! "$restore_choice" =~ ^[0-9]+$ ]] || [ "$restore_choice" -lt 1 ] || [ "$restore_choice" -gt "${#remote_backup_lines[@]}" ]; then
                        restore_cursor_position
                        echo -e "${RED}Invalid choice. Please enter a valid number.${RESET}"
                        break # break out of the select statement to restart the while loop
                    fi

                    # Go back if the user typed q
                    if [ "${restore_choice,,}" == "q" ]; then
                        restore_cursor_position
                        break # break out of the select statement to restart the while loop
                    fi

                    # Get the selected backup based on the user's choice
                    local selected_remote_backup="${remote_backup_files[restore_choice - 1]}"

                    # Confirm with the user before restoring the backup
                    echo ""
                    echo -e "You selected: ${BOLD}$selected_remote_backup${RESET}"
                    echo -e "Choose a restore approach:"
                    echo -e "${BOLD}${YELLOW}1. ${RESET}Restore only"
                    echo -e "${BOLD}${YELLOW}2. ${RESET}Clear and restore"

                    read -p "$(echo -e "${BOLD}${BLUE}Enter the number of your choice (1/2)${RESET} ${BLUE}( or q to go back ): ${RESET}")" restore_approach_choice
                    # Go back if the user typed q
                    if [ "${restore_approach_choice,,}" == "q" ]; then
                        restore_cursor_position
                        break # break out of the select statement to restart the while loop
                    fi

                    # Handle user restore choice
                    if [[ $restore_approach_choice == "1" || $restore_approach_choice == "2" ]]; then
                        restore_cursor_position

                        # Show a pre-restore backup notice
                        echo ""
                        echo -e "${YELLOW}Taking a pre-restore backup ...${RESET}"
                        # Take a backup using backup script with the arg "restore" to indicate this is a pre-restore backup
                        # Abort the restore if the pre-restore backup did not succeed ( protects the live site )
                        if ! sudo bash "$selected_backup_script" "restore"; then
                            restore_cursor_position
                            echo -e "${RED}Pre-restore backup failed. Restore aborted to protect your site.${RESET}"
                            echo ""
                            break
                        fi

                        # Show a restoration notice
                        echo ""
                        echo -e "${YELLOW}Restoring ${RESET}${BOLD}${YELLOW}$selected_remote_backup${RESET} ${YELLOW}to${RESET} ${BOLD}${YELLOW}$selected_backup_path${RESET}"
                        # Pull the backup from remote
                        sudo rclone copyto --progress "${selected_backup_rclone_remote}":"${selected_backup_remote_location}${selected_remote_backup}" "${TMP_DIR}/${selected_remote_backup}.tmp"

                        # Handle "Clear and restore" option
                        if [ $restore_approach_choice == "2" ]; then
                            sudo rm -rf "${selected_backup_path%/}"/*
                        fi

                        # Unzip the backup file inside the destination folder
                        sudo tar -xzf "${TMP_DIR}/${selected_remote_backup}.tmp" -C "$selected_backup_path"
                        sudo rm "${TMP_DIR}/${selected_remote_backup}.tmp"

                    else
                        restore_cursor_position
                        echo -e "${BOLD}${YELLOW}'$selected_remote_backup'${RESET} ${YELLOW}restoration has been aborted.${RESET}"
                        echo ""
                    fi
                fi

                # Show a db import notice
                echo ""
                echo -e "${YELLOW}Importing the database ...${RESET}"
                # Now import the database using wp cli and delete it afterwards
                local wp_owner=$(sudo stat -c "%U" ${selected_backup_path})                                                # get WordPress folder owner
                local sql_file=$(find "$selected_backup_path" -type f -name "*${selected_backup_hash}_*.sql" -print -quit) # find the sql file path
                run_wp_cli_as "${wp_owner}" db import "${sql_file}" --path="${selected_backup_path}" --skip-plugins --skip-themes          # import db
                sudo rm "${sql_file}"                                                                                      # Delete the SQL file after it's been imported

                clear_screen "force"
                # Show a success message
                echo -e "${BOLD}${GREEN}Restore successfully completed.${RESET}"
                echo ""
                manage_automated_backups
                return
                ;;
            "Return to the previous menu")
                restore_cursor_position "alt"
                clear_screen "force"
                manage_automated_backups
                return
                ;;
            *)
                restore_cursor_position
                echo -e "${RED}Invalid action. Please choose a valid action.${RESET}"
                ;;
            esac
            break
        done
    done

    # Restore the original PS3 value
    PS3="$original_ps3"
}
