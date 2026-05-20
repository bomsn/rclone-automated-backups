#!/bin/bash

# Headless / non-interactive mode: create one backup straight from CLI flags.

# Print headless usage to stderr ( optionally prefixed with an error message ).
headless_usage() {
    [ -n "$1" ] && echo "Error: $1" >&2
    cat >&2 <<'USAGE'

Usage: sudo bash config.sh --domain <d> --type <t> --frequency <f> \
       --time <HH:MM> --retention <n> --remote <r> --location <loc> [options]

Required:
  --domain     <domain>   site domain ( stored, or new together with --path )
  --type       <type>     full | incremental | database
  --frequency  <freq>     daily | weekly | monthly
  --time       <HH:MM>    backup time in the SERVER's timezone ( eg; 02:00 )
  --retention  <days>     3 | 7 | 30 | 90 | 180
  --remote     <name>     rclone remote name
  --location   <path>     backup location on the remote

Conditional / optional:
  --path       <path>     WordPress path; required when --domain is new
  --day        <day>      required for weekly ( monday..sunday ) and monthly
                          ( 1..28 or last ); not allowed with daily
  --exclude    <list>     comma-separated paths, or "none"; omit to
                          auto-detect cache / junk folders
  --password   <pass>     required for --type incremental
  --yes                   assume yes to confirmations
USAGE
}

# Create one backup non-interactively from --flag value arguments.
# Returns 2 on any invalid/missing flag, otherwise the exit code of the
# shared generation core.
run_headless() {
    BACKUP_DOMAIN="" BACKUP_TYPE="" BACKUP_FREQUENCY="" BACKUP_DAY=""
    BACKUP_TIME="" RETENTION_PERIOD="" BACKUP_REMOTE="" REMOTE_BACKUP_LOCATION=""
    BACKUP_PASS="" EXCLUDED_ITEMS="" ASSUME_YES=false
    local hl_path="" hl_day="" hl_exclude_set=false
    local flag val

    # --- parse --flag value arguments ---
    while [ $# -gt 0 ]; do
        flag="$1"
        case "$flag" in
        --yes)
            ASSUME_YES=true
            shift
            continue
            ;;
        --domain | --path | --type | --frequency | --day | --time | --retention | --remote | --location | --exclude | --password)
            if [ $# -lt 2 ]; then
                headless_usage "option $flag requires a value"
                return 2
            fi
            val="$2"
            shift 2
            ;;
        *)
            headless_usage "unknown option '$flag'"
            return 2
            ;;
        esac
        case "$flag" in
        --domain) BACKUP_DOMAIN="$val" ;;
        --path) hl_path="$val" ;;
        --type) BACKUP_TYPE="$val" ;;
        --frequency) BACKUP_FREQUENCY="$val" ;;
        --day) hl_day="$val" ;;
        --time) BACKUP_TIME="$val" ;;
        --retention) RETENTION_PERIOD="$val" ;;
        --remote) BACKUP_REMOTE="$val" ;;
        --location) REMOTE_BACKUP_LOCATION="$val" ;;
        --exclude)
            EXCLUDED_ITEMS="$val"
            hl_exclude_set=true
            ;;
        --password) BACKUP_PASS="$val" ;;
        esac
    done

    # --- required flags ---
    [ -n "$BACKUP_DOMAIN" ] || { headless_usage "--domain is required"; return 2; }
    [ -n "$BACKUP_TYPE" ] || { headless_usage "--type is required"; return 2; }
    [ -n "$BACKUP_FREQUENCY" ] || { headless_usage "--frequency is required"; return 2; }
    [ -n "$BACKUP_TIME" ] || { headless_usage "--time is required"; return 2; }
    [ -n "$RETENTION_PERIOD" ] || { headless_usage "--retention is required"; return 2; }
    [ -n "$BACKUP_REMOTE" ] || { headless_usage "--remote is required"; return 2; }
    [ -n "$REMOTE_BACKUP_LOCATION" ] || { headless_usage "--location is required"; return 2; }

    # Drop a single trailing slash from the location, matching the interactive prompt
    REMOTE_BACKUP_LOCATION="${REMOTE_BACKUP_LOCATION%/}"

    # --- value validation ( same rules as the interactive prompts ) ---
    case "$BACKUP_TYPE" in
    full | incremental | database) ;;
    *)
        headless_usage "--type must be full, incremental or database"
        return 2
        ;;
    esac
    case "$BACKUP_FREQUENCY" in
    daily | weekly | monthly) ;;
    *)
        headless_usage "--frequency must be daily, weekly or monthly"
        return 2
        ;;
    esac
    if [[ ! "$BACKUP_TIME" =~ ^[0-9]{2}:[0-9]{2}$ ]]; then
        headless_usage "--time must be HH:MM ( eg; 02:00 )"
        return 2
    fi
    if [[ ! "$RETENTION_PERIOD" =~ ^(3|7|30|90|180)$ ]]; then
        headless_usage "--retention must be 3, 7, 30, 90 or 180"
        return 2
    fi

    # --- incremental needs restic available and a password ---
    if [ "$BACKUP_TYPE" == "incremental" ]; then
        if [ "$RESTIC_AVAILABLE" != true ]; then
            headless_usage "--type incremental requires restic to be installed"
            return 2
        fi
        if [ -z "$BACKUP_PASS" ]; then
            headless_usage "--password is required for --type incremental"
            return 2
        fi
    fi

    # --- day: required for weekly / monthly, not allowed for daily ---
    case "$BACKUP_FREQUENCY" in
    daily)
        if [ -n "$hl_day" ]; then
            headless_usage "--day is not valid with --frequency daily"
            return 2
        fi
        BACKUP_DAY=""
        ;;
    weekly)
        if [ -z "$hl_day" ]; then
            headless_usage "--day is required for --frequency weekly"
            return 2
        fi
        case "${hl_day,,}" in
        monday) BACKUP_DAY="Monday" ;;
        tuesday) BACKUP_DAY="Tuesday" ;;
        wednesday) BACKUP_DAY="Wednesday" ;;
        thursday) BACKUP_DAY="Thursday" ;;
        friday) BACKUP_DAY="Friday" ;;
        saturday) BACKUP_DAY="Saturday" ;;
        sunday) BACKUP_DAY="Sunday" ;;
        *)
            headless_usage "--day must be a weekday name ( monday..sunday )"
            return 2
            ;;
        esac
        ;;
    monthly)
        if [ -z "$hl_day" ]; then
            headless_usage "--day is required for --frequency monthly"
            return 2
        fi
        if [ "${hl_day,,}" == "last" ]; then
            BACKUP_DAY="last"
        elif [[ "$hl_day" =~ ^[0-9]+$ ]] && [ "$hl_day" -ge 1 ] && [ "$hl_day" -le 28 ]; then
            BACKUP_DAY="$hl_day"
        else
            headless_usage "--day must be 1-28 or 'last' for --frequency monthly"
            return 2
        fi
        ;;
    esac

    # --- domain / path resolution ---
    local known_path
    known_path=$(resolve_domain_path "$BACKUP_DOMAIN")
    if [ -n "$known_path" ]; then
        # Domain already stored: --path is optional but must match if supplied
        if [ -n "$hl_path" ] && [ "${hl_path%/}" != "${known_path%/}" ]; then
            headless_usage "--path '$hl_path' does not match the stored path for '$BACKUP_DOMAIN' ( $known_path )"
            return 2
        fi
    else
        # New domain: --path is required and must hold a WordPress install
        if [ -z "$hl_path" ]; then
            headless_usage "--path is required for the new domain '$BACKUP_DOMAIN'"
            return 2
        fi
        if [[ ! "$hl_path" == /* ]]; then
            hl_path="/$hl_path"
        fi
        hl_path="${hl_path%/}"
        local resolved
        resolved=$(derive_wp_path "$hl_path")
        if [ -z "$resolved" ]; then
            headless_usage "no WordPress installation found under '$hl_path'"
            return 2
        fi
        DOMAINS+=("$BACKUP_DOMAIN")
        PATHS+=("$resolved")
        update_definitions
    fi

    # --- excludes: explicit list, "none", or auto-detect when omitted ---
    if [ "$hl_exclude_set" == true ]; then
        if [ "${EXCLUDED_ITEMS,,}" == "none" ]; then
            EXCLUDED_ITEMS=""
        fi
        # otherwise EXCLUDED_ITEMS already holds the supplied comma-separated list
    else
        # Not supplied: auto-detect cache / junk folders under the site
        local site_path detected
        site_path=$(resolve_domain_path "$BACKUP_DOMAIN")
        EXCLUDED_ITEMS=""
        while IFS= read -r detected; do
            [ -z "$detected" ] && continue
            if [ -z "$EXCLUDED_ITEMS" ]; then
                EXCLUDED_ITEMS="$detected"
            else
                EXCLUDED_ITEMS="$EXCLUDED_ITEMS, $detected"
            fi
        done < <(detect_excludes "$site_path")
    fi

    # All settings resolved - hand off to the shared generation core
    create_backup_from_settings "headless"
    return $?
}
