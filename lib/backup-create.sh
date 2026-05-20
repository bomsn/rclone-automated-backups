#!/bin/bash

# Backup creation: settings collection and backup-script generation

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

    # Collect backup time preference
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

    # Collect excluded folders
    read -p "$(echo -e "${BOLD}${BLUE}Enter folders to exclude (comma-separated eg; wp-admin, wp-includes; or leave empty for none): ${RESET}")" EXCLUDED_ITEMS

    # Collect backup type
    # full      = whole site files + database in one archive
    # incremental = restic-based snapshots of the whole site ( requires restic )
    # database  = database-only backup ( lightweight, ideal for a daily schedule )
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
    echo -e "${BOLD}Backup Frequency:${RESET} $BACKUP_FREQUENCY"
    echo -e "${BOLD}Backup Time:${RESET} $BACKUP_TIME"
    echo -e "${BOLD}Retention Period:${RESET} $RETENTION_PERIOD days"
    echo -e "${BOLD}Excluded Locations:${RESET} $EXCLUDED_ITEMS"
    echo -e "${BOLD}Remote Backup Location:${RESET} $REMOTE_BACKUP_LOCATION"
    echo -e "${BOLD}Remote Backup Type:${RESET} $BACKUP_TYPE"

    read -p "$(echo -e "${BOLD}${BLUE}Are you sure you want to proceed with the above configurations? (y/n): ${RESET}")" confirm
    if [[ $confirm != "y" && $confirm != "yes" ]]; then
        clear_screen "force"
        echo -e "${YELLOW}Please select your preferences again.${RESET}"
        collect_backup_settings
        return
    fi

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

    # Extract the collected backup settings from the `$backup_settings` array
    local backup_domain="${BACKUP_DOMAIN}"
    local backup_path=""
    local backup_frequency="${BACKUP_FREQUENCY}"
    local backup_time="${BACKUP_TIME}"
    local retention_period="${RETENTION_PERIOD}"
    local excluded_items="${EXCLUDED_ITEMS}"
    local remote_backup_location="${REMOTE_BACKUP_LOCATION}/"
    local remote_backup_type="${BACKUP_TYPE}"
    local restic_password=""
    local rclone_remote_name=""
    local rclone_remote_valid=false

    # Pull restic password if an incremental backup is defined
    if [ $remote_backup_type == "incremental" ]; then
        restic_password="${BACKUP_PASS}"
    fi

    # Validate backup_domain
    if [[ ! " ${DOMAINS[@]} " =~ " $backup_domain " ]]; then
        clear_screen "force"
        echo -e "${RED}A valid domain must be selected from the available options.${RESET}"
        return
    else
        # If the domain is valid, let populate the backup path
        for ((i = 0; i < ${#DOMAINS[@]}; i++)); do
            current_domain="${DOMAINS[$i]}"
            current_path="${PATHS[$i]}"
            if [ "$current_domain" == "$backup_domain" ]; then
                backup_path=$current_path
            fi
        done
    fi

    # Validate and sanitize backup_frequency
    if [ -z "$backup_frequency" ] || [[ ! "$backup_frequency" =~ ^(daily|weekly|monthly)$ ]]; then
        clear_screen "force"
        echo -e "${RED}A valid frequency must be selected from the available options.${RESET}"
        return
    fi

    # Validate backup_time
    if [ -z "$backup_time" ] || [[ ! "$backup_time" =~ ^[0-9]{2}:[0-9]{2}$ ]]; then
        clear_screen "force"
        echo -e "${RED}A valid backup time must selected from the available options.${RESET}"
        return
    else
        # Convert the user-provided time to the appropriate cron format
        IFS=: read -r cron_hour cron_minute <<<"$backup_time"
    fi

    # Validate retention_period
    if [ -z "$retention_period" ] || [[ ! "$retention_period" =~ ^(3|7|30|90|180)$ ]]; then
        clear_screen "force"
        echo -e "${RED}A valid retention period must selected from the available options.${RESET}"
        return
    fi

    # Create a cron expression based on the frequency and backup time
    case "$backup_frequency" in
    daily)
        cron_expression="$cron_minute $cron_hour * * *"
        ;;
    weekly)
        cron_expression="$cron_minute $cron_hour * * 0" # 0 represents Sunday, adjust as needed
        ;;
    monthly)
        cron_expression="$cron_minute $cron_hour 1 * *" # 1 represents first day of the month
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

    # Validate the rclone remote by writing a test file
    while [ $rclone_remote_valid == false ]; do
        sudo touch wpali.com.txt >/dev/null 2>&1
        # Run the rclone copy command and capture its exit code
        sudo rclone copy wpali.com.txt "${rclone_remote_name}":"${remote_backup_location}"
        exit_code=$?

        # Confirm the file has been created successfully on remote server
        if [ $exit_code -eq 0 ]; then
            # Get the rclone remote name that we'll use for the back up with this cron job
            echo ""
            echo -e "${GREEN}We have created a test file on your remote location.${RESET}"
            echo -e "Please go to ${BOLD}"$remote_backup_location"${RESET} on your remote server and check if this file ${BOLD}"wpali.com.txt"${RESET} exists."
            echo ""
            read -p "$(echo -e "${BOLD}${BLUE}Do you confirm that the test file has been created succesfully on your remote server? (y/n): ${RESET}")" rclone_remote_push_success

            if [[ -n "$rclone_remote_push_success" && ("$rclone_remote_push_success" == "y" || "$rclone_remote_push_success" == "yes") ]]; then
                # Copy was successful
                rclone_remote_valid=true
                # Delete leftovers
                sudo rm wpali.com.txt
                sudo rclone delete "${rclone_remote_name}":"${remote_backup_location}wpali.com.txt"
            fi
        else
            # Copy failed, display relevant errors
            echo -e "${RED}rclone copy failed with exit code $exit_code${RESET}"
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
            echo -e "${RED}Duplicate detected, this backup could not be created.${RESET}"
            return
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
                    clear_screen "force"
                    echo -e "${RED}Restic repository initilization failed.${RESET}"
                    echo ""
                    return
                fi
            else
                # If a repository does not exist, restic will return a non-zero exit code
                clear_screen "force"
                echo -e "${RED}This incremental backup could not be created. Duplicate found, or other error.${RESET}"
                echo ""
                return
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
domain="${backup_domain}"
domain_path="${backup_path}"
retention_period=${retention_period}
rclone_remote="${rclone_remote_name}"
remote_backup_location="${remote_backup_location}"
timestamp=\$(date +'%Y-%m-%d %H:%M:%S')
backup_date=\$(date +'%d-%m-%Y_%H-%M')

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
db_name=\$(sudo -u "\${wp_owner}" -s -- wp config get DB_NAME --path="\${domain_path}")
db_filename=\${hash}_\${domain//./_}_\${db_name}_incremental.sql
# We'll export the database and move it to our current directory as a 'tmp' file
if ! sudo -u "\${wp_owner}" -s -- wp db export "\${domain_path}/\${db_filename}" --path="\${domain_path}"; then
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
wp_owner_directory="/tmp/wp_db_backup"

echo "[\${timestamp}] - WP folder owner found: '\${wp_owner}'" >> "$LOG_FILE"
echo "[\${timestamp}] - Using temp directory: '\${wp_owner_directory}'" >> "$LOG_FILE"

# Create tmp directory with proper permissions if it doesn't exist
if [ ! -d "\${wp_owner_directory}" ]; then
    sudo mkdir -p "\${wp_owner_directory}"
    sudo chown \${wp_owner}:\${wp_owner} "\${wp_owner_directory}"
    sudo chmod 755 "\${wp_owner_directory}"
fi

# Get the database name and construct the db backup file name and path
db_name=\$(sudo -u "\${wp_owner}" -s -- wp config get DB_NAME --path="\${domain_path}")
db_filename=\${hash}_\${domain//./_}_\${db_name}_\${backup_date}.sql

# Export the database with proper permissions
if ! sudo -u "\${wp_owner}" -s -- wp db export "\${wp_owner_directory}/\${db_filename}" --path="\${domain_path}"; then
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
wp_owner_directory="/tmp/wp_db_backup"

echo "[\${timestamp}] - WP folder owner found: '\${wp_owner}'" >> "$LOG_FILE"
echo "[\${timestamp}] - Using temp directory: '\${wp_owner_directory}'" >> "$LOG_FILE"

# Create tmp directory with proper permissions if it doesn't exist
if [ ! -d "\${wp_owner_directory}" ]; then
    sudo mkdir -p "\${wp_owner_directory}"
    sudo chown \${wp_owner}:\${wp_owner} "\${wp_owner_directory}"
    sudo chmod 755 "\${wp_owner_directory}"
fi

# Get wp-config.php location (one level up from domain_path for WordOps)
wp_config_path="\${domain_path}"
if [[ "\${domain_path}" == */htdocs ]]; then
    wp_config_path="\${domain_path%/htdocs}"
fi

# Get the database name and construct the db backup file name and path
db_name=\$(sudo -u "\${wp_owner}" -s -- wp config get DB_NAME --path="\${domain_path}")
db_filename=\${hash}_\${domain//./_}_\${db_name}_\${backup_date}.sql

# Export the database with proper permissions
if ! sudo -u "\${wp_owner}" -s -- wp db export "\${wp_owner_directory}/\${db_filename}" --path="\${domain_path}"; then
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
        # Run the script to take the initial backup in the background
        sudo -b bash "$script_path" >/dev/null 2>&1
        # Create our cron file if it doesn't already exist, and give it correct permissions
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
        clear_screen "force"
        echo -e "${BOLD}${GREEN}Your automated backup for $backup_domain has been created successfully.${RESET}"
        echo -e "${GREEN}An initial backup is running the background.${RESET}"
        echo ""
        # Update definitions state variables
        update_definitions_state

    else
        # Copy failed, display relevant errors
        echo -e "${RED}Something went wrong, please make sure the selected rclone remote is correctly configured.${RESET}"
        echo -e "${RED}Also note that if you're using object based storage, your backup location should start with a bucket name.${RESET}"
        read -p "$(echo -e "${BLUE}Would you like to open rclone configuration screen? (y/n): ${RESET}")" rclone_reconfig
        if [ $rclone_reconfig == "y" ] || [ $rclone_reconfig == "yes" ]; then
            configure_rclone
            generate_backup_script
            return
        else
            generate_backup_script
            return
        fi
    fi
}
