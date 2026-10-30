#!/bin/bash

# Backup creation: settings collection and backup-script generation
source "$(dirname "${BASH_SOURCE[0]}")/mysql-options.sh"
source "$(dirname "${BASH_SOURCE[0]}")/locking.sh"
source "$(dirname "${BASH_SOURCE[0]}")/notifications.sh"
source "$(dirname "${BASH_SOURCE[0]}")/metadata.sh"
source "$(dirname "${BASH_SOURCE[0]}")/archive.sh"
source "$(dirname "${BASH_SOURCE[0]}")/remote-probe.sh"

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

    # Collect backup type early. A database-only or files-only backup follows a
    # different code path, so choosing it here lets the right step be skipped.
    # full        = whole site files + database in one archive ( WordPress )
    # incremental = restic-based snapshots of the whole site + database
    #               ( requires restic; WordPress )
    # database    = database-only backup ( lightweight, ideal for a daily schedule )
    # files       = files-only backup of any directory ( no database, no WordPress
    #               assumptions; use this for non-WP folders )
    PS3="$(echo -e "${BOLD}${BLUE}Choose backup type: ${RESET}")"
    if [ $RESTIC_AVAILABLE == true ]; then
        select type in "full" "incremental" "database" "files"; do
            case $type in
            full | incremental | database | files)
                BACKUP_TYPE="$type"
                break
                ;;
            *)
                echo -e "${RED}Invalid option. Please select a valid type.${RESET}"
                ;;
            esac
        done
    else
        select type in "full" "database" "files"; do
            case $type in
            full | database | files)
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

    # Collect the database driver for backup types that touch the database.
    # wpcli ( default ) reads credentials from wp-config.php; mysqldump uses
    # explicit credentials supplied here, useful for non-WP databases and for
    # cases where wp-cli is unavailable. Incremental and files types skip this.
    DB_DRIVER="wpcli"
    DB_NAME=""
    DB_USER=""
    DB_PASS=""
    DB_HOST="localhost"
    if [[ "$BACKUP_TYPE" == "database" || "$BACKUP_TYPE" == "full" ]]; then
        PS3="$(echo -e "${BOLD}${BLUE}Choose database driver: ${RESET}")"
        select driver in "wp-cli ( reads credentials from wp-config.php )" "mysqldump ( supply credentials manually )"; do
            case "$driver" in
            "wp-cli"*) DB_DRIVER="wpcli"; break ;;
            "mysqldump"*) DB_DRIVER="mysqldump"; break ;;
            *) echo -e "${RED}Invalid option. Please select a valid driver.${RESET}" ;;
            esac
        done
        PS3="$original_ps3"

        if [ "$DB_DRIVER" == "mysqldump" ]; then
            echo ""
            echo -e "${YELLOW}mysqldump credentials are stored in plain text inside the${RESET}"
            echo -e "${YELLOW}generated backup script ( file is chmod 700, root-readable${RESET}"
            echo -e "${YELLOW}only ). At backup time they are passed via --defaults-extra-file${RESET}"
            echo -e "${YELLOW}so they never appear in ps / argv.${RESET}"
            echo ""
            # Re-prompt on empty input so a stray Enter cannot silently produce
            # a non-functional backup script.
            while true; do
                read -p "$(echo -e "${BOLD}${BLUE}Database name: ${RESET}")" DB_NAME
                [ -n "$DB_NAME" ] && break
                echo -e "${RED}Database name is required.${RESET}"
            done
            while true; do
                read -p "$(echo -e "${BOLD}${BLUE}Database user: ${RESET}")" DB_USER
                [ -n "$DB_USER" ] && break
                echo -e "${RED}Database user is required.${RESET}"
            done
            while true; do
                read -s -p "$(echo -e "${BOLD}${BLUE}Database password: ${RESET}")" DB_PASS
                echo ""
                if [ -z "$DB_PASS" ]; then
                    echo -e "${RED}Database password is required.${RESET}"
                    continue
                fi
                if [[ "$DB_PASS" == *$'\n'* ]]; then
                    echo -e "${RED}Password must not contain a newline character.${RESET}"
                    continue
                fi
                # Confirm by re-typing, same protection as the restic password prompt
                read -s -p "$(echo -e "${BOLD}${BLUE}Confirm database password: ${RESET}")" DB_PASS_CONFIRM
                echo ""
                [ "$DB_PASS" = "$DB_PASS_CONFIRM" ] && break
                echo -e "${RED}Passwords do not match. Please try again.${RESET}"
            done
            read -p "$(echo -e "${BOLD}${BLUE}Database host [localhost]: ${RESET}")" DB_HOST
            DB_HOST="${DB_HOST:-localhost}"
        fi
    fi

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
    local backup_php_binary="${BACKUP_PHP_BINARY:-}"
    if [ -n "$backup_php_binary" ]; then
        if [[ "$backup_php_binary" != /* || ! -x "$backup_php_binary" ]] ||
           ! "$backup_php_binary" -v 2>/dev/null | head -1 | grep -q '(cli)'; then
            echo 'The selected PHP binary must be an executable absolute path to PHP CLI.' >&2
            return 1
        fi
    fi
    # Database driver and ( for mysqldump ) credentials. Defaults to wpcli so a
    # backup created before this knob existed has the same behavior. Credentials
    # are written into the script via printf %s outside the heredoc so values
    # containing $ or " survive intact.
    local db_driver="${DB_DRIVER:-wpcli}"
    local db_name="${DB_NAME:-}"
    local db_user="${DB_USER:-}"
    local db_pass="${DB_PASS:-}"
    local db_host="${DB_HOST:-localhost}"

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

    # Pre-flight: catch invalid combinations BEFORE writing the script, so the
    # user does not discover a misconfiguration only when the first cron run
    # logs an error. Combinations that require a WordPress install:
    #   - type incremental ( always wp-cli driven )
    #   - type full or database with db_driver wpcli ( reads wp-config.php )
    # The files type and the mysqldump driver have no WP requirement.
    if [[ "$remote_backup_type" == "incremental" ]] \
        || ( [[ "$remote_backup_type" == "full" || "$remote_backup_type" == "database" ]] && [ "$db_driver" == "wpcli" ] ); then
        if [ -z "$(derive_wp_path "$backup_path")" ]; then
            [ "$mode" == "interactive" ] && clear_screen "force"
            echo -e "${RED}The chosen combination requires a WordPress install at '${backup_path}'${RESET}" >&2
            echo -e "${RED}( type=${remote_backup_type}, db-driver=${db_driver} ), but no wp-config.php was found.${RESET}" >&2
            echo -e "${YELLOW}Options: use --type files ( files-only backup of any directory ), or use${RESET}" >&2
            echo -e "${YELLOW}--db-driver mysqldump with explicit --db-name / --db-user / --db-pass.${RESET}" >&2
            return 1
        fi
    fi

    # Validate and sanitize backup_frequency
    if [ -z "$backup_frequency" ] || [[ ! "$backup_frequency" =~ ^(daily|weekly|monthly)$ ]]; then
        [ "$mode" == "interactive" ] && clear_screen "force"
        echo -e "${RED}A valid frequency must be selected from the available options.${RESET}" >&2
        return 1
    fi

    # Validate backup_time
    if [ -z "$backup_time" ] || [[ ! "$backup_time" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
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
            case "/$item/" in
                //|//*|*/../*|*/./*)
                    echo 'Exclusions must be relative paths inside the site.' >&2
                    return 1 ;;
            esac
            # Check if the item exists under the backup_domain path
            if [ -e "${backup_path}/${item}" ]; then
                # Every file reader now runs relative to the selected site.
                printf -v item '%q' "--exclude=${item}"
                excludes+=" $item"

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
            if rclone listremotes | grep -Fxq -- "${rclone_remote_name}:"; then
                break # Remote name is valid, exit the loop
            else
                echo -e "${YELLOW}The remote you entered doesn't exist, please try again.${RESET}"
            fi
        done
    else
        # Headless: the remote was provided via --remote
        rclone_remote_name="${BACKUP_REMOTE}"
        if ! rclone listremotes | grep -Fxq -- "${rclone_remote_name}:"; then
            echo "Error: rclone remote '${rclone_remote_name}' does not exist." >&2
            return 1
        fi
    fi

    # Remember the chosen remote so the repeat-command hint can reference it
    BACKUP_REMOTE="$rclone_remote_name"

    if verify_rclone_destination "$rclone_remote_name" "$remote_backup_location"; then
        rclone_remote_valid=true
        echo 'Remote backup destination passed write, read-back and cleanup checks.'
    else
        echo 'Error: the remote backup destination could not be verified.' >&2
    fi

    # Prepare the backup script and cron job based on frequency, time and the other options.
    if [ $rclone_remote_valid == true ]; then

        # Check if the cron scripts directory exists, and create it if it doesn't
        prepare_operator_directory "$CRON_SCRIPTS_DIR" || return 1

        # Generate a unique name for the backup script based on the frequency and time
        local creation_date=$(date +'%Y-%m-%d %H:%M:%S')
        local script_prefix=$(echo -n "$creation_date-$backup_domain-$cron_expression-$retention_period-$remote_backup_location-$rclone_remote_name-$remote_backup_type" | md5sum | awk '{print $1}') # used to prefix the backup script
        local script_name="${script_prefix}_${backup_time//:/-}_${backup_frequency}"
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
            local restic_remote_config_output=$(RESTIC_PASSWORD="${restic_password}" sudo --preserve-env=RESTIC_PASSWORD restic -r "rclone:${rclone_remote_name}:${remote_backup_location}" cat config 2>&1)
            if echo "$restic_remote_config_output" | grep -q "Is there a repository at the following location"; then

                echo ""
                echo -e "${YELLOW}Initializing remote repository ...${RESET}"
                echo ""

                # If there are no errors, initialize the repo
                RESTIC_PASSWORD="${restic_password}" sudo --preserve-env=RESTIC_PASSWORD restic -r "rclone:${rclone_remote_name}:${remote_backup_location}" init
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
        # Credentials must never be readable between creation and the final chmod.
        if [ -L "$script_path" ]; then
            echo "Refusing a symbolic-link backup script destination." >&2
            return 1
        fi
        (umask 077; : > "$script_path") || return 1
        # Add the starting content for the backup script (eg; variables..etc)
        cat <<EOF >"$script_path"
#!/bin/bash

# Define the call type, whether it's a pre-restore backup, or default backup
if [ \$# -ge 1 ]; then
    call_type=\$1
else
    call_type="backup"
fi

# A failed pre-restore backup must also abort; it is the restore safety boundary.
set -e
set -o pipefail
umask 077

$(declare -f mysql_option_quote mysql_client_options)
$(declare -f prepare_backup_lock)
$(declare -f read_notification_email)
$(declare -f run_site_reader create_site_tar create_site_archive create_incremental_tree)

# Bind the reviewed descriptor-based reader to this standalone generated job.
BACKUP_EXTRACTOR_B64=$(base64 -w0 "$(dirname "${BASH_SOURCE[0]}")/restore-files.py")

# Values are encoded as literal data, including paths containing shell syntax.
LOG_FILE_b64=$(printf '%s' "$LOG_FILE" | base64 -w0)
LOG_FILE=\$(printf '%s' "\${LOG_FILE_b64}" | base64 -d)
LOCK_FILE_b64=$(printf '%s' "$LOCK_FILE" | base64 -w0)
LOCK_FILE=\$(printf '%s' "\${LOCK_FILE_b64}" | base64 -d)
COMPAT_LOCK_FILE_b64=$(printf '%s' "$COMPAT_LOCK_FILE" | base64 -w0)
COMPAT_LOCK_FILE=\$(printf '%s' "\${COMPAT_LOCK_FILE_b64}" | base64 -d)

# Never stage archives in the installation directory, which may itself be served
# by a web server. Every run owns a fresh private directory, with no shared sweep.
tmp_path=\$(mktemp -d /var/tmp/rclone-automated-backups.XXXXXXXXXX)
wp_owner_directory=""
backup_cleanup() {
    local rc=\$?
    trap - EXIT
    if declare -F backup_failure_notify >/dev/null; then
        backup_failure_notify "\$rc"
    fi
    if [ "\${wp_owner_directory}" = "/var/lib/rclone-automated-backups/dumps/\${hash:-}" ] &&
       [ ! -L "\${wp_owner_directory}" ]; then
        rm -f -- "\${wp_owner_directory}/database.sql"
    fi
    case "\${wp_owner_directory}" in
        /var/tmp/rclone-automated-backups-db.*)
            [ ! -L "\${wp_owner_directory}" ] && rm -rf -- "\${wp_owner_directory}" ;;
    esac
    case "\${tmp_path}" in
        /var/tmp/rclone-automated-backups.*)
            [ ! -L "\${tmp_path}" ] && rm -rf -- "\${tmp_path}" ;;
    esac
    exit "\$rc"
}
trap backup_cleanup EXIT

# Logs can contain private database errors. Validate before opening, and retain
# the inode so queued jobs cannot keep writing into a discarded rotated file.
prepare_backup_lock "\${LOG_FILE}"
chmod 600 -- "\${LOG_FILE}"
exec >> "\${LOG_FILE}" 2>&1

# Prepare main variables
type_b64=$(printf '%s' "$remote_backup_type" | base64 -w0)
type=\$(printf '%s' "\${type_b64}" | base64 -d)
hash_b64=$(printf '%s' "$script_hash" | base64 -w0)
hash=\$(printf '%s' "\${hash_b64}" | base64 -d)
creation_date_b64=$(printf '%s' "$creation_date" | base64 -w0)
creation_date=\$(printf '%s' "\${creation_date_b64}" | base64 -d)
cron_expression_b64=$(printf '%s' "$cron_expression" | base64 -w0)
cron_expression=\$(printf '%s' "\${cron_expression_b64}" | base64 -d)
schedule_b64=$(printf '%s' "$schedule" | base64 -w0)
schedule=\$(printf '%s' "\${schedule_b64}" | base64 -d)
schedule_label_b64=$(printf '%s' "$schedule_label" | base64 -w0)
schedule_label=\$(printf '%s' "\${schedule_label_b64}" | base64 -d)
domain_b64=$(printf '%s' "$backup_domain" | base64 -w0)
domain=\$(printf '%s' "\${domain_b64}" | base64 -d)
domain_path_b64=$(printf '%s' "$backup_path" | base64 -w0)
domain_path=\$(printf '%s' "\${domain_path_b64}" | base64 -d)
retention_period_b64=$(printf '%s' "$retention_period" | base64 -w0)
retention_period=\$(printf '%s' "\${retention_period_b64}" | base64 -d)
rclone_remote_b64=$(printf '%s' "$rclone_remote_name" | base64 -w0)
rclone_remote=\$(printf '%s' "\${rclone_remote_b64}" | base64 -d)
remote_backup_location_b64=$(printf '%s' "$remote_backup_location" | base64 -w0)
remote_backup_location=\$(printf '%s' "\${remote_backup_location_b64}" | base64 -d)
# Database driver: wpcli ( reads wp-config.php ) or mysqldump ( uses the
# credentials baked further below via printf %s ).
db_driver_b64=$(printf '%s' "$db_driver" | base64 -w0)
db_driver=\$(printf '%s' "\${db_driver_b64}" | base64 -d)
timestamp=\$(date +'%Y-%m-%d %H:%M:%S')
backup_date=\$(date +'%d-%m-%Y_%H-%M')

# Resolve how to run wp-cli. Standard servers run wp directly; Plesk and cPanel
# may need an explicit PHP binary because no php command is exposed on PATH, or
# ( cPanel's case ) the php on PATH is cgi-fcgi and wp-cli rejects it. We always
# require the CLI SAPI - "(cli)" must appear in php -v's first line.
wp_cli_b64=$(printf '%s' "$wp_cli_path" | base64 -w0)
wp_cli=\$(printf '%s' "\${wp_cli_b64}" | base64 -d)
wp_php=$(printf '%q' "$backup_php_binary")
_is_cli_php() {
    [ -x "\$1" ] && "\$1" -v 2>/dev/null | head -1 | grep -q '(cli)'
}
php_on_path=""
command -v php >/dev/null 2>&1 && php_on_path=\$(command -v php)
if [ -n "\${wp_php}" ]; then
    if ! _is_cli_php "\${wp_php}"; then
        echo 'The configured site PHP CLI is unavailable. Backup stopped rather than changing PHP versions.' >&2
        exit 1
    fi
elif [ -n "\${php_on_path}" ] && _is_cli_php "\${php_on_path}"; then
    : # PATH php is CLI - leave wp_php empty so wp's shebang finds it
else
    php_candidates=""
    php_candidates="\${php_candidates} \$(find /opt/plesk/php -mindepth 3 -maxdepth 3 -path '*/bin/php' -type f -perm -111 2>/dev/null | sort -Vr)"
    php_candidates="\${php_candidates} \$(find /opt/cpanel -mindepth 5 -maxdepth 5 -path '*/ea-php*/root/usr/bin/php' -type f -perm -111 2>/dev/null | sort -Vr)"
    php_candidates="\${php_candidates} /usr/local/bin/php /usr/bin/php"
    for php_candidate in \${php_candidates}; do
        if _is_cli_php "\${php_candidate}"; then
            wp_php="\${php_candidate}"
            break
        fi
    done
fi
unset -f _is_cli_php

run_wp_cli_as() {
    local wp_user="\$1"
    shift
    if [ "\$(id -u "\${wp_user}")" -eq 0 ]; then
        echo 'WordPress backups require a non-root site owner.' >&2
        return 1
    fi
    # Child processes such as mysqldump need a working directory the site user
    # can traverse; root's installation directory is commonly inaccessible.
    (
        cd "\${domain_path}" || exit 1
        if [ -n "\${wp_php}" ]; then
            sudo -u "\${wp_user}" -- "\${wp_php}" "\${wp_cli}" "\$@"
        else
            sudo -u "\${wp_user}" -- "\${wp_cli}" "\$@"
        fi
    )
}

# wp-cli and PHP are only needed when the database step uses the wp-cli driver.
# A files-only backup or a mysqldump-driven dump does not need them, so skip
# the guards in those cases.
if [ "\${type}" != "files" ] && [ "\${db_driver}" != "mysqldump" ]; then
    if [ ! -f "\${wp_cli}" ]; then
        echo "[\${timestamp}] ERROR: wp-cli not found at '\${wp_cli}'. Aborting backup." >> "\${LOG_FILE}"
        exit 1
    fi

    if [ -z "\${wp_php}" ] && ! command -v php >/dev/null 2>&1; then
        echo "[\${timestamp}] ERROR: PHP is not on PATH and no fallback binary was found under /opt/plesk/php, /opt/cpanel/ea-php*/root/usr/bin, /usr/local/bin, or /usr/bin. Aborting backup." >> "\${LOG_FILE}"
        exit 1
    fi
fi

# Email a failure alert if this backup exits with an error ( one alert per failed run ).
# The address is read from the definitions file at run time, so it can be changed centrally.
definitions_file_b64=$(printf '%s' "$PWD/$DEFINITIONS_FILE" | base64 -w0)
definitions_file=\$(printf '%s' "\${definitions_file_b64}" | base64 -d)
backup_failure_notify() {
    local rc=\$1
    set +e
    [ \$rc -eq 0 ] && return
    local notify_email=""
    notify_email=\$(read_notification_email "\${definitions_file}" 2>/dev/null) || return
    [ -z "\${notify_email}" ] && return
    local subject="[Backup FAILED] \${domain} (\${type})"
    local mail_body="Automated \${type} backup for '\${domain}' failed with exit code \${rc}.
Server time: \$(date)

--- last 30 log lines ---
\$(tail -n 30 "\${LOG_FILE}" 2>/dev/null)"
    if command -v mail >/dev/null 2>&1; then
        printf '%s\n' "\${mail_body}" | mail -s "\${subject}" "\${notify_email}"
    elif command -v sendmail >/dev/null 2>&1; then
        printf 'Subject: %s\nTo: %s\n\n%s\n' "\${subject}" "\${notify_email}" "\${mail_body}" | sendmail -t
    fi
}

# A "last day of month" schedule runs daily but only acts on the month's final
# day. Only scheduled cron runs ( call_type=backup ) are skipped - the initial
# backup and a pre-restore backup must always run, whatever the day.
if [ "\${call_type}" = "backup" ] && [ "\${schedule}" = "monthly-last" ] && [ "\$(date -d tomorrow +%d)" != "01" ]; then
    exit 0
fi

# --- Serialize backup runs across all sites ( prevents server overload ) ---
# Acquire shared locks so that, however many cron entries fire together, the
# heavy work ( tar / rclone / restic ) runs strictly one site at a time. Two
# lock files are used: the current one and the legacy "-by-alikhallad" one
# from before the rename. Old scripts ( generated before the rename ) only
# lock the legacy file; this script locks both, so we mutually exclude with
# old in-flight scripts via the shared legacy file and with peer new scripts
# via either file. The order ( COMPAT then NEW ) is fixed across every caller
# to prevent AB-BA deadlock.
prepare_backup_lock "\${COMPAT_LOCK_FILE}"
prepare_backup_lock "\${LOCK_FILE}"
exec {lock_fd_compat}<>"\${COMPAT_LOCK_FILE}"
exec {lock_fd}<>"\${LOCK_FILE}"
if ! flock -n "\${lock_fd_compat}" || ! flock -n "\${lock_fd}"; then
    echo "[\$(date +'%Y-%m-%d %H:%M:%S')] BACK UP QUEUED (\${type}): waiting for another backup to finish for '\${domain}'" >> "\${LOG_FILE}"
    if ! flock -w $lock_timeout "\${lock_fd_compat}" || ! flock -w $lock_timeout "\${lock_fd}"; then
        echo "[\$(date +'%Y-%m-%d %H:%M:%S')] BACK UP SKIPPED (\${type}): lock busy, timed out for '\${domain}'" >> "\${LOG_FILE}"
        # A missed scheduled backup is also a failure and must reach monitoring.
        exit 75
    fi
fi

# Rotate after obtaining the shared backup lock, using this run's private path.
if [ "\$(stat -c %s -- "\${LOG_FILE}")" -gt 1048576 ]; then
    tail -c 1048576 -- "\${LOG_FILE}" > "\${tmp_path}/log-tail"
    cat "\${tmp_path}/log-tail" > "\${LOG_FILE}"
fi

echo "[\${timestamp}] BACK UP STARTED (\${type}): Performing $backup_time $backup_frequency backup for '\${domain}'" >> "\${LOG_FILE}"
echo "[\${timestamp}] - Exporting database" >> "\${LOG_FILE}"

EOF

        # Bake mysqldump credentials into the script when the mysqldump driver
        # is selected. Values are stored base64-encoded so any byte sequence -
        # including ", ', $, \, =, spaces, control chars - survives both bash
        # parsing of the assignment line AND grep extraction at restore time.
        # The script is chmod 700 ( root-readable only ).
        if [ "$db_driver" == "mysqldump" ]; then
            # Fail early at script-creation time if base64 is missing on the
            # server doing the create. base64 is part of GNU coreutils and is
            # present on every supported Linux distribution, but checking now
            # turns a silent runtime failure into a clear setup error.
            if ! command -v base64 >/dev/null 2>&1; then
                echo -e "${RED}base64 is required for the mysqldump driver but was not found on PATH.${RESET}" >&2
                echo -e "${YELLOW}Install coreutils ( apt install coreutils / yum install coreutils ) and retry.${RESET}" >&2
                return 1
            fi
            printf 'db_name_b64=%s\n' "$(printf '%s' "$db_name" | base64 -w0)" >> "$script_path"
            printf 'db_user_b64=%s\n' "$(printf '%s' "$db_user" | base64 -w0)" >> "$script_path"
            printf 'db_pass_b64=%s\n' "$(printf '%s' "$db_pass" | base64 -w0)" >> "$script_path"
            printf 'db_host_b64=%s\n' "$(printf '%s' "$db_host" | base64 -w0)" >> "$script_path"
            # Decode into runtime vars so the dispatch branches can reference
            # them by their plain names just like any other baked variable.
            # The runtime guard below catches the rare case where base64 was
            # removed AFTER the script was generated.
            cat >> "$script_path" <<'CREDS_DECODE'
if ! command -v base64 >/dev/null 2>&1; then
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: base64 not found - mysqldump credentials cannot be decoded. Aborting backup."
    exit 1
fi
db_name=$(printf '%s' "$db_name_b64" | base64 -d)
db_user=$(printf '%s' "$db_user_b64" | base64 -d)
db_pass=$(printf '%s' "$db_pass_b64" | base64 -d)
db_host=$(printf '%s' "$db_host_b64" | base64 -d)
CREDS_DECODE
        fi

        # Append to the script based on the backup type
        if [ $remote_backup_type == "incremental" ]; then
            local restic_password_b64
            restic_password_b64=$(printf '%s' "$restic_password" | base64 -w 0)
            # Stable private dump path lets restore select the database explicitly
            # without putting SQL in the document root or restoring filesystem '/'.
            cat <<EOF >>"$script_path"
# Get the wp installation folder owner and their home directory
wp_owner=\$(sudo stat -c "%U" "\${domain_path}")

# Get the database name and construct the db backup file name and path
# Note that we are using sudo to run wp cli commands as "wp_owner" to avoid permissions complications
db_name=\$(run_wp_cli_as "\${wp_owner}" config get DB_NAME --path="\${domain_path}" --skip-plugins --skip-themes)
db_snapshot_path="/var/lib/rclone-automated-backups/dumps/${script_hash}/database.sql"
install -d -m 700 /var/lib/rclone-automated-backups /var/lib/rclone-automated-backups/dumps
wp_owner_directory="\${db_snapshot_path%/*}"
test ! -L "\${wp_owner_directory}"
install -d -m 700 -o root "\${wp_owner_directory}"
rm -f -- "\${db_snapshot_path}"
test ! -L "\${db_snapshot_path}"
if ! run_wp_cli_as "\${wp_owner}" db export - --path="\${domain_path}" --single-transaction --quick --skip-plugins --skip-themes > "\${db_snapshot_path}"; then
    echo "[\${timestamp}] ERROR: database export failed. Aborting backup." >>"\${LOG_FILE}"
    exit 1
fi

restic_password_b64=${restic_password_b64}
restic_password=\$(printf '%s' "\${restic_password_b64}" | base64 -d)

echo "[\${timestamp}] - Sending the backup to 'rclone' "\${rclone_remote}" remote  using 'restic'" >>"\${LOG_FILE}"

# Restic must not traverse a mutable website tree as root. Read it as the
# website owner, then materialize the checked archive inside root-only storage.
# The mirrored path retains existing restic subtree restore selectors.
snapshot_root="\${tmp_path}/incremental-tree"
printf '%s' "\${BACKUP_EXTRACTOR_B64}" | base64 -d > "\${tmp_path}/extractor.py"
if [ "\${call_type}" = restore ]; then
    create_incremental_tree "\${domain_path}" "\${tmp_path}" "\${tmp_path}/extractor.py"
else
    create_incremental_tree "\${domain_path}" "\${tmp_path}" "\${tmp_path}/extractor.py" ${excludes}
fi
if ! (cd "\${snapshot_root}" && RESTIC_PASSWORD="\${restic_password}" sudo --preserve-env=RESTIC_PASSWORD restic -q -r "rclone:\${rclone_remote}:\${remote_backup_location}" backup "\${domain_path#/}/" "\${db_snapshot_path}"); then
    echo "[\${timestamp}] ERROR: restic backup failed. Aborting backup." >>"\${LOG_FILE}"
    exit 1
fi

echo "[\${timestamp}] - backup sent to the remote location successfully" >>"\${LOG_FILE}"
echo "[\${timestamp}] - Delete the internally generated backup files to free space" >>"\${LOG_FILE}"

# Delete the generated database file
sudo rm "\${db_snapshot_path}"

echo "[\${timestamp}] - Delete backups older than \${retention_period} days from 'rclone' "\${rclone_remote}" remote using 'restic'" >>"\${LOG_FILE}"

# Delete old backups from remote ( retention logic )
RESTIC_PASSWORD="\${restic_password}" sudo --preserve-env=RESTIC_PASSWORD restic -q -r "rclone:\${rclone_remote}:\${remote_backup_location}" forget --keep-within "\${retention_period}d" --prune

EOF

        elif [ $remote_backup_type == "database" ]; then
            # Add the necessary commands for database-only backups (append to file, note >>)
            cat <<EOF >>"$script_path"

# Get the wp installation folder owner
wp_owner=\$(sudo stat -c "%U" "\${domain_path}")

# Use a fresh private directory, outside the document root, for database backups.
wp_owner_directory=\$(mktemp -d /var/tmp/rclone-automated-backups-db.XXXXXXXXXX)
chmod 700 "\${wp_owner_directory}"

echo "[\${timestamp}] - WP folder owner found: '\${wp_owner}'" >> "\${LOG_FILE}"
echo "[\${timestamp}] - Using temp directory: '\${wp_owner_directory}'" >> "\${LOG_FILE}"


# Export the database using either wp-cli ( reads wp-config.php ) or mysqldump
# ( uses the credentials baked at the top of this script ). mysqldump passes
# credentials via --defaults-extra-file so they never appear in argv.
if [ "\${db_driver}" = "mysqldump" ]; then
    db_filename=\${hash}_database_\${backup_date}.sql
    my_cnf="\${wp_owner_directory}/.bk-\${hash}.cnf"
    umask 077
    mysql_client_options "\${db_user}" "\${db_pass}" "\${db_host}" > "\${my_cnf}"
    if ! sudo mysqldump --defaults-extra-file="\${my_cnf}" --single-transaction --quick --routines --events --triggers -- "\${db_name}" > "\${wp_owner_directory}/\${db_filename}"; then
        echo "[\${timestamp}] ERROR: mysqldump export failed. Aborting backup." >> "\${LOG_FILE}"
        sudo rm -f "\${my_cnf}" "\${wp_owner_directory}/\${db_filename}"
        exit 1
    fi
    sudo rm -f "\${my_cnf}"
else
    db_name=\$(run_wp_cli_as "\${wp_owner}" config get DB_NAME --path="\${domain_path}" --skip-plugins --skip-themes)
    db_filename=\${hash}_database_\${backup_date}.sql
    if ! run_wp_cli_as "\${wp_owner}" db export - --path="\${domain_path}" --skip-plugins --skip-themes > "\${wp_owner_directory}/\${db_filename}"; then
        echo "[\${timestamp}] ERROR: database export failed. Aborting backup." >> "\${LOG_FILE}"
        sudo rm -f "\${wp_owner_directory}/\${db_filename}"
        exit 1
    fi
fi

echo "[\${timestamp}] - Compressing the database export" >> "\${LOG_FILE}"

# Compress the SQL dump to reduce transfer size and remote storage usage
if ! sudo gzip -f "\${wp_owner_directory}/\${db_filename}"; then
    echo "[\${timestamp}] ERROR: database compression failed. Aborting backup." >> "\${LOG_FILE}"
    sudo rm -f "\${wp_owner_directory}/\${db_filename}" "\${wp_owner_directory}/\${db_filename}.gz"
    exit 1
fi
db_archive="\${wp_owner_directory}/\${db_filename}.gz"

echo "[\${timestamp}] - Sending the database backup to remote location "\${rclone_remote}" using rclone" >> "\${LOG_FILE}"

# Copy the compressed database backup to the remote location using rclone
if ! sudo rclone copy "\${db_archive}" "\${rclone_remote}:\${remote_backup_location}"; then
    echo "[\${timestamp}] ERROR: rclone copy failed. Aborting backup." >> "\${LOG_FILE}"
    sudo rm -f "\${db_archive}"
    exit 1
fi

echo "[\${timestamp}] - database backup sent to the remote location successfully" >> "\${LOG_FILE}"
echo "[\${timestamp}] - Delete the internally generated database backup to free space" >> "\${LOG_FILE}"

# Delete the locally generated database archive
sudo rm -f "\${db_archive}"

echo "[\${timestamp}] - Delete backups older than \${retention_period} days from remote location "\${rclone_remote}" using rclone" >> "\${LOG_FILE}"

# Delete old backups from remote ( retention logic )
sudo rclone delete --min-age "\${retention_period}d" --include "\${hash}_*" "\${rclone_remote}:\${remote_backup_location}"

EOF

        elif [ $remote_backup_type == "files" ]; then
            # Files-only backup: tar the target directory ( no database, no
            # WordPress assumptions ). Mirrors the full branch minus the DB
            # hunks so non-WP folders can be backed up by the same tool.
            cat <<EOF >>"$script_path"

if [ \${call_type} == "restore" ]; then
    echo "[\${timestamp}] - Generating pre-restore backup archive" >> "\${LOG_FILE}"
    backup_filename=\${tmp_path}/\${hash}_site_\${backup_date}-pre-restore.tar.gz
else
    echo "[\${timestamp}] - Generating backup archive" >> "\${LOG_FILE}"
    backup_filename=\${tmp_path}/\${hash}_site_\${backup_date}.tar.gz
fi

# --- Backup Logic ---

echo "[\${timestamp}] - Attempting direct tar backup" >> "\${LOG_FILE}"

backup_success=false

if sudo test "\${call_type}" = "restore"; then
    # Pre-restore: tar without excludes so the restore-baseline is complete
    if create_site_archive "\${backup_filename}.tmp" "\${domain_path}" '' 2>> "\${LOG_FILE}"; then
        backup_success=true
        echo "[\${timestamp}] - Direct tar backup successful" >> "\${LOG_FILE}"
    else
        echo "[\${timestamp}] - Direct tar backup failed" >> "\${LOG_FILE}"
    fi
else
    # Scheduled run: apply excludes
    if create_site_archive "\${backup_filename}.tmp" "\${domain_path}" '' $excludes 2>> "\${LOG_FILE}"; then
        backup_success=true
        echo "[\${timestamp}] - Direct tar backup successful" >> "\${LOG_FILE}"
    else
        echo "[\${timestamp}] - Direct tar backup failed" >> "\${LOG_FILE}"
    fi
fi

if [ "\$backup_success" = false ]; then
    echo "[\${timestamp}] ERROR: tar backup failed" >> "\${LOG_FILE}"
    sudo rm -f "\${backup_filename}.tmp"
    exit 1
fi

# Rename the temporary backup file to the actual name to indicate that the compression completed
sudo mv "\${backup_filename}.tmp" "\${backup_filename}"

# --- End Backup Logic ---

echo "[\${timestamp}] - backup archive generated: "\${backup_filename}"" >> "\${LOG_FILE}"
echo "[\${timestamp}] - Sending the backup file to remote location "\${rclone_remote}" using rclone" >> "\${LOG_FILE}"

# Copy the generated backup to the remote location using rclone
if ! sudo rclone copy "\${backup_filename}" "\${rclone_remote}:\${remote_backup_location}"; then
    echo "[\${timestamp}] ERROR: rclone copy failed. Aborting backup." >> "\${LOG_FILE}"
    sudo rm -f "\${backup_filename}"
    exit 1
fi

echo "[\${timestamp}] - backup file sent to the remote location successfully" >> "\${LOG_FILE}"
echo "[\${timestamp}] - Delete the internally generated backup files to free space" >> "\${LOG_FILE}"

# Delete the generated backup archive
sudo rm -- "\${backup_filename}"

echo "[\${timestamp}] - Delete backups older than \${retention_period} days from remote location "\${rclone_remote}" using rclone" >> "\${LOG_FILE}"

# Delete old backups from remote ( retention logic )
sudo rclone delete --min-age "\${retention_period}d" --include "\${hash}_*" "\${rclone_remote}:\${remote_backup_location}"

EOF

        else
            # Add the necessary commands for full backups (append to file, note >>)
            cat <<EOF >>"$script_path"

# Get the wp installation folder owner
wp_owner=\$(sudo stat -c "%U" "\${domain_path}")

# Use a fresh private directory, outside the document root, for database backups.
wp_owner_directory=\$(mktemp -d /var/tmp/rclone-automated-backups-db.XXXXXXXXXX)
chmod 700 "\${wp_owner_directory}"

echo "[\${timestamp}] - WP folder owner found: '\${wp_owner}'" >> "\${LOG_FILE}"
echo "[\${timestamp}] - Using temp directory: '\${wp_owner_directory}'" >> "\${LOG_FILE}"


# Get wp-config.php location (one level up from domain_path for WordOps)
wp_config_path="\${domain_path}"
if [[ "\${domain_path}" == */htdocs ]]; then
    wp_config_path="\${domain_path%/htdocs}"
fi

# Export the database using either wp-cli ( reads wp-config.php ) or mysqldump
# ( uses the credentials baked at the top of this script ).
if [ "\${db_driver}" = "mysqldump" ]; then
    db_filename=\${hash}_database_\${backup_date}.sql
    my_cnf="\${wp_owner_directory}/.bk-\${hash}.cnf"
    umask 077
    mysql_client_options "\${db_user}" "\${db_pass}" "\${db_host}" > "\${my_cnf}"
    if ! sudo mysqldump --defaults-extra-file="\${my_cnf}" --single-transaction --quick --routines --events --triggers -- "\${db_name}" > "\${wp_owner_directory}/\${db_filename}"; then
        echo "[\${timestamp}] ERROR: mysqldump export failed. Aborting backup." >> "\${LOG_FILE}"
        sudo rm -f "\${my_cnf}" "\${wp_owner_directory}/\${db_filename}"
        exit 1
    fi
    sudo rm -f "\${my_cnf}"
else
    db_name=\$(run_wp_cli_as "\${wp_owner}" config get DB_NAME --path="\${domain_path}" --skip-plugins --skip-themes)
    db_filename=\${hash}_database_\${backup_date}.sql
    if ! run_wp_cli_as "\${wp_owner}" db export - --path="\${domain_path}" --skip-plugins --skip-themes > "\${wp_owner_directory}/\${db_filename}"; then
        echo "[\${timestamp}] ERROR: database export failed. Aborting backup." >> "\${LOG_FILE}"
        sudo rm -f "\${wp_owner_directory}/\${db_filename}"
        exit 1
    fi
fi

if [ \${call_type} == "restore" ]; then
    echo "[\${timestamp}] - Generating pre-restore backup archive" >> "\${LOG_FILE}"
    backup_filename=\${tmp_path}/\${hash}_site_\${backup_date}-pre-restore.tar.gz
else
    echo "[\${timestamp}] - Generating backup archive" >> "\${LOG_FILE}"
    backup_filename=\${tmp_path}/\${hash}_site_\${backup_date}.tar.gz
fi

# --- Backup Logic ---

# Source files are read as the site owner; append only the root-private SQL.
# The helper retains the changing-files snapshot fallback and its space check.
archive_excludes=($excludes)
[ "\${call_type}" != "restore" ] || archive_excludes=()
if ! create_site_archive "\${backup_filename}.tmp" "\${domain_path}" "\${wp_owner_directory}/\${db_filename}" "\${archive_excludes[@]}"; then
    echo "[\${timestamp}] ERROR: Site archive failed" >> "\${LOG_FILE}"
    exit 1
fi

# Rename the temporary backup file to the actual name to indicate that the compression completed
sudo mv "\${backup_filename}.tmp" "\${backup_filename}"

# --- End Backup Logic ---

echo "[\${timestamp}] - backup archive generated: "\${backup_filename}"" >> "\${LOG_FILE}"
echo "[\${timestamp}] - Sending the backup file to remote location "\${rclone_remote}" using rclone" >> "\${LOG_FILE}"

# Copy the generated backup to the remote location using rclone
if ! sudo rclone copy "\${backup_filename}" "\${rclone_remote}:\${remote_backup_location}"; then
    echo "[\${timestamp}] ERROR: rclone copy failed. Aborting backup." >> "\${LOG_FILE}"
    sudo rm -f "\${backup_filename}" "\${wp_owner_directory}/\${db_filename}"
    exit 1
fi

echo "[\${timestamp}] - backup file sent to the remote location successfully" >> "\${LOG_FILE}"
echo "[\${timestamp}] - Delete the internally generated backup files to free space" >> "\${LOG_FILE}"

# Delete the generated backup archive and database
sudo rm -- "\${backup_filename}"
sudo rm -- "\${wp_owner_directory}/\${db_filename}"

echo "[\${timestamp}] - Delete backups older than \${retention_period} days from remote location "\${rclone_remote}" using rclone" >> "\${LOG_FILE}"

# Delete old backups from remote ( retention logic )
sudo rclone delete --min-age "\${retention_period}d" --include "\${hash}_*" "\${rclone_remote}:\${remote_backup_location}"

EOF
        fi

        # Add the final content of the script file (append to file, note >>)
        cat <<EOF >>"$script_path"
echo "[\${timestamp}] BACK UP FINISHED (\${type}): $backup_frequency backup for \${domain} has completed successfully" >> "\${LOG_FILE}"

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
        # Add the cron job, unless an identical entry ( or one for the same script )
        # already exists in either the current or legacy cron file.
        #
        # The grep-then-append is guarded by an exclusive flock so concurrent
        # headless runs ( eg; a bulk rollout that scripts 30 sites in parallel )
        # cannot race and produce duplicate cron lines.
        local cron_script cron_line
        printf -v cron_script '%q' "$PWD/$script_path"
        # Cron interprets percent signs before passing its command to a shell.
        cron_script="${cron_script//%/\\%}"
        cron_line="$cron_expression root /bin/bash $cron_script"
        (
            prepare_backup_lock /tmp/rclone-automated-backups-cron-write.lock || return 1
            exec 8<>"/tmp/rclone-automated-backups-cron-write.lock"
            flock 8
            if grep -Fqx "$cron_line" "$CRON_FILE" "$COMPAT_CRON_FILE" 2>/dev/null \
                || grep -Fq "$(basename "$script_path")" "$CRON_FILE" "$COMPAT_CRON_FILE" 2>/dev/null; then
                echo -e "${YELLOW}A cron entry for this backup already exists, skipping cron update.${RESET}"
            else
                echo "$cron_line" >>"$CRON_FILE"
            fi
        )

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
                return 1
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
    # mysqldump-driven backups need their own credentials; same placeholder
    # treatment for the password.
    if [ "${DB_DRIVER:-wpcli}" == "mysqldump" ]; then
        hint+=" --db-driver \"mysqldump\""
        hint+=" --db-name \"$DB_NAME\""
        hint+=" --db-user \"$DB_USER\""
        hint+=" --db-pass \"<your-db-password>\""
        [ -n "$DB_HOST" ] && [ "$DB_HOST" != "localhost" ] && hint+=" --db-host \"$DB_HOST\""
    fi
    hint+=" --yes"

    echo -e "${BOLD}To create this backup again ( or script it ), run:${RESET}"
    echo -e "${GREEN}${hint}${RESET}"
    [ "$BACKUP_TYPE" == "incremental" ] && echo -e "${YELLOW}Replace <your-restic-password> with the password you set for this backup.${RESET}"
    [ "${DB_DRIVER:-wpcli}" == "mysqldump" ] && echo -e "${YELLOW}Replace <your-db-password> with the database password you supplied.${RESET}"
    echo ""
}
