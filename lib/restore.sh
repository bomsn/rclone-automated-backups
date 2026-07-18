#!/bin/bash

# Restore-destination resolution for the "View/restore remote backups" flow.
#
# Every restore either lands on the ORIGIN ( live ) site — today's behaviour,
# preserved byte-for-byte — or on a STAGING target the operator names at restore
# time. Staging mode redirects every file write and the database import to a path
# and DB the operator specifies, and refuses to run if the resolved target
# collides with the origin path or origin database. This is what lets a backup be
# test-restored without any risk of clobbering the live site.
#
# The functions here set RESTORE_* globals that lib/backup-manage.sh consumes:
#   RESTORE_MODE              origin | staging
#   RESTORE_TARGET_PATH       effective files directory the restore writes into
#   RESTORE_DB_MODE           origin | wpconfig | explicit | none
#   RESTORE_DB_NAME/USER/PASS/HOST   explicit staging DB credentials
#   RESTORE_URL_NEW           URL to stamp on the staged copy after import
#   RESTORE_URL_OLD           origin URL found in the imported DB ( set at rewrite )
#   RESTORE_PRESERVE_WPCONFIG staging wp-config.php to protect across a file restore
#   RESTORE_WPCONFIG_STASH    temp copy of that wp-config ( internal )

# Resolve the origin database name so we can guard against a staging target that
# would overwrite the live database. wpcli backups read it from the origin's
# wp-config.php; mysqldump backups carry it base64-encoded in the backup script.
resolve_origin_db_name() {
    local origin_path="$1"
    local backup_script="$2"

    # This flow runs under the script's global "set -e" ( set in
    # manage_automated_backups ). These captures legitimately exit non-zero — a
    # grep with no match on a legacy script, or wp-cli on an unreadable install —
    # so use the masked "local VAR=$(...)" form: the "local" builtin's own exit
    # status ( always 0 ) swallows the failure that would otherwise abort the tool.
    local driver=$(grep -oP 'db_driver="\K[^"]+' "$backup_script" 2>/dev/null)
    [ -z "$driver" ] && driver="wpcli"

    if [ "$driver" == "mysqldump" ]; then
        grep -oP '^db_name_b64=\K.*' "$backup_script" 2>/dev/null | base64 -d 2>/dev/null
    else
        local owner=$(sudo stat -c "%U" "$origin_path" 2>/dev/null)
        run_wp_cli_as "$owner" config get DB_NAME --path="$origin_path" --skip-plugins --skip-themes 2>/dev/null
    fi
}

# Prompt for and validate the restore destination. Returns 0 to proceed with the
# restore ( RESTORE_* populated ), non-zero to abort ( user bailed or a guard
# tripped ). backup_type gates the DB/URL questions ( files-only backups carry no
# database ).
select_restore_destination() {
    local origin_path="${1%/}"
    local origin_domain="$2"
    local backup_script="$3"
    local backup_type="$4"

    # Reset every output so a prior selection can't leak into this one.
    RESTORE_MODE=""
    RESTORE_TARGET_PATH=""
    RESTORE_DB_MODE=""
    RESTORE_DB_NAME=""
    RESTORE_DB_USER=""
    RESTORE_DB_PASS=""
    RESTORE_DB_HOST=""
    RESTORE_URL_NEW=""
    RESTORE_URL_OLD=""
    RESTORE_PRESERVE_WPCONFIG=""
    RESTORE_WPCONFIG_STASH=""

    echo ""
    echo -e "${BOLD}Choose a restore destination:${RESET}"
    echo -e "${BOLD}${YELLOW}1. ${RESET}Origin ( live ) — restore onto ${BOLD}${origin_domain}${RESET} at ${origin_path}"
    echo -e "${BOLD}${YELLOW}2. ${RESET}Staging target ( test ) — restore to a different path / database you specify"
    read -p "$(echo -e "${BOLD}${BLUE}Enter the number of your choice (1/2)${RESET} ${BLUE}( or q to go back ): ${RESET}")" dest_choice

    if [ "${dest_choice,,}" == "q" ]; then
        return 1
    fi

    if [ "$dest_choice" == "1" ]; then
        RESTORE_MODE="origin"
        RESTORE_TARGET_PATH="$origin_path"
        RESTORE_DB_MODE="origin"
        return 0
    elif [ "$dest_choice" != "2" ]; then
        echo -e "${RED}Invalid choice.${RESET}"
        return 1
    fi

    # ---------------------------------------------------------------- staging
    RESTORE_MODE="staging"

    local staging_path
    read -p "$(echo -e "${BOLD}${BLUE}Enter the staging target path${RESET} ${BLUE}( or q to go back ): ${RESET}")" staging_path
    if [ "${staging_path,,}" == "q" ]; then
        return 1
    fi

    # Normalize the same way domains.sh does: force a leading slash, strip a
    # trailing one.
    [[ ! "$staging_path" == /* ]] && staging_path="/$staging_path"
    staging_path="${staging_path%/}"

    if [ -z "$staging_path" ] || [ "$staging_path" == "/" ]; then
        echo -e "${RED}Refusing to use an empty path or '/' as a staging target.${RESET}"
        return 1
    fi
    if [ ! -d "$staging_path" ]; then
        echo -e "${RED}Staging path '${staging_path}' does not exist or is not a directory. Create it first.${RESET}"
        return 1
    fi

    # Resolve the WordPress files directory the same way the rest of the tool
    # does. For WordOps / htdocs layouts this points one level in; for a plain
    # directory it stays as given.
    local staging_wp_path
    staging_wp_path=$(derive_wp_path "$staging_path")
    local effective_path="$staging_path"
    [ -n "$staging_wp_path" ] && effective_path="${staging_wp_path%/}"

    # Collision guard: the effective files target must not equal, sit inside, or
    # contain the origin path. Any overlap would let the clear / extract steps
    # write into ( or wipe ) the live tree.
    if [ "$effective_path" == "$origin_path" ] ||
        [[ "$effective_path" == "$origin_path"/* ]] ||
        [[ "$origin_path" == "$effective_path"/* ]]; then
        echo -e "${RED}The staging path overlaps the origin path ('${origin_path}'). Aborting to protect the live site.${RESET}"
        return 1
    fi
    RESTORE_TARGET_PATH="$effective_path"

    local origin_db_name
    origin_db_name=$(resolve_origin_db_name "$origin_path" "$backup_script")

    local staging_db_name=""
    if [ "$backup_type" == "files" ]; then
        # Files-only backups have no database step at all.
        RESTORE_DB_MODE="none"
    elif [ -n "$staging_wp_path" ]; then
        # The target is a real WordPress install: import into whatever database
        # its own wp-config.php points at, and keep the site's current URL.
        RESTORE_DB_MODE="wpconfig"
        local owner
        owner=$(sudo stat -c "%U" "$effective_path" 2>/dev/null)
        staging_db_name=$(run_wp_cli_as "$owner" config get DB_NAME --path="$effective_path" --skip-plugins --skip-themes 2>/dev/null)

        # Collision guard: never import into the live database.
        if [ -n "$staging_db_name" ] && [ -n "$origin_db_name" ] && [ "$staging_db_name" == "$origin_db_name" ]; then
            echo -e "${RED}The staging database ('${staging_db_name}') is the same as the origin database. Aborting to prevent overwriting the live database.${RESET}"
            return 1
        fi

        # Capture the staging site's current URL BEFORE the import overwrites it
        # with the origin's URL. That captured value becomes the URL we rewrite
        # back to afterwards.
        RESTORE_URL_NEW=$(run_wp_cli_as "$owner" option get siteurl --path="$effective_path" --skip-plugins --skip-themes 2>/dev/null)

        # If the staging site currently carries the origin's URL, or we could not
        # read one, ask the operator for a distinct staging URL so the staged
        # copy never resolves to the live domain.
        local origin_url=""
        local origin_owner
        origin_owner=$(sudo stat -c "%U" "$origin_path" 2>/dev/null)
        origin_url=$(run_wp_cli_as "$origin_owner" option get siteurl --path="$origin_path" --skip-plugins --skip-themes 2>/dev/null)

        if [ -z "$RESTORE_URL_NEW" ] || { [ -n "$origin_url" ] && [ "$RESTORE_URL_NEW" == "$origin_url" ]; }; then
            read -p "$(echo -e "${BOLD}${BLUE}Enter the staging URL to use after import ( e.g. https://staging.example.com )${RESET} ${BLUE}( or q to go back ): ${RESET}")" RESTORE_URL_NEW
            if [ "${RESTORE_URL_NEW,,}" == "q" ] || [ -z "$RESTORE_URL_NEW" ]; then
                return 1
            fi
        fi

        # Standard layout keeps wp-config.php inside the files directory, so a
        # full / incremental restore would overwrite it with the origin's DB
        # credentials — which would then point the import at the live database.
        # Flag it for preservation. WordOps / htdocs layouts keep wp-config.php
        # outside the target, so nothing to protect there.
        if [ "$backup_type" != "database" ] && [ -f "$effective_path/wp-config.php" ]; then
            RESTORE_PRESERVE_WPCONFIG="$effective_path/wp-config.php"
        fi
    else
        # Non-WordPress target ( or a mysqldump backup landing somewhere without a
        # wp-config ): the operator supplies the staging database explicitly.
        RESTORE_DB_MODE="explicit"
        read -p "$(echo -e "${BOLD}${BLUE}Staging database name${RESET} ${BLUE}( or q to go back ): ${RESET}")" RESTORE_DB_NAME
        if [ "${RESTORE_DB_NAME,,}" == "q" ] || [ -z "$RESTORE_DB_NAME" ]; then
            return 1
        fi
        if [ -n "$origin_db_name" ] && [ "$RESTORE_DB_NAME" == "$origin_db_name" ]; then
            echo -e "${RED}That database name matches the origin database. Aborting to protect the live database.${RESET}"
            return 1
        fi
        read -p "$(echo -e "${BOLD}${BLUE}Staging database user: ${RESET}")" RESTORE_DB_USER
        read -s -p "$(echo -e "${BOLD}${BLUE}Staging database password: ${RESET}")" RESTORE_DB_PASS
        echo ""
        read -p "$(echo -e "${BOLD}${BLUE}Staging database host ( default: localhost ): ${RESET}")" RESTORE_DB_HOST
        [ -z "$RESTORE_DB_HOST" ] && RESTORE_DB_HOST="localhost"
    fi

    # ------------------------------------------------ resolved-summary confirm
    echo ""
    echo -e "${BOLD}${UNDERLINE}Restore destination${RESET}"
    echo -e "${BOLD}Mode:${RESET}  ${YELLOW}Staging ( test )${RESET}"
    echo -e "${BOLD}Files ->${RESET} ${RESTORE_TARGET_PATH}"
    case "$RESTORE_DB_MODE" in
    wpconfig)
        echo -e "${BOLD}DB    ->${RESET} ${staging_db_name:-<from staging wp-config>} ( via staging wp-config )"
        echo -e "${BOLD}URL   ->${RESET} <origin URL> -> ${RESTORE_URL_NEW} ( applied after import )"
        ;;
    explicit)
        echo -e "${BOLD}DB    ->${RESET} ${RESTORE_DB_NAME} ( ${RESTORE_DB_USER}@${RESTORE_DB_HOST} )"
        echo -e "${BOLD}URL   ->${RESET} no rewrite ( non-WordPress / explicit database )"
        ;;
    none)
        echo -e "${BOLD}DB    ->${RESET} none ( files-only backup )"
        ;;
    esac
    echo -e "${YELLOW}The staging target contents will be overwritten. The live site is NOT touched.${RESET}"
    echo ""
    read -p "$(echo -e "${BOLD}${BLUE}Proceed with this staging restore? (y/n): ${RESET}")" confirm_dest
    if [[ "${confirm_dest,,}" != "y" && "${confirm_dest,,}" != "yes" ]]; then
        echo -e "${YELLOW}Restore aborted.${RESET}"
        return 1
    fi

    return 0
}

# Copy the staging wp-config.php aside before a file restore overwrites it. Only
# does anything when select_restore_destination flagged one for preservation.
stash_staging_wpconfig() {
    RESTORE_WPCONFIG_STASH=""
    [ -z "$RESTORE_PRESERVE_WPCONFIG" ] && return 0
    [ ! -f "$RESTORE_PRESERVE_WPCONFIG" ] && return 0

    sudo mkdir -p "$TMP_DIR"
    RESTORE_WPCONFIG_STASH="${TMP_DIR}/wp-config.staging.$$.php"
    sudo cp -p "$RESTORE_PRESERVE_WPCONFIG" "$RESTORE_WPCONFIG_STASH"
}

# Put the staging wp-config.php back after the file restore, so the DB import and
# URL rewrite run against the staging database ( not the origin's ).
restore_staging_wpconfig() {
    [ -z "$RESTORE_WPCONFIG_STASH" ] && return 0
    [ ! -f "$RESTORE_WPCONFIG_STASH" ] && return 0

    sudo cp -p "$RESTORE_WPCONFIG_STASH" "$RESTORE_PRESERVE_WPCONFIG"
    sudo rm -f "$RESTORE_WPCONFIG_STASH"
}

# Import the restored SQL dump into the resolved database. Mirrors the original
# inline import for origin mode and adds the two staging paths. Expects the dump
# to sit under RESTORE_TARGET_PATH ( the file restore put it there ).
run_restore_db_import() {
    local backup_type="$1"
    local backup_script="$2"
    local backup_hash="$3"

    # Files-only backups have no database to import.
    if [ "$backup_type" == "files" ] || [ "$RESTORE_DB_MODE" == "none" ]; then
        return 0
    fi

    # The dump always lands at the top level of the restore target ( full and
    # database place it there, and the incremental subpath restore lands it at the
    # root ), so cap the search at depth 1 — no walking the whole site tree, and no
    # risk of matching a stray dump buried in uploads.
    local sql_file=$(find "$RESTORE_TARGET_PATH" -maxdepth 1 -type f -name "*${backup_hash}_*.sql" -print -quit)
    if [ -z "$sql_file" ]; then
        echo -e "${YELLOW}No SQL dump found under ${RESTORE_TARGET_PATH}; skipping database import.${RESET}"
        return 0
    fi

    echo ""
    echo -e "${YELLOW}Importing the database ...${RESET}"

    case "$RESTORE_DB_MODE" in
    explicit)
        local my_cnf
        my_cnf=$(mktemp)
        chmod 600 "$my_cnf"
        printf '[client]\nuser=%s\npassword=%s\nhost=%s\n' "$RESTORE_DB_USER" "$RESTORE_DB_PASS" "$RESTORE_DB_HOST" >"$my_cnf"
        sudo mysql --defaults-extra-file="$my_cnf" "$RESTORE_DB_NAME" <"$sql_file"
        rm -f "$my_cnf"
        ;;
    wpconfig)
        # Import through the staging site's own wp-config.php.
        local owner=$(sudo stat -c "%U" "$RESTORE_TARGET_PATH")
        run_wp_cli_as "${owner}" db import "${sql_file}" --path="${RESTORE_TARGET_PATH}" --skip-plugins --skip-themes
        ;;
    origin)
        # Original behaviour: dispatch on the driver baked into the backup script.
        # Masked "local VAR=$(...)" captures keep a no-match grep from aborting the
        # tool under set -e ( legacy scripts have no db_driver= line ).
        local backup_db_driver=$(grep -oP 'db_driver="\K[^"]+' "$backup_script" 2>/dev/null)
        [ -z "$backup_db_driver" ] && backup_db_driver="wpcli"

        if [ "$backup_db_driver" == "mysqldump" ]; then
            if ! command -v base64 >/dev/null 2>&1; then
                echo -e "${RED}base64 is required to decode mysqldump credentials but was not found on PATH.${RESET}" >&2
                return 1
            fi
            local backup_db_name=$(grep -oP '^db_name_b64=\K.*' "$backup_script" | base64 -d)
            local backup_db_user=$(grep -oP '^db_user_b64=\K.*' "$backup_script" | base64 -d)
            local backup_db_pass=$(grep -oP '^db_pass_b64=\K.*' "$backup_script" | base64 -d)
            local backup_db_host=$(grep -oP '^db_host_b64=\K.*' "$backup_script" | base64 -d)
            local my_cnf=$(mktemp)
            chmod 600 "$my_cnf"
            printf '[client]\nuser=%s\npassword=%s\nhost=%s\n' "$backup_db_user" "$backup_db_pass" "$backup_db_host" >"$my_cnf"
            sudo mysql --defaults-extra-file="$my_cnf" "$backup_db_name" <"$sql_file"
            rm -f "$my_cnf"
        else
            local wp_owner=$(sudo stat -c "%U" "${RESTORE_TARGET_PATH}")
            run_wp_cli_as "${wp_owner}" db import "${sql_file}" --path="${RESTORE_TARGET_PATH}" --skip-plugins --skip-themes
        fi
        ;;
    esac

    sudo rm "$sql_file"
}

# After a staging import, rewrite the WordPress URL from the origin's ( which the
# import just wrote into the DB ) to the staging URL captured earlier, so the
# staged copy stops referencing the live domain. Only runs for a WordPress
# staging target; explicit / non-WP restores print a note and leave URLs alone.
maybe_wp_search_replace() {
    if [ "$RESTORE_MODE" != "staging" ]; then
        return 0
    fi
    if [ "$RESTORE_DB_MODE" != "wpconfig" ]; then
        if [ "$RESTORE_DB_MODE" == "explicit" ]; then
            echo -e "${YELLOW}Staging database imported with explicit credentials; skipping WordPress URL rewrite. Update siteurl/home manually if the data is a WordPress site.${RESET}"
        fi
        return 0
    fi

    local owner=$(sudo stat -c "%U" "$RESTORE_TARGET_PATH")

    # The freshly imported DB now holds the origin's URL — that is the value to
    # search for. Tolerate a non-zero / empty read under set -e.
    RESTORE_URL_OLD=$(run_wp_cli_as "$owner" option get siteurl --path="$RESTORE_TARGET_PATH" --skip-plugins --skip-themes 2>/dev/null) || true

    if [ -z "$RESTORE_URL_NEW" ]; then
        echo -e "${YELLOW}No staging URL was captured; skipping URL rewrite.${RESET}"
        return 0
    fi
    if [ -z "$RESTORE_URL_OLD" ] || [ "$RESTORE_URL_OLD" == "$RESTORE_URL_NEW" ]; then
        echo -e "${YELLOW}Imported site URL is empty or already matches the staging URL ( ${RESTORE_URL_NEW} ); no rewrite needed.${RESET}"
        return 0
    fi

    echo ""
    echo -e "${YELLOW}Rewriting site URL ${RESTORE_URL_OLD} -> ${RESTORE_URL_NEW} ...${RESET}"
    # A failed rewrite would leave the staged copy pointing at the live domain, so
    # surface it loudly rather than letting set -e tear the whole tool down.
    if ! run_wp_cli_as "$owner" search-replace "$RESTORE_URL_OLD" "$RESTORE_URL_NEW" --path="$RESTORE_TARGET_PATH" --all-tables-with-prefix --skip-columns=guid --report-changed-only --skip-plugins --skip-themes; then
        echo -e "${RED}URL rewrite failed. The staged copy may still reference ${RESTORE_URL_OLD}; fix it before using the stage.${RESET}"
        return 0
    fi
    # siteurl/home live in the options table; set them explicitly as a belt-and-
    # suspenders in case search-replace skipped a serialized edge case.
    run_wp_cli_as "$owner" option update siteurl "$RESTORE_URL_NEW" --path="$RESTORE_TARGET_PATH" --skip-plugins --skip-themes || true
    run_wp_cli_as "$owner" option update home "$RESTORE_URL_NEW" --path="$RESTORE_TARGET_PATH" --skip-plugins --skip-themes || true
    run_wp_cli_as "$owner" cache flush --path="$RESTORE_TARGET_PATH" --skip-plugins --skip-themes >/dev/null 2>&1 || true
}
