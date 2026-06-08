#!/bin/bash

# Domain/site management: discovery, manual entry, deletion

# Resolve the actual WordPress files directory for a given path.
# Echoes the resolved path, or an empty string when no WordPress install is found.
# Handles WordOps (wp-config.php in the parent + an htdocs/ dir), a path that already
# points at htdocs, and the standard layout (wp-config.php in the same directory).
derive_wp_path() {
    local path="${1%/}"
    if [ -f "$path/wp-config.php" ] && [ -d "$path/htdocs" ]; then
        echo "$path/htdocs"
    elif [ -f "${path%/htdocs}/wp-config.php" ] && [ -d "$path" ]; then
        echo "$path"
    elif [ -f "$path/wp-config.php" ]; then
        echo "$path"
    else
        echo ""
    fi
}

# Look up the stored WordPress path for a domain. Echoes the path, or an empty
# string when the domain is not in the DOMAINS array.
resolve_domain_path() {
    local target="$1"
    local i
    for ((i = 0; i < ${#DOMAINS[@]}; i++)); do
        if [ "${DOMAINS[$i]}" == "$target" ]; then
            echo "${PATHS[$i]}"
            return 0
        fi
    done
    echo ""
    return 1
}

# Dispatcher: let the user pick how to add a site ( auto-discovery or manual entry )
add_domain() {

    clear_screen "force"

    echo -e "${BOLD}${UNDERLINE}Add a site/domain${RESET}"
    echo ""

    local original_ps3="$PS3"
    PS3="$(echo -e "${BOLD}${BLUE}Type the desired option number to continue: ${RESET}")"
    select method in "Auto-discover WordPress sites" "Enter the path manually" "Enter a non-WordPress directory" "Go back"; do
        case "$method" in
        "Auto-discover WordPress sites")
            PS3="$original_ps3"
            add_domain_discover
            return
            ;;
        "Enter the path manually")
            PS3="$original_ps3"
            add_domain_manual
            return
            ;;
        "Enter a non-WordPress directory")
            PS3="$original_ps3"
            add_domain_nonwp
            return
            ;;
        "Go back")
            PS3="$original_ps3"
            clear_screen "force"
            return
            ;;
        *)
            echo -e "${RED}Invalid choice. Please select a valid option.${RESET}"
            ;;
        esac
    done
    PS3="$original_ps3"
}

# Function to add a non-WordPress directory ( for use with the "files" backup
# type or the "mysqldump" DB driver ). Skips the WordPress install check and
# just validates that the path exists.
add_domain_nonwp() {

    clear_screen "force"

    echo -e "${BOLD}${UNDERLINE}Add a site/domain > Enter a non-WordPress directory${RESET}"
    echo -e "${YELLOW}Use this for any directory you want to back up that is not a${RESET}"
    echo -e "${YELLOW}WordPress install ( forums, custom apps, static sites, etc. ).${RESET}"
    echo ""

    read -p "$(echo -e "${BOLD}${BLUE}Enter an identifier ( domain-like name )${RESET} ${BLUE}( or q to go back ): ${RESET}")" domain

    if [ "${domain,,}" == "q" ]; then
        manage_domains
        return
    fi

    local sanitized_domain=$(echo "$domain" | sed -e 's|^https://||' -e 's|^http://||' -e 's|^www\.||' -e 's|/.*$||')
    local domain_pattern="^([a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$"
    if [[ ! "$sanitized_domain" =~ $domain_pattern ]]; then
        clear_screen "force"
        echo -e "${RED}"${domain}" is not a valid identifier ( must look like a domain, eg; mysite.example ).${RESET}"
        return
    fi

    if [ "$domain" != "$sanitized_domain" ]; then
        echo -e "${YELLOW}Identifier interpreted as:${RESET} ${BOLD}$sanitized_domain${RESET}"
    fi

    local duplicate=false
    for existing_domain in "${DOMAINS[@]}"; do
        if [ "$existing_domain" == "$sanitized_domain" ]; then
            duplicate=true
            break
        fi
    done
    if [ "$duplicate" == true ]; then
        clear_screen "force"
        echo -e "${RED}Identifier $sanitized_domain is already in the list.${RESET}"
        return
    fi

    read -p "$(echo -e "${BOLD}${BLUE}Enter the full directory path for $sanitized_domain${RESET} ${BLUE}( or q to go back ): ${RESET}")" path

    if [ "${path,,}" == "q" ]; then
        add_domain_nonwp
        return
    fi

    if [[ ! "$path" == /* ]]; then
        path="/$path"
    fi
    path="${path%/}"

    if [ ! -d "$path" ]; then
        clear_screen "force"
        echo -e "${RED}Directory $path does not exist or is not a directory.${RESET}"
        return
    fi

    DOMAINS+=("$sanitized_domain")
    PATHS+=("$path")
    update_definitions
    clear_screen "force"
    echo -e "${GREEN}Non-WordPress directory $sanitized_domain added successfully.${RESET}"
    echo -e "${GREEN}Path:${RESET} ${BOLD}$path${RESET}"
    echo -e "${YELLOW}Use --type files ( or --type full/database with --db-driver mysqldump${RESET}"
    echo -e "${YELLOW}once you have set up that driver ) when creating a backup for this entry.${RESET}"
}

# Function to add a domain/path by manually typing them in
add_domain_manual() {

    clear_screen "force"

    read -p "$(echo -e "${BOLD}${BLUE}Enter a domain${RESET} ${BLUE}( or q to go back ): ${RESET}")" domain

    if [ "${domain,,}" == "q" ]; then
        manage_domains
        return
    fi

    # Clean and validate the domain
    local sanitized_domain=$(echo "$domain" | sed -e 's|^https://||' -e 's|^http://||' -e 's|^www\.||' -e 's|/.*$||')
    local domain_pattern="^([a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$"
    if [[ ! "$sanitized_domain" =~ $domain_pattern ]]; then
        clear_screen "force"
        echo -e "${RED}"${domain}" is not a valid domain.${RESET}"
        return
    fi

    # Show the user how their input was interpreted ( eg; protocol/www stripped )
    if [ "$domain" != "$sanitized_domain" ]; then
        echo -e "${YELLOW}Domain interpreted as:${RESET} ${BOLD}$sanitized_domain${RESET}"
    fi

    # Check if the domain already exists in the DOMAINS array
    local duplicate=false
    for existing_domain in "${DOMAINS[@]}"; do
        if [ "$existing_domain" == "$sanitized_domain" ]; then
            duplicate=true
            break
        fi
    done
    # If the domain is already added, show an error
    if [ "$duplicate" == true ]; then
        clear_screen "force"
        echo -e "${RED}Domain $sanitized_domain is already in the list.${RESET}"
        return
    fi

    # Get the WordPress installation dir for that domain
    read -p "$(echo -e "${BOLD}${BLUE}Enter the WordPress installation's full path for $sanitized_domain${RESET} ${BLUE}( or q to go back ): ${RESET}")" path

    if [ "${path,,}" == "q" ]; then
        add_domain_manual
        return
    fi

    # Make sure the path always has a leading slash
    if [[ ! "$path" == /* ]]; then
        path="/$path"
    fi

    # Remove any trailing slash
    path="${path%/}"

    # Resolve the WordPress files directory ( WordOps / htdocs / standard layouts )
    local wp_path=$(derive_wp_path "$path")

    if [ -z "$wp_path" ]; then
        # No WordPress installation found
        clear_screen "force"
        echo -e "${RED}We could not find a WordPress installation under $path ${RESET}"
        return
    fi

    # WordPress installation exists for this domain, let's append it to the array
    DOMAINS+=("$sanitized_domain")
    PATHS+=("$wp_path") # Store the path to WordPress files
    update_definitions   # Save definitions after each addition
    clear_screen "force"
    # Confirm the result, showing the resolved path so any auto-correction is visible
    echo -e "${GREEN}Domain $sanitized_domain added successfully.${RESET}"
    echo -e "${GREEN}WordPress files path:${RESET} ${BOLD}$wp_path${RESET}"
}

# Scan common web roots for WordPress installs and let the user pick which to add
add_domain_discover() {

    clear_screen "force"
    echo -e "${BOLD}${UNDERLINE}Add a site/domain > Auto-discover${RESET}"
    echo ""
    echo -e "${YELLOW}Scanning the server for WordPress installations, this may take a moment ...${RESET}"

    # Candidate web roots across common stacks ( generic, WordOps, cPanel, Plesk,
    # OpenLiteSpeed/CyberPanel, Bitnami ). Roots that don't exist are simply skipped.
    local candidate_roots=("/var/www" "/srv/www" "/usr/share/nginx/html" "/home" "/opt/bitnami")

    # Collect wp-config.php locations ( depth-limited, heavy dirs pruned, errors hidden )
    local config_files=()
    local root cfg
    for root in "${candidate_roots[@]}"; do
        [ -d "$root" ] || continue
        while IFS= read -r cfg; do
            [ -n "$cfg" ] && config_files+=("$cfg")
        done < <(sudo find "$root" -maxdepth 5 -type d \( -name node_modules -o -name '.git' -o -path '*/wp-content/uploads' \) -prune -o -name wp-config.php -type f -print 2>/dev/null)
    done

    # Resolve each install and read its real domain ( de-duplicated by path and domain )
    DISCOVERED_DOMAINS=()
    DISCOVERED_PATHS=()
    local seen_paths=" "
    local cfg_dir wp_path owner site_domain existing already
    for cfg in "${config_files[@]}"; do
        cfg_dir="$(dirname "$cfg")"
        wp_path=$(derive_wp_path "$cfg_dir")
        [ -z "$wp_path" ] && continue
        # Skip a path we already resolved ( WordOps yields the same install twice )
        [[ "$seen_paths" == *" $wp_path "* ]] && continue
        seen_paths+="$wp_path "

        owner=$(sudo stat -c "%U" "$wp_path" 2>/dev/null)
        # Read the canonical domain from WordPress itself ( stack-agnostic )
        site_domain=""
        if [ -n "$owner" ]; then
            site_domain=$(run_wp_cli_as "$owner" option get siteurl --path="$wp_path" --skip-plugins --skip-themes 2>/dev/null)
        fi
        site_domain=$(echo "$site_domain" | sed -e 's|^https://||' -e 's|^http://||' -e 's|^www\.||' -e 's|/.*$||')
        # Fall back to the directory name when wp-cli is unavailable or fails
        if [ -z "$site_domain" ]; then
            site_domain="$(basename "$cfg_dir")"
            if [[ "$site_domain" == "htdocs" || "$site_domain" == "httpdocs" || "$site_domain" == "public_html" ]]; then
                site_domain="$(basename "$(dirname "$cfg_dir")")"
            fi
        fi

        # Skip installs whose domain is already saved or already discovered in this run
        already=false
        for existing in "${DOMAINS[@]}" "${DISCOVERED_DOMAINS[@]}"; do
            if [ "$existing" == "$site_domain" ]; then
                already=true
                break
            fi
        done
        [ "$already" == true ] && continue

        DISCOVERED_DOMAINS+=("$site_domain")
        DISCOVERED_PATHS+=("$wp_path")
    done

    if [ ${#DISCOVERED_DOMAINS[@]} -eq 0 ]; then
        clear_screen "force"
        echo -e "${YELLOW}No new WordPress installations were discovered automatically.${RESET}"
        echo ""
        read -p "$(echo -e "${BOLD}${BLUE}Add a site manually instead? (y/n): ${RESET}")" go_manual
        if [[ "${go_manual,,}" == "y" || "${go_manual,,}" == "yes" ]]; then
            add_domain_manual
        fi
        return
    fi

    # Let the user choose which discovered sites to add
    multiselect_discovered
}

# Let the user pick which discovered sites ( DISCOVERED_DOMAINS / DISCOVERED_PATHS )
# to add. One prompt takes the numbers to add ( supports ranges and 'all' ), then
# a confirmation screen lists exactly what will be saved.
multiselect_discovered() {

    local count=${#DISCOVERED_DOMAINS[@]}
    local i
    local msg="" # an error message carried over to the next redraw

    while true; do
        # Show the numbered list of discovered sites
        clear_screen "force"
        echo -e "${BOLD}${UNDERLINE}Add a site/domain > Auto-discover${RESET}"
        echo ""
        echo -e "${GREEN}Discovered ${count} WordPress site(s):${RESET}"
        echo ""
        for ((i = 0; i < count; i++)); do
            echo -e "  ${BOLD}$((i + 1)).${RESET} ${BOLD}${DISCOVERED_DOMAINS[i]}${RESET}  ${BLUE}${DISCOVERED_PATHS[i]}${RESET}"
        done
        echo ""
        if [ -n "$msg" ]; then
            echo -e "$msg"
            echo ""
            msg=""
        fi

        # Single prompt: the numbers of the sites to add
        echo -e "${YELLOW}Type the number(s) of the sites to add — eg; ${BOLD}1,3,6${RESET}${YELLOW}  ·  a range ${BOLD}1-10,15${RESET}${YELLOW}  ·  or ${BOLD}all${RESET}${YELLOW}.${RESET}"
        if ! read -p "$(echo -e "${BOLD}${BLUE}Sites to add ( or q to cancel ): ${RESET}")" sel_input; then
            clear_screen "force"
            echo -e "${YELLOW}Cancelled, nothing was added.${RESET}"
            echo ""
            return
        fi

        # Strip terminal bracketed-paste markers some terminals add around pasted text
        sel_input="${sel_input//$'\e'/}"
        sel_input="${sel_input//'[200~'/}"
        sel_input="${sel_input//'[201~'/}"
        # Trim surrounding whitespace
        sel_input="${sel_input#"${sel_input%%[![:space:]]*}"}"
        sel_input="${sel_input%"${sel_input##*[![:space:]]}"}"

        if [ "${sel_input,,}" == "q" ]; then
            clear_screen "force"
            echo -e "${YELLOW}Cancelled, nothing was added.${RESET}"
            echo ""
            return
        fi

        # Parse the input into a list of 1-based indexes
        local -a chosen=()
        local chosen_str
        if chosen_str=$(parse_index_selection "$sel_input" "$count"); then
            read -ra chosen <<<"$chosen_str"
        else
            msg="${RED}Invalid selection.${RESET} Use numbers 1-${count} ( eg; 1,3,6 ), a range ( eg; 1-10 ), or 'all'."
            continue
        fi

        # De-duplicate the chosen indexes and build the add lists
        local -a to_add_domains=()
        local -a to_add_paths=()
        local seen=" "
        local c
        for c in "${chosen[@]}"; do
            [[ "$seen" == *" $c "* ]] && continue
            seen+="$c "
            to_add_domains+=("${DISCOVERED_DOMAINS[c - 1]}")
            to_add_paths+=("${DISCOVERED_PATHS[c - 1]}")
        done

        # Confirmation screen — show exactly what will be added
        clear_screen "force"
        echo -e "${BOLD}${UNDERLINE}Add a site/domain > Confirm${RESET}"
        echo ""
        echo -e "${BOLD}These ${#to_add_domains[@]} site(s) will be added:${RESET}"
        echo ""
        for ((i = 0; i < ${#to_add_domains[@]}; i++)); do
            echo -e "  ${GREEN}+${RESET} ${BOLD}${to_add_domains[i]}${RESET}  ${BLUE}${to_add_paths[i]}${RESET}"
        done
        echo ""
        read -p "$(echo -e "${BOLD}${BLUE}Add these?  y = yes  ·  n = choose again  ·  q = cancel: ${RESET}")" confirm

        case "${confirm,,}" in
        y | yes)
            for ((i = 0; i < ${#to_add_domains[@]}; i++)); do
                DOMAINS+=("${to_add_domains[i]}")
                PATHS+=("${to_add_paths[i]}")
            done
            update_definitions # Save definitions after adding the selected sites
            clear_screen "force"
            echo -e "${GREEN}${#to_add_domains[@]} site(s) added successfully.${RESET}"
            echo ""
            return
            ;;
        q)
            clear_screen "force"
            echo -e "${YELLOW}Cancelled, nothing was added.${RESET}"
            echo ""
            return
            ;;
        *)
            # 'n' or anything else: go back and choose again
            msg=""
            ;;
        esac
    done
}

# Function to delete domain and path
delete_domain() {

    clear_screen "force"

    # Show a list of existing domains
    echo -e "${BOLD}The following is a list of the domains/sites available for deletion:${RESET}"
    for ((i = 0; i < ${#DOMAINS[@]}; i++)); do
        domain="${DOMAINS[$i]}"
        echo -e "- $domain"
    done

    # Ask user to type the domain they want to delete
    echo ""
    echo -e "${BOLD}${YELLOW}Note: ${RESET}${YELLOW}the automated backups created for the selected domain will NOT be effected.${RESET}"
    read -p "$(echo -e "${BOLD}${BLUE}Enter a domain to delete${RESET} ${BLUE}( or q to go back ): ${RESET}")" domain_to_delete

    if [ "${domain_to_delete,,}" == "q" ]; then
        manage_domains
        return
    fi

    # Attempt to delete the domain from our list, and keep track
    local deleted=false
    local new_domains=()
    local new_paths=()

    for ((i = 0; i < ${#DOMAINS[@]}; i++)); do
        if [ "${DOMAINS[$i]}" != "$domain_to_delete" ]; then
            new_domains+=("${DOMAINS[$i]}")
            new_paths+=("${PATHS[$i]}")
        else
            deleted=true
        fi
    done

    # Run processes asscoaited with deletion, or raise an error
    if [ $deleted == true ]; then
        # Update the DOMAINS and PATHS arrays with the new values
        DOMAINS=("${new_domains[@]}")
        PATHS=("${new_paths[@]}")

        clear_screen "force"
        # Show success message
        echo -e "${GREEN}Domain $domain_to_delete has been deleted successfully.${RESET}"
        # Save definitions after each deletion
        update_definitions
    else

        clear_screen "force"
        # Show an error
        echo -e "${RED}Invalid choice. Domain $domain_to_delete is not in the list.${RESET}"
    fi

}

# Function to allow the management of domains and path ( view, add, delete )
manage_domains() {
    # If there are no existing domains/sites, fall back to the 'add_domain' function
    if [[ $ARE_DOMAINS_EMPTY == true || $ARE_DOMAINS_EMPTY == -1 ]]; then
        add_domain
    fi

    # Clear screen and show the site management menu
    clear_screen

    while true; do
        # Add a title
        echo -e "${BOLD}${UNDERLINE}Manage sites/domains${RESET}"
        # Show list of options
        local original_ps3="$PS3" # Save the original PS3 value
        PS3="$(echo -e "${BOLD}${BLUE}Type the desired option number to continue: ${RESET}")"
        options=("View existing domains/sites" "Add a new domain/site" "Delete an existing domain/site" "Return to the previous menu")
        select choice in "${options[@]}"; do
            case "$choice" in
            "View existing domains/sites")
                clear_screen "force"
                echo -e "${BOLD}The following is a list of the domain you've added:${RESET}"
                for ((i = 0; i < ${#DOMAINS[@]}; i++)); do
                    domain="${DOMAINS[$i]}"
                    path="${PATHS[$i]}"
                    echo -e "- ${BOLD}Domain:${RESET} $domain,  ${BOLD}Path:${RESET} $path"
                done
                echo ""
                ;;
            "Add a new domain/site")
                add_domain
                ;;
            "Delete an existing domain/site")
                delete_domain
                # Return to the main menu if there are no domains available
                if [[ $ARE_DOMAINS_EMPTY == true || $ARE_DOMAINS_EMPTY == -1 ]]; then
                    return
                fi
                ;;
            "Return to the previous menu")
                clear_screen "force"
                return
                ;;
            *)
                clear_screen "force"
                echo -e "${RED}Invalid choice. Please select a valid option.${RESET}"
                ;;
            esac
            break
        done
        PS3="$original_ps3" # Restore the original PS3 value
    done

}
