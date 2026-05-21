#!/bin/bash

# Backup creation: settings collection and backup-script generation

# Detect cache / junk folders and files that are safe to exclude from a backup.
# Echoes newline-separated relative paths that actually exist under <site_path>.
# Pure ( no prompts ) so it can be reused by headless mode.
# It NEVER returns wp-content/uploads or anything under it - the media must stay.
detect_excludes() {
    local site_path="${1%/}"
    local -a found=()
    local seen=" "
    local candidate entry rel

    # Fixed directory / file candidates ( caches, dependency dirs, known logs )
    local -a fixed=(
        "wp-content/cache"
        "wp-content/debug.log"
        "node_modules"
        "wp-content/node_modules"
        "wp-content/ai1wm-backups"
        "wp-content/updraft"
        "wp-content/updraftplus"
        "wp-content/backups"
        ".git"
    )
    for candidate in "${fixed[@]}"; do
        if [ -e "$site_path/$candidate" ] && [[ "$seen" != *" $candidate "* ]]; then
            found+=("$candidate")
            seen+="$candidate "
        fi
    done

    # backup* directories directly under wp-content/ ( eg; backup, backups-old )
    if [ -d "$site_path/wp-content" ]; then
        for entry in "$site_path"/wp-content/backup*/; do
            [ -d "$entry" ] || continue
            rel="wp-content/$(basename "$entry")"
            if [[ "$seen" != *" $rel "* ]]; then
                found+=("$rel")
                seen+="$rel "
            fi
        done
    fi

    # *.log files at the site root and directly under wp-content/
    for entry in "$site_path"/*.log "$site_path"/wp-content/*.log; do
        [ -f "$entry" ] || continue
        rel="${entry#"$site_path"/}"
        if [[ "$seen" != *" $rel "* ]]; then
            found+=("$rel")
            seen+="$rel "
        fi
    done

    [ ${#found[@]} -gt 0 ] && printf '%s\n' "${found[@]}"
}

# Interactive exclude selection. Shows the auto-detected junk locations ( all
# pre-marked for exclusion ), lets the user KEEP any of them, then asks for extra
# free-text paths. The result is written to EXCLUDED_ITEMS as the comma-separated
# string the rest of the code already consumes.
review_detected_excludes() {
    local site_path="$1"
    local -a detected=()
    local line i

    if [ -n "$site_path" ]; then
        while IFS= read -r line; do
            [ -n "$line" ] && detected+=("$line")
        done < <(detect_excludes "$site_path")
    fi

    local -a to_exclude=()

    if [ ${#detected[@]} -gt 0 ]; then
        echo ""
        echo -e "${YELLOW}Auto-detected cache / junk locations under this site:${RESET}"
        for ((i = 0; i < ${#detected[@]}; i++)); do
            echo -e "  ${BOLD}$((i + 1)).${RESET} ${detected[i]}"
        done
        echo ""
        echo -e "All of the above will be ${BOLD}excluded${RESET} from the backup."
        read -p "$(echo -e "${BOLD}${BLUE}Enter number(s) to KEEP ( eg; 1,3 ), or press Enter to exclude them all: ${RESET}")" keep_input

        # Strip terminal bracketed-paste markers some terminals add around pasted text
        keep_input="${keep_input//$'\e'/}"
        keep_input="${keep_input//'[200~'/}"
        keep_input="${keep_input//'[201~'/}"
        keep_input="${keep_input#"${keep_input%%[![:space:]]*}"}"
        keep_input="${keep_input%"${keep_input##*[![:space:]]}"}"

        local -a keep_idx=()
        local keep_str
        if [ -n "$keep_input" ]; then
            if keep_str=$(parse_index_selection "$keep_input" "${#detected[@]}"); then
                read -ra keep_idx <<<"$keep_str"
            else
                echo -e "${YELLOW}Selection not understood - excluding all detected locations.${RESET}"
            fi
        fi

        # Exclude every detected location that was not chosen to be kept
        local kept seen_keep=" "
        for kept in "${keep_idx[@]}"; do
            seen_keep+="$kept "
        done
        for ((i = 0; i < ${#detected[@]}; i++)); do
            if [[ "$seen_keep" != *" $((i + 1)) "* ]]; then
                to_exclude+=("${detected[i]}")
            fi
        done
    fi

    # Always offer a free-text prompt for any extra paths to exclude
    local extra
    if [ ${#detected[@]} -gt 0 ]; then
        read -p "$(echo -e "${BOLD}${BLUE}Enter any additional folders to exclude (comma-separated eg; wp-admin, wp-includes; or leave empty for none): ${RESET}")" extra
    else
        read -p "$(echo -e "${BOLD}${BLUE}Enter folders to exclude (comma-separated eg; wp-admin, wp-includes; or leave empty for none): ${RESET}")" extra
    fi
    if [ -n "$extra" ]; then
        local -a extra_arr=()
        IFS=',' read -ra extra_arr <<<"$extra"
        for line in "${extra_arr[@]}"; do
            line="${line#"${line%%[![:space:]]*}"}"
            line="${line%"${line##*[![:space:]]}"}"
            [ -n "$line" ] && to_exclude+=("$line")
        done
    fi

    # Join into the comma-separated string the rest of the code consumes
    local result=""
    for line in "${to_exclude[@]}"; do
        if [ -z "$result" ]; then
            result="$line"
        else
            result="$result, $line"
        fi
    done
    EXCLUDED_ITEMS="$result"
}

# Function to collect the backup settings from the user
collect_backup_settings() {

    echo -e "${BOLD}${YELLOW}Step 1: ${RESET}${YELLOW}configure your backup settings.${RESET}"
    echo ""

    # Save the original PS3 value
    local original_ps3="$PS3"

    # Collect the target domain/site
    PS3="$(echo -e "${BOLD}${BLUE}Select the target domain for this backup: ${RESET}")"
    select BACKUP_DOMAIN in "${DOMAINS[@]}" "none"; do
        if [ "$BACKUP_DOMAIN" == "none" ]; then
            return
        elif [ -n "$BACKUP_DOMAIN" ]; then
            break
        else
            echo -e "${RED}Invalid option. Please select a valid number.${RESET}"
        fi
    done
    PS3="$original_ps3" # Restore the original PS3 value

    # Collect backup type early. A database-only backup never touches site
    # files, so choosing it here lets the file-exclude step be skipped.
    # full        = whole site files + database in one archive
    # incremental = restic-based snapshots of the whole site ( requires restic )
    # database    = database-only backup ( lightweight, ideal for a daily schedule )
    PS3="$(echo -e "${BOLD}${BLUE}Choose backup type: ${RESET}")"
    if [ $RESTIC_AVAILABLE == true ]; then
        select type in "full" "incremental" "database"; do
            case $type in
            full | incremental | database)
                BACKUP_TYPE="$type"
                break
                ;;
            *)
                echo -e "${RED}Invalid option. Please select a valid type.${RESET}"
                ;;
            esac
        done
    else
        select type in "full" "database"; do
            case $type in
            full | database)
                BACKUP_TYPE="$type"
                break
                ;;
            *)
                echo -e "${RED}Invalid option. Please select a valid type.${RESET}"
                ;;
            esac
        done
    fi
    PS3="$original_ps3" # Restore the original PS3 value

    # Collect restic password
    if [ $BACKUP_TYPE == "incremental" ]; then
        echo ""
        echo -e "${YELLOW}A password is required for incremental backups.${RESET}"
        echo -e "${BOLD}${YELLOW}Note 1:${RESET} ${YELLOW}The password is required by restic to take and restore backups.${RESET}"
        echo -e "${BOLD}${YELLOW}Note 2:${RESET} ${YELLOW}The Password will be saved in plain-text inside the backup script for automation.${RESET}"
        echo -e "${BOLD}${YELLOW}Note 3:${RESET} ${YELLOW}If the backup script is deleted, the password record will be lost.${RESET}"
        echo -e "${BOLD}${YELLOW}Note 4:${RESET} ${YELLOW}Make sure to remember your password, if it's lost/forgotten, the incremental backups cannot be restored anywhere.${RESET}"
        echo ""

        while true; do

            read -s -p "$(echo -e "${BOLD}${BLUE}Enter your password: ${RESET}")" BACKUP_PASS
            echo ""
            read -s -p "$(echo -e "${BOLD}${BLUE}Confirm your password: ${RESET}")" BACKUP_CONFIRM_PASS
            echo ""

            if [ "$BACKUP_PASS" == "$BACKUP_CONFIRM_PASS" ]; then
                break
            else
                echo -e "${RED}Passwords do not match. Please try again.${RESET}"
            fi
        done
    fi

    # Collect frequency preference
    PS3="$(echo -e "${BOLD}${BLUE}Choose backup frequency: ${RESET}")"
    select frequency in "daily" "weekly" "monthly" "none"; do
        case $frequency in
        daily | weekly | monthly)
            BACKUP_FREQUENCY="$frequency"
            break
            ;;
        none)
            return
            ;;
        *)
            echo -e "${RED}Invalid option. Please select a valid frequency.${RESET}"
            ;;
        esac
    done
    PS3="$original_ps3" # Restore the original PS3 value

    # Collect the day for weekly / monthly schedules ( a daily job has no "day" )
    BACKUP_DAY=""
    if [ "$BACKUP_FREQUENCY" == "weekly" ]; then
        PS3="$(echo -e "${BOLD}${BLUE}Choose the day of week to run the backup: ${RESET}")"
        select weekday in "Monday" "Tuesday" "Wednesday" "Thursday" "Friday" "Saturday" "Sunday" "none"; do
            case $weekday in
            Monday | Tuesday | Wednesday | Thursday | Friday | Saturday | Sunday)
                BACKUP_DAY="$weekday"
                break
                ;;
            none)
                return
                ;;
            *)
                echo -e "${RED}Invalid option. Please select a valid day.${RESET}"
                ;;
            esac
        done
        PS3="$original_ps3" # Restore the original PS3 value
    elif [ "$BACKUP_FREQUENCY" == "monthly" ]; then
        echo -e "${BLUE}Days 29-31 are not offered: they would silently skip shorter months.${RESET}"
        PS3="$(echo -e "${BOLD}${BLUE}Choose the day of month to run the backup: ${RESET}")"
        local month_day_options=()
        local d
        for ((d = 1; d <= 28; d++)); do month_day_options+=("$d"); done
        month_day_options+=("Last day of month" "none")
        select monthday in "${month_day_options[@]}"; do
            if [ "$monthday" == "none" ]; then
                return
            elif [ "$monthday" == "Last day of month" ]; then
                BACKUP_DAY="last"
                break
            elif [[ "$monthday" =~ ^[0-9]+$ ]] && [ "$monthday" -ge 1 ] && [ "$monthday" -le 28 ]; then
                BACKUP_DAY="$monthday"
                break
            else
                echo -e "${RED}Invalid option. Please select a valid day.${RESET}"
            fi
        done
        PS3="$original_ps3" # Restore the original PS3 value
    fi

    # Collect backup time preference
    echo ""
    echo -e "${YELLOW}Note: backup times use the SERVER's timezone, not your local time.${RESET}"
    echo -e "${BOLD}Server timezone:${RESET} $(timedatectl show -p Timezone --value 2>/dev/null || date +%Z)"
    echo -e "${BOLD}Server current time:${RESET} $(date '+%Y-%m-%d %H:%M:%S %Z')"
    PS3="$(echo -e "${BOLD}${BLUE}Choose backup time: ${RESET}")"
    options=("01:00" "02:00" "03:00" "04:00" "05:00" "06:00" "07:00" "08:00" "09:00" "10:00" "11:00" "12:00" "13:00" "14:00" "15:00" "16:00" "17:00" "18:00" "19:00" "20:00" "21:00" "22:00" "23:00" "00:00" "none")
    select time in "${options[@]}"; do
        case $time in
        "01:00" | "02:00" | "03:00" | "04:00" | "05:00" | "06:00" | "07:00" | "08:00" | "09:00" | "10:00" | "11:00" | "12:00" | "13:00" | "14:00" | "15:00" | "16:00" | "17:00" | "18:00" | "19:00" | "20:00" | "21:00" | "22:00" | "23:00" | "00:00")
            BACKUP_TIME="$time"
            break
            ;;
        "none")
            return
            ;;
        *)
            echo -e "${RED}Invalid option. Please select a valid time.${RESET}"
            ;;
        esac
    done
    PS3="$original_ps3" # Restore the original PS3 value

    # Collect retention period preference
    PS3="$(echo -e "${BOLD}${BLUE}Choose a retention period option: ${RESET}")"
    select retention in "3 days" "7 days" "30 days" "90 days" "180 days" "none"; do
        case $retention in
        "3 days" | "7 days" | "30 days" | "90 days" | "180 days")
            RETENTION_PERIOD="${retention%% *}" # Extract the numeric part
            break
            ;;
        none)
            return
            ;;
        *)
            echo -e "${RED}Invalid option. Please select a valid retention period.${RESET}"
            ;;
        esac
    done
    PS3="$original_ps3" # Restore the original PS3 value

    # Collect excluded folders ( auto-detect cache / junk, then free-text extras ).
    # A database-only backup never touches site files, so the step is skipped.
    if [ "$BACKUP_TYPE" == "database" ]; then
        EXCLUDED_ITEMS=""
    else
        review_detected_excludes "$(resolve_domain_path "$BACKUP_DOMAIN")"
    fi

    # Collect the destination folder path
    echo -e "${BLUE}- if using object based storage (eg; AWS S3, Google Cloud Storage..etc), the backup location should start with the 'bucket' name (eg; bucket/path/to/dir)${RESET}"
    echo -e "${BLUE}- If using SFTP/FTP based storage, use the full path to your backup directory (eg; /home/user/backup_folder)${RESET}"
    read -p "$(echo -e "${BOLD}${BLUE}Enter your backup location: ${RESET}")" REMOTE_BACKUP_LOCATION

    # If `$REMOTE_BACKUP_LOCATION` has a trailing slash, remove it
    if [[ -n "$REMOTE_BACKUP_LOCATION" && "$REMOTE_BACKUP_LOCATION" == */ ]]; then
        REMOTE_BACKUP_LOCATION="${REMOTE_BACKUP_LOCATION%/}"
    fi

    # Make sure all required settings are available, otherwise, re-collect them
    if [[ -z "$BACKUP_DOMAIN" || -z "$BACKUP_FREQUENCY" || -z "$BACKUP_TIME" || -z "$RETENTION_PERIOD" || -z "$BACKUP_TYPE" ]]; then

        clear_screen "force"
        echo -e "${RED}Something is missing, please select your preferences again.${RESET}"
        collect_backup_settings
        return
    fi

    # Ask the user to confirm their settings before proceeding
    echo ""
    echo -e "${YELLOW}Your current backup configurations:${RESET}"
    echo -e "${BOLD}Backup Site:${RESET} $BACKUP_DOMAIN"
    echo -e "${BOLD}Backup Type:${RESET} $BACKUP_TYPE"
    if [ -n "$BACKUP_DAY" ]; then
        echo -e "${BOLD}Backup Frequency:${RESET} $BACKUP_FREQUENCY ( $BACKUP_DAY )"
    else
        echo -e "${BOLD}Backup Frequency:${RESET} $BACKUP_FREQUENCY"
    fi
    echo -e "${BOLD}Backup Time:${RESET} $BACKUP_TIME"
    echo -e "${BOLD}Retention Period:${RESET} $RETENTION_PERIOD days"
    if [ "$BACKUP_TYPE" != "database" ]; then
        echo -e "${BOLD}Excluded Locations:${RESET} $EXCLUDED_ITEMS"
    fi
    echo -e "${BOLD}Remote Backup Location:${RESET} $REMOTE_BACKUP_LOCATION"

    while true; do
        read -p "$(echo -e "${BOLD}${BLUE}Are you sure you want to proceed with the above configurations? (y/n): ${RESET}")" confirm
        case "${confirm,,}" in
        y | yes)
            break
            ;;
        n | no)
            clear_screen "force"
            echo -e "${YELLOW}Please select your preferences again.${RESET}"
            collect_backup_settings
            return
            ;;
        *)
            echo -e "${RED}Please answer y ( yes ) or n ( no ).${RESET}"
            ;;
        esac
    done

}

generate_backup_script() {

    clear_screen

    # Add a title
    if [ $HAS_AUTOMATED_BACKUPS == false ]; then
        echo -e "${BOLD}${UNDERLINE}Create an automated backup${RESET}"
    else
        echo -e "${BOLD}${UNDERLINE}Manage backups > Create a new automated backup${RESET}"
    fi

    # Collect backup settings from user
    collect_backup_settings

    # Generate the backup ( interactive mode ); show the repeat command on success
    if create_backup_from_settings "interactive"; then
        print_repeat_hint
    fi
}

# Generate the backup script and its cron entry from the BACKUP_* globals.
# <mode> is "interactive" ( prompts for the rclone remote and confirms the test
# upload ) or "headless" ( takes the remote from BACKUP_REMOTE and trusts the
# test exit code ). Returns 0 on success, non-zero on any failure.
create_backup_from_settings() {
    local mode="$1"

    # Extract the collected backup settings from the BACKUP_* globals
    local backup_domain="${BACKUP_DOMAIN}"
    local backup_path=""
    local backup_frequency="${BACKUP_FREQUENCY}"
    local backup_day="${BACKUP_DAY}"
    local backup_time="${BACKUP_TIME}"
    local schedule=""
    local schedule_label=""
    local retention_period="${RETENTION_PERIOD}"
    local excluded_items="${EXCLUDED_ITEMS}"
    local remote_backup_location="${REMOTE_BACKUP_LOCATION}/"
    local remote_backup_type="${BACKUP_TYPE}"
    local restic_password=""
    local rclone_remote_name=""
    local rclone_remote_valid=false
    # Lock wait timeout baked into the generated script ( see LOCK_TIMEOUT )
    local lock_timeout="${LOCK_TIMEOUT}"
    # wp-cli phar path, baked in; the script re-resolves PHP itself at run time
    local wp_cli_path="${WP_CLI_PATH}"

    # Pull restic password if an incremental backup is defined
    if [ $remote_backup_type == "incremental" ]; then
        restic_password="${BACKUP_PASS}"
    fi

    # Validate backup_domain
    if [[ ! " ${DOMAINS[@]} " =~ " $backup_domain " ]]; then
        [ "$mode" == "interactive" ] && clear_screen "force"
        echo -e "${RED}A valid domain must be selected from the available options.${RESET}" >&2
        return 1
    else
        # If the domain is valid, populate the backup path
        backup_path=$(resolve_domain_path "$backup_domain")
    fi

    # Validate and sanitize backup_frequency
    if [ -z "$backup_frequency" ] || [[ ! "$backup_frequency" =~ ^(daily|weekly|monthly)$ ]]; then
        [ "$mode" == "interactive" ] && clear_screen "force"
        echo -e "${RED}A valid frequency must be selected from the available options.${RESET}" >&2
        return 1
    fi

    # Validate backup_time
    if [ -z "$backup_time" ] || [[ ! "$backup_time" =~ ^[0-9]{2}:[0-9]{2}$ ]]; then
        [ "$mode" == "interactive" ] && clear_screen "force"
        echo -e "${RED}A valid backup time must selected from the available options.${RESET}" >&2
        return 1
    else
        # Convert the user-provided time to the appropriate cron format
        IFS=: read -r cron_hour cron_minute <<<"$backup_time"
    fi

    # Validate retention_period
    if [ -z "$retention_period" ] || [[ ! "$retention_period" =~ ^(3|7|30|90|180)$ ]]; then
        [ "$mode" == "interactive" ] && clear_screen "force"
        echo -e "${RED}A valid retention period must selected from the available options.${RESET}" >&2
        return 1
    fi

    # Build the cron expression and the schedule metadata baked into the script.
    # "schedule" / "schedule_label" let the manager display the real schedule
    # ( the cron expression alone cannot express a weekday name or "last day" ).
    case "$backup_frequency" in
    daily)
        cron_expression="$cron_minute $cron_hour * * *"
        schedule="daily"
        schedule_label="Daily"
        ;;
    weekly)
        # Map the chosen weekday name to its cron day-of-week number ( Sunday=0 )
        local cron_dow
        case "$backup_day" in
        Monday) cron_dow=1 ;;
        Tuesday) cron_dow=2 ;;
        Wednesday) cron_dow=3 ;;
        Thursday) cron_dow=4 ;;
        Friday) cron_dow=5 ;;
        Saturday) cron_dow=6 ;;
        Sunday) cron_dow=0 ;;
        *)
            [ "$mode" == "interactive" ] && clear_screen "force"
            echo -e "${RED}A valid weekday must be selected for a weekly backup.${RESET}" >&2
            return 1
            ;;
        esac
        cron_expression="$cron_minute $cron_hour * * $cron_dow"
        schedule="weekly"
        schedule_label="Weekly ($backup_day)"
        ;;
    monthly)
        if [ "$backup_day" == "last" ]; then
            # "Last day of month" cannot be expressed in cron, so the job runs
            # daily and the generated script self-restricts to the final day.
            cron_expression="$cron_minute $cron_hour * * *"
            schedule="monthly-last"
            schedule_label="Monthly (last day)"
        elif [[ "$backup_day" =~ ^[0-9]+$ ]] && [ "$backup_day" -ge 1 ] && [ "$backup_day" -le 28 ]; then
            cron_expression="$cron_minute $cron_hour $backup_day * *"
            schedule="monthly"
            schedule_label="Monthly (day $backup_day)"
        else
            [ "$mode" == "interactive" ] && clear_screen "force"
            echo -e "${RED}A valid day of month ( 1-28 or last ) must be selected for a monthly backup.${RESET}" >&2
            return 1
        fi
        ;;
    *)
        # Handle invalid or unsupported frequency here
        echo -e "${RED}Invalid or unsupported frequency: $backup_frequency${RESET}"
        exit 1
        ;;
    esac

    # Prepare excludes by breaking the $excluded_items variable by comma and format based on backup type
    excludes=""
    if [ -n "$excluded_items" ]; then
        IFS=',' read -ra excluded_items_array <<<"$excluded_items"
        for item in "${excluded_items_array[@]}"; do
            # Remove leading and trailing spaces
            item=$(echo "$item" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
            # Check if the item exists under the backup_domain path
            if [ -e "${backup_path}/${item}" ]; then
                # Wrap the item in double quotes and add it to excludes
                if [ $remote_backup_type == "incremental" ]; then
                    excludes+=" --exclude=\"${backup_path}/${item}\""
                else
                    excludes+=" --exclude=\"${item}\""
                fi

            else
                echo -e "${YELLOW}Warning: excluded location '${item}' does not exist under '${backup_path}'. Skipping...${RESET}"
            fi
        done
    fi

    # Select the rclone remote. Interactive mode prompts and shows the list;
    # headless mode takes it from BACKUP_REMOTE and validates it once.
    if [ "$mode" == "interactive" ]; then
        clear_screen "force"
        echo -e "${BOLD}${YELLOW}Step 2: ${RESET}${YELLOW}select the rclone's remote you'd like to use for this backup.${RESET}"
        echo ""

        # Get comma seperated list of remotes to give to the user as examples
        local remotes_list=$(sudo rclone listremotes --long | awk -F ':' '{print $1}' | tr '\n' ', ')
        remotes_list="${remotes_list%,}"

        # Show available remotes
        echo -e "${BOLD}Available rclone remotes:${RESET}"
        sudo rclone listremotes --long

        # Use a while loop to make sure the user is prompted again if they made a mistake
        while true; do

            read -p "$(echo -e "${BOLD}${BLUE}Type the name of one of the available remotes as your backup destination (eg; ${remotes_list}): ${RESET}")" rclone_remote_name

            # Check if the entered remote name exists
            if rclone listremotes | grep -q "${rclone_remote_name}:"; then
                break # Remote name is valid, exit the loop
            else
                echo -e "${YELLOW}The remote you entered doesn't exist, please try again.${RESET}"
            fi
        done
    else
        # Headless: the remote was provided via --remote
        rclone_remote_name="${BACKUP_REMOTE}"
        if ! rclone listremotes | grep -q "${rclone_remote_name}:"; then
            echo "Error: rclone remote '${rclone_remote_name}' does not exist." >&2
            return 1
        fi
    fi

    # Remember the chosen remote so the repeat-command hint can reference it
    BACKUP_REMOTE="$rclone_remote_name"

    # Validate the rclone remote by writing a test file
    while [ $rclone_remote_valid == false ]; do
        sudo touch wpali.com.txt >/dev/null 2>&1
        # Run the rclone copy command and capture its exit code
        sudo rclone copy wpali.com.txt "${rclone_remote_name}":"${remote_backup_location}"
        exit_code=$?

        # Confirm the file has been created successfully on remote server
        if [ $exit_code -eq 0 ]; then
            if [ "$mode" == "interactive" ]; then
                # Get the rclone remote name that we'll use for the back up with this cron job
                echo ""
                echo -e "${GREEN}We have created a test file on your remote location.${RESET}"
                echo -e "Please go to ${BOLD}"$remote_backup_location"${RESET} on your remote server and check if this file ${BOLD}"wpali.com.txt"${RESET} exists."
                echo ""
                read -p "$(echo -e "${BOLD}${BLUE}Do you confirm that the test file has been created succesfully on your remote server? (y/n): ${RESET}")" rclone_remote_push_success

                if [[ -n "$rclone_remote_push_success" && ("${rclone_remote_push_success,,}" == "y" || "${rclone_remote_push_success,,}" == "yes") ]]; then
                    # Copy was successful
                    rclone_remote_valid=true
                    # Delete leftovers
                    sudo rm wpali.com.txt
                    sudo rclone delete "${rclone_remote_name}":"${remote_backup_location}wpali.com.txt"
                fi
            else
                # Headless: confirm the test file actually appears on the remote
                # ( the automated equivalent of the interactive y/n confirmation -
                # catches a misconfigured bucket/path that rclone copy still exits 0 on )
                if sudo rclone lsf "${rclone_remote_name}":"${remote_backup_location}" 2>/dev/null | grep -qx "wpali.com.txt"; then
                    rclone_remote_valid=true
                    sudo rm wpali.com.txt
                    sudo rclone delete "${rclone_remote_name}":"${remote_backup_location}wpali.com.txt"
                else
                    echo "Error: the rclone test file did not appear at '${rclone_remote_name}:${remote_backup_location}'." >&2
                    sudo rm wpali.com.txt
                    break
                fi
            fi
        else
            # Copy failed, display relevant errors
            echo -e "${RED}rclone copy failed with exit code $exit_code${RESET}" >&2
            break
        fi
    done

    # Prepare the backup script and cron job based on frequency, time and the other options.
    if [ $rclone_remote_valid == true ]; then

        # Check if the cron scripts directory exists, and create it if it doesn't
        if [ ! -d "$CRON_SCRIPTS_DIR" ]; then
            mkdir -p "$CRON_SCRIPTS_DIR"
        fi

        # Generate a unique name for the backup script based on the frequency and time
        local creation_date=$(date +'%Y-%m-%d %H:%M:%S')
        local script_prefix=$(echo -n "$creation_date-$backup_domain-$cron_expression-$retention_period-$remote_backup_location-$rclone_remote_name-$remote_backup_type" | md5sum | awk '{print $1}') # used to prefix the backup script
        local script_name="${script_prefix}_${backup_domain//./-}_${backup_time//:/-}_${backup_frequency}_to_${rclone_remote_name}"
        local script_path="$CRON_SCRIPTS_DIR/$script_name"
        local script_hash=$(echo -n "$script_name" | md5sum | awk '{print $1}') # Use to prefix backups

        # Check if the file exists
        if [ -e "$script_path" ]; then
            echo -e "${RED}Duplicate detected, this backup could not be created.${RESET}" >&2
            return 1
        fi

        # Initialize restic if this is an incremental backup
        if [ $remote_backup_type == "incremental" ]; then
            # Check if a restic repository already exists in the remote location
            local restic_remote_config_output=$(sudo RESTIC_PASSWORD="${restic_password}" restic -r "rclone:${rclone_remote_name}:${remote_backup_location}" cat config 2>&1)
            if echo "$restic_remote_config_output" | grep -q "Is there a repository at the following location"; then

                echo ""
                echo -e "${YELLOW}Initializing remote repository ...${RESET}"
                echo ""

                # If there are no errors, initialize the repo
                sudo RESTIC_PASSWORD="${restic_password}" restic -r "rclone:${rclone_remote_name}:${remote_backup_location}" init
                # Check the exit status of the previous command
                if [ $? -ne 0 ]; then
                    # The restic init command failed, we'll bail out to avoid creating a non-valid backup script
                    [ "$mode" == "interactive" ] && clear_screen "force"
                    echo -e "${RED}Restic repository initilization failed.${RESET}" >&2
                    echo ""
                    return 1
                fi
            else
                # If a repository does not exist, restic will return a non-zero exit code
                [ "$mode" == "interactive" ] && clear_screen "force"
                echo -e "${RED}This incremental backup could not be created. Duplicate found, or other error.${RESET}" >&2
                echo ""
                return 1
            fi

        fi
        # Add the starting content for the backup script (eg; variables..etc)
        cat <<EOF >"$script_path"
#!/bin/bash

# Define the call type, whether it's a pre-restore backup, or default backup
if [ \$# -ge 1 ]; then
    call_type=\$1
else
    call_type="backup"
fi

# Exit script on error, only if this is not a pre-restore backup
if [ \${call_type} != "restore" ]; then
    set -e
fi

tmp_path=$TMP_DIR

# Check if the tmp folder exists, and if not, create it
if [ ! -d "\${tmp_path}" ]; then
    sudo mkdir -p "\${tmp_path}"
fi

# Find and delete any 'tar.gz.tmp', 'sql' or 'sql.gz.tmp' files that are older than 48 hours ( failed backups )
sudo find "\${tmp_path}" -type f -name "*.tar.gz.tmp" -mmin +2880 -exec rm {} \;
sudo find "\${tmp_path}" -type f -name "*.sql" -mmin +2880 -exec rm {} \;
sudo find "\${tmp_path}" -type f -name "*.sql.gz.tmp" -mmin +2880 -exec rm {} \;

# Make sure out logs files doesn't get too big
if [ -f "$LOG_FILE" ]; then
    # Get the current size of the log file in bytes
    log_file_size=\$(stat -c %s "$LOG_FILE")
    log_file_max_size=1048576 # 1MB

    # Check if the log file size exceeds the maximum size ( 1048576 == 1MB )
    if [ "\${log_file_size}" -gt "\${log_file_max_size}" ]; then
        # Truncate the log file to the maximum size
        tail -c "\${log_file_max_size}" "$LOG_FILE" > "$LOG_FILE.tmp"
        mv "$LOG_FILE.tmp" "$LOG_FILE"
    fi
fi

# Save all errors automatically in our logs file
exec >> "$LOG_FILE" 2>&1

# Prepare main variables
type="${remote_backup_type}"
hash="${script_hash}"
creation_date="${creation_date}"
cron_expression="${cron_expression}"
schedule="${schedule}"
schedule_label="${schedule_label}"
domain="${backup_domain}"
domain_path="${backup_path}"
retention_period=${retention_period}
rclone_remote="${rclone_remote_name}"
remote_backup_location="${remote_backup_location}"
timestamp=\$(date +'%Y-%m-%d %H:%M:%S')
backup_date=\$(date +'%d-%m-%Y_%H-%M')

# Resolve how to run wp-cli. PHP is on PATH on standard hosts; Plesk keeps it
# under /opt/plesk/php/<version>/bin. Re-checked here on every run so a PHP
# path change can never silently break the backup.
wp_cli="${wp_cli_path}"
if command -v php >/dev/null 2>&1; then
    wp_run="\${wp_cli}"
else
    wp_run="\$(ls -d /opt/plesk/php/*/bin/php 2>/dev/null | sort -Vr | head -1) \${wp_cli}"
fi

# Email a failure alert if this backup exits with an error ( one alert per failed run ).
# The address is read from the definitions file at run time, so it can be changed centrally.
definitions_file="$PWD/$DEFINITIONS_FILE"
backup_failure_notify() {
    local rc=\$?
    set +e
    [ \$rc -eq 0 ] && return
    local notify_email=""
    [ -f "\${definitions_file}" ] && notify_email=\$(grep -oP 'NOTIFY_EMAIL="\K[^"]*' "\${definitions_file}" 2>/dev/null)
    [ -z "\${notify_email}" ] && return
    local subject="[Backup FAILED] \${domain} (\${type})"
    local mail_body="Automated \${type} backup for '\${domain}' failed with exit code \${rc}.
Server time: \$(date)

--- last 30 log lines ---
\$(tail -n 30 "$LOG_FILE" 2>/dev/null)"
    if command -v mail >/dev/null 2>&1; then
        printf '%s\n' "\${mail_body}" | mail -s "\${subject}" "\${notify_email}"
    elif command -v sendmail >/dev/null 2>&1; then
        printf 'Subject: %s\nTo: %s\n\n%s\n' "\${subject}" "\${notify_email}" "\${mail_body}" | sendmail -t
    fi
}
trap backup_failure_notify EXIT

# A "last day of month" schedule runs daily but only acts on the month's final
# day. Only scheduled cron runs ( call_type=backup ) are skipped - the initial
# backup and a pre-restore backup must always run, whatever the day.
if [ "\${call_type}" = "backup" ] && [ "\${schedule}" = "monthly-last" ] && [ "\$(date -d tomorrow +%d)" != "01" ]; then
    exit 0
fi

# --- Serialize backup runs across all sites ( prevents server overload ) ---
# Acquire a shared lock so that, however many cron entries fire together, the
# heavy work ( tar / rclone / restic ) runs strictly one site at a time.
exec {lock_fd}>"$LOCK_FILE"
if ! flock -n "\${lock_fd}"; then
    echo "[\$(date +'%Y-%m-%d %H:%M:%S')] BACK UP QUEUED (\${type}): waiting for another backup to finish for '\${domain}'" >> "$LOG_FILE"
    if ! flock -w $lock_timeout "\${lock_fd}"; then
        echo "[\$(date +'%Y-%m-%d %H:%M:%S')] BACK UP SKIPPED (\${type}): lock busy, timed out for '\${domain}'" >> "$LOG_FILE"
        # A pre-restore backup that cannot run must fail so the caller aborts the
        # restore; a scheduled run just skips this cycle without an alert.
        [ "\${call_type}" = "restore" ] && exit 1
        exit 0
    fi
fi

echo "[\${timestamp}] BACK UP STARTED (\${type}): Performing $backup_time $backup_frequency backup for '\${domain}'" >> "$LOG_FILE"
echo "[\${timestamp}] - Exporting database" >> "$LOG_FILE"

EOF

        # Append to the script based on the backup type
        if [ $remote_backup_type == "incremental" ]; then
            # Add the necessary commands for incremental backups (append to file, note >>)
            cat <<EOF >>"$script_path"
# Get the wp installation folder owner and their home directory
wp_owner=\$(sudo stat -c "%U" \${domain_path})

# Get the database name and construct the db backup file name and path
# Note that we are using sudo to run wp cli commands as "wp_owner" to avoid permissions complications
db_name=\$(sudo -u "\${wp_owner}" -s -- \${wp_run} config get DB_NAME --path="\${domain_path}" --skip-plugins --skip-themes)
db_filename=\${hash}_\${domain//./_}_\${db_name}_incremental.sql
# We'll export the database and move it to our current directory as a 'tmp' file
if ! sudo -u "\${wp_owner}" -s -- \${wp_run} db export "\${domain_path}/\${db_filename}" --path="\${domain_path}" --skip-plugins --skip-themes; then
    echo "[\${timestamp}] ERROR: database export failed. Aborting backup." >>"$LOG_FILE"
    sudo rm -f "\${domain_path}/\${db_filename}"
    exit 1
fi

restic_password=${restic_password}

echo "[\${timestamp}] - Sending the backup to 'rclone' "\${rclone_remote}" remote  using 'restic'" >>"$LOG_FILE"

# Use restic to save a new backup to rclone remote
if [ \${call_type} == "restore" ]; then
    # We will backup the whole folder when it's a pre-restore backup ( no excludes )
    if ! sudo RESTIC_PASSWORD="\${restic_password}" restic -q -r "rclone:\${rclone_remote}:\${remote_backup_location}" backup "\$domain_path/"; then
        echo "[\${timestamp}] ERROR: restic backup failed. Aborting backup." >>"$LOG_FILE"
        sudo rm -f "\${domain_path}/\${db_filename}"
        exit 1
    fi
else
    if ! sudo RESTIC_PASSWORD="\${restic_password}" restic -q -r "rclone:\${rclone_remote}:\${remote_backup_location}" backup "\$domain_path/" ${excludes}; then
        echo "[\${timestamp}] ERROR: restic backup failed. Aborting backup." >>"$LOG_FILE"
        sudo rm -f "\${domain_path}/\${db_filename}"
        exit 1
    fi
fi

echo "[\${timestamp}] - backup sent to the remote location successfully" >>"$LOG_FILE"
echo "[\${timestamp}] - Delete the internally generated backup files to free space" >>"$LOG_FILE"

# Delete the generated database file
sudo rm "\${domain_path}/\${db_filename}"

echo "[\${timestamp}] - Delete backups older than \${retention_period} days from 'rclone' "\${rclone_remote}" remote using 'restic'" >>"$LOG_FILE"

# Delete old backups from remote ( retention logic )
sudo RESTIC_PASSWORD="\${restic_password}" restic -q -r "rclone:\${rclone_remote}:\${remote_backup_location}" forget --keep-within "\${retention_period}d" --prune

EOF

        elif [ $remote_backup_type == "database" ]; then
            # Add the necessary commands for database-only backups (append to file, note >>)
            cat <<EOF >>"$script_path"

# Get the wp installation folder owner
wp_owner=\$(sudo stat -c "%U" \${domain_path})

# Use a dedicated temp directory for database backups
wp_owner_directory="/tmp/wp_db_backup_\${hash}"

echo "[\${timestamp}] - WP folder owner found: '\${wp_owner}'" >> "$LOG_FILE"
echo "[\${timestamp}] - Using temp directory: '\${wp_owner_directory}'" >> "$LOG_FILE"

# Create tmp directory with proper permissions if it doesn't exist
if [ ! -d "\${wp_owner_directory}" ]; then
    sudo mkdir -p "\${wp_owner_directory}"
    sudo chown \${wp_owner} "\${wp_owner_directory}"
    sudo chmod 755 "\${wp_owner_directory}"
fi

# Get the database name and construct the db backup file name and path
db_name=\$(sudo -u "\${wp_owner}" -s -- \${wp_run} config get DB_NAME --path="\${domain_path}" --skip-plugins --skip-themes)
db_filename=\${hash}_\${domain//./_}_\${db_name}_\${backup_date}.sql

# Export the database with proper permissions
if ! sudo -u "\${wp_owner}" -s -- \${wp_run} db export "\${wp_owner_directory}/\${db_filename}" --path="\${domain_path}" --skip-plugins --skip-themes; then
    echo "[\${timestamp}] ERROR: database export failed. Aborting backup." >> "$LOG_FILE"
    sudo rm -f "\${wp_owner_directory}/\${db_filename}"
    exit 1
fi

echo "[\${timestamp}] - Compressing the database export" >> "$LOG_FILE"

# Compress the SQL dump to reduce transfer size and remote storage usage
if ! sudo gzip -f "\${wp_owner_directory}/\${db_filename}"; then
    echo "[\${timestamp}] ERROR: database compression failed. Aborting backup." >> "$LOG_FILE"
    sudo rm -f "\${wp_owner_directory}/\${db_filename}" "\${wp_owner_directory}/\${db_filename}.gz"
    exit 1
fi
db_archive="\${wp_owner_directory}/\${db_filename}.gz"

echo "[\${timestamp}] - Sending the database backup to remote location "\${rclone_remote}" using rclone" >> "$LOG_FILE"

# Copy the compressed database backup to the remote location using rclone
if ! sudo rclone copy "\${db_archive}" \${rclone_remote}:\${remote_backup_location}; then
    echo "[\${timestamp}] ERROR: rclone copy failed. Aborting backup." >> "$LOG_FILE"
    sudo rm -f "\${db_archive}"
    exit 1
fi

echo "[\${timestamp}] - database backup sent to the remote location successfully" >> "$LOG_FILE"
echo "[\${timestamp}] - Delete the internally generated database backup to free space" >> "$LOG_FILE"

# Delete the locally generated database archive
sudo rm -f "\${db_archive}"

echo "[\${timestamp}] - Delete backups older than \${retention_period} days from remote location "\${rclone_remote}" using rclone" >> "$LOG_FILE"

# Delete old backups from remote ( retention logic )
sudo rclone delete --min-age \${retention_period}d "\${rclone_remote}":"\${remote_backup_location}"

EOF

        else
            # Add the necessary commands for full backups (append to file, note >>)
            cat <<EOF >>"$script_path"

# Get the wp installation folder owner
wp_owner=\$(sudo stat -c "%U" \${domain_path})

# Use a dedicated temp directory for database backups
wp_owner_directory="/tmp/wp_db_backup_\${hash}"

echo "[\${timestamp}] - WP folder owner found: '\${wp_owner}'" >> "$LOG_FILE"
echo "[\${timestamp}] - Using temp directory: '\${wp_owner_directory}'" >> "$LOG_FILE"

# Create tmp directory with proper permissions if it doesn't exist
if [ ! -d "\${wp_owner_directory}" ]; then
    sudo mkdir -p "\${wp_owner_directory}"
    sudo chown \${wp_owner} "\${wp_owner_directory}"
    sudo chmod 755 "\${wp_owner_directory}"
fi

# Get wp-config.php location (one level up from domain_path for WordOps)
wp_config_path="\${domain_path}"
if [[ "\${domain_path}" == */htdocs ]]; then
    wp_config_path="\${domain_path%/htdocs}"
fi

# Get the database name and construct the db backup file name and path
db_name=\$(sudo -u "\${wp_owner}" -s -- \${wp_run} config get DB_NAME --path="\${domain_path}" --skip-plugins --skip-themes)
db_filename=\${hash}_\${domain//./_}_\${db_name}_\${backup_date}.sql

# Export the database with proper permissions
if ! sudo -u "\${wp_owner}" -s -- \${wp_run} db export "\${wp_owner_directory}/\${db_filename}" --path="\${domain_path}" --skip-plugins --skip-themes; then
    echo "[\${timestamp}] ERROR: database export failed. Aborting backup." >> "$LOG_FILE"
    sudo rm -f "\${wp_owner_directory}/\${db_filename}"
    exit 1
fi

if [ \${call_type} == "restore" ]; then
    echo "[\${timestamp}] - Generating pre-restore backup archive" >> "$LOG_FILE"
    backup_filename=\${tmp_path}/\${hash}_\${domain//./-}_\${backup_date}-pre-restore.tar.gz
else
    echo "[\${timestamp}] - Generating backup archive" >> "$LOG_FILE"
    backup_filename=\${tmp_path}/\${hash}_\${domain//./-}_\${backup_date}.tar.gz
fi

# --- Backup Logic ---

# Prepare the backup file (compress the target site and the previously exported database)
echo "[\${timestamp}] - Attempting direct tar backup" >> "$LOG_FILE"

backup_success=false

if sudo test "\${call_type}" = "restore"; then
    # Try direct tar for pre-restore backup first
    if sudo tar --warning=no-file-changed --transform 's,^\./,,' -czf "\${backup_filename}.tmp" -C "\${domain_path}/" . -C "\${wp_owner_directory}/" "\${db_filename}" 2>> "$LOG_FILE"; then
        backup_success=true
        echo "[\${timestamp}] - Direct tar backup successful" >> "$LOG_FILE"
    else
        echo "[\${timestamp}] - Direct tar backup failed, trying alternative method" >> "$LOG_FILE"
    fi
else
    # Try direct tar with excludes first
    if sudo tar --warning=no-file-changed --transform 's,^\./,,' $excludes -czf "\${backup_filename}.tmp" -C "\${domain_path}/" . -C "\${wp_owner_directory}/" "\${db_filename}" 2>> "$LOG_FILE"; then
        backup_success=true
        echo "[\${timestamp}] - Direct tar backup successful" >> "$LOG_FILE"
    else
        echo "[\${timestamp}] - Direct tar backup failed, trying alternative method" >> "$LOG_FILE"
    fi
fi

# If direct tar failed, try cp method
if [ "\$backup_success" = false ]; then
    # Create temporary directory for cp method
    tmp_backup_dir="\${wp_owner_directory}/tmp_backup_\${backup_date}"
    
    # Check available space before copying
    required_space=\$(sudo du -sb "\${domain_path}" | cut -f1)
    available_space=\$(sudo df -B1 "\${wp_owner_directory}" | awk 'NR==2 {print \$4}')

    if [ "\$available_space" -gt "\$((required_space * 2))" ]; then
        echo "[\${timestamp}] - Sufficient space available for cp method" >> "$LOG_FILE"
        
        # Create temp directory and copy files
        sudo mkdir -p "\${tmp_backup_dir}"
        
        if sudo test "\${call_type}" = "restore"; then
            sudo cp -a "\${domain_path}/." "\${tmp_backup_dir}/"
        else
            sudo cp -a "\${domain_path}/." "\${tmp_backup_dir}/"
            # Apply excludes by removing excluded files/directories
            for exclude in $excludes; do
                exclude_path=\$(echo "\$exclude" | sed 's/--exclude=//')
                sudo rm -rf "\${tmp_backup_dir}/\${exclude_path}"
            done
        fi
        
        # Try tar on the copied files
        if sudo tar -czf "\${backup_filename}.tmp" -C "\${tmp_backup_dir}" . -C "\${wp_owner_directory}/" "\${db_filename}" 2>> "$LOG_FILE"; then
            backup_success=true
            echo "[\${timestamp}] - Backup successful using cp method" >> "$LOG_FILE"
        fi
        
        # Clean up temp directory
        sudo rm -rf "\${tmp_backup_dir}"
    else
        echo "[\${timestamp}] - Insufficient space for cp method" >> "$LOG_FILE"
    fi
fi

if [ "\$backup_success" = false ]; then
    echo "[\${timestamp}] ERROR: All backup methods failed" >> "$LOG_FILE"
    # Cleanup any temporary files
    sudo rm -f "\${backup_filename}.tmp"
    sudo rm -f "\${wp_owner_directory}/\${db_filename}"
    exit 1
fi

# Rename the temporary backup file to the actual name to indicate that the compression completed
sudo mv "\${backup_filename}.tmp" "\${backup_filename}"

# --- End Backup Logic ---

echo "[\${timestamp}] - backup archive generated: "\${backup_filename}"" >> "$LOG_FILE"
echo "[\${timestamp}] - Sending the backup file to remote location "\${rclone_remote}" using rclone" >> "$LOG_FILE"

# Copy the generated backup to the remote location using rclone
if ! sudo rclone copy \$backup_filename \${rclone_remote}:\${remote_backup_location}; then
    echo "[\${timestamp}] ERROR: rclone copy failed. Aborting backup." >> "$LOG_FILE"
    sudo rm -f "\${backup_filename}" "\${wp_owner_directory}/\${db_filename}"
    exit 1
fi

echo "[\${timestamp}] - backup file sent to the remote location successfully" >> "$LOG_FILE"
echo "[\${timestamp}] - Delete the internally generated backup files to free space" >> "$LOG_FILE"

# Delete the generated backup archive and database
sudo rm \${backup_filename}
sudo rm \${wp_owner_directory}/\${db_filename}

echo "[\${timestamp}] - Delete backups older than \${retention_period} days from remote location "\${rclone_remote}" using rclone" >> "$LOG_FILE"

# Delete old backups from remote ( retention logic )
sudo rclone delete --min-age \${retention_period}d "\${rclone_remote}":"\${remote_backup_location}"

EOF
        fi

        # Add the final content of the script file (append to file, note >>)
        cat <<EOF >>"$script_path"
echo "[\${timestamp}] BACK UP FINISHED (\${type}): $backup_frequency backup for \${domain} has completed successfully" >> "$LOG_FILE"

# Make sure to close the log file when done
exec 3>&-
EOF

        # Give the script the right permissions ( only owner can read/write/execute )
        sudo chmod 700 "$script_path"

        # Register the cron schedule ( the durable part - do this before the
        # first backup, which can take a while ).
        if [ ! -f "$CRON_FILE" ]; then
            sudo touch "$CRON_FILE"     # Create the cron file
            sudo chmod 644 "$CRON_FILE" # Ensure the file has the correct permissions
        fi
        # Add the cron job, unless an identical entry ( or one for the same script ) already exists
        local cron_line="$cron_expression root /bin/bash $PWD/$script_path"
        if grep -Fqx "$cron_line" "$CRON_FILE" 2>/dev/null || grep -Fq "$(basename "$script_path")" "$CRON_FILE" 2>/dev/null; then
            echo -e "${YELLOW}A cron entry for this backup already exists, skipping cron update.${RESET}"
        else
            echo "$cron_line" >>"$CRON_FILE"
        fi

        # Show success message
        if [ "$mode" == "interactive" ]; then
            clear_screen "force"
            echo -e "${BOLD}${GREEN}Your automated backup for $backup_domain has been created successfully.${RESET}"
            echo ""
        else
            echo "Backup created for ${backup_domain} (${remote_backup_type}, ${schedule_label}) -> ${rclone_remote_name}:${remote_backup_location}"
        fi
        # Update definitions state variables
        update_definitions_state

        # Decide whether to take the first backup right now. Interactive mode
        # asks; headless runs it unless --no-initial was passed.
        local run_initial=false
        if [ "$mode" == "interactive" ]; then
            local first_now
            read -p "$(echo -e "${BOLD}${BLUE}Run the first backup now? (y/n): ${RESET}")" first_now
            [[ "${first_now,,}" == "y" || "${first_now,,}" == "yes" ]] && run_initial=true
        elif [ "$SKIP_INITIAL" != true ]; then
            run_initial=true
        fi

        if [ "$run_initial" == true ]; then
            # Run it in the foreground so the result is visible and confirmed.
            # The backup script logs its detail to "$LOG_FILE"; here we only
            # report whether it succeeded.
            echo -e "${YELLOW}Running the first backup now ( this can take a while )...${RESET}"
            if sudo bash "$script_path" "initial"; then
                echo -e "${GREEN}First backup completed. Backups will continue on the schedule.${RESET}"
            else
                echo -e "${RED}First backup FAILED - check the log: $LOG_FILE${RESET}" >&2
            fi
        else
            echo -e "${YELLOW}Skipped the first backup; the schedule will take it ( $backup_time, $schedule_label ).${RESET}"
        fi
        echo ""
        return 0

    else
        if [ "$mode" == "interactive" ]; then
            # Copy failed, display relevant errors
            echo -e "${RED}Something went wrong, please make sure the selected rclone remote is correctly configured.${RESET}"
            echo -e "${RED}Also note that if you're using object based storage, your backup location should start with a bucket name.${RESET}"
            read -p "$(echo -e "${BLUE}Would you like to open rclone configuration screen? (y/n): ${RESET}")" rclone_reconfig
            if [ "${rclone_reconfig,,}" == "y" ] || [ "${rclone_reconfig,,}" == "yes" ]; then
                configure_rclone
                generate_backup_script
            else
                generate_backup_script
            fi
            return 1
        else
            echo "Error: the rclone remote test failed for '${rclone_remote_name}'." >&2
            echo "Check that the remote name and backup location are correct." >&2
            return 1
        fi
    fi
}

# Print the equivalent non-interactive command for the backup just created, so
# it can be reproduced or scripted across many sites. Reads the BACKUP_* globals.
print_repeat_hint() {
    local hint_path hint_exclude
    hint_path=$(resolve_domain_path "$BACKUP_DOMAIN")
    hint_exclude="$EXCLUDED_ITEMS"
    [ -z "$hint_exclude" ] && hint_exclude="none"

    local hint="  sudo bash \"$SCRIPT_DIR/config.sh\""
    hint+=" --domain \"$BACKUP_DOMAIN\""
    hint+=" --path \"$hint_path\""
    hint+=" --type \"$BACKUP_TYPE\""
    hint+=" --frequency \"$BACKUP_FREQUENCY\""
    [ -n "$BACKUP_DAY" ] && hint+=" --day \"$BACKUP_DAY\""
    hint+=" --time \"$BACKUP_TIME\""
    hint+=" --retention \"$RETENTION_PERIOD\""
    hint+=" --remote \"$BACKUP_REMOTE\""
    hint+=" --location \"$REMOTE_BACKUP_LOCATION\""
    hint+=" --exclude \"$hint_exclude\""
    # Emit a placeholder rather than the real restic password, so copying this
    # command into a script or shell history does not leak the secret.
    [ "$BACKUP_TYPE" == "incremental" ] && hint+=" --password \"<your-restic-password>\""
    hint+=" --yes"

    echo -e "${BOLD}To create this backup again ( or script it ), run:${RESET}"
    echo -e "${GREEN}${hint}${RESET}"
    [ "$BACKUP_TYPE" == "incremental" ] && echo -e "${YELLOW}Replace <your-restic-password> with the password you set for this backup.${RESET}"
    echo ""
}
