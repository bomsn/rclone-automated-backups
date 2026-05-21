#!/bin/bash

# UI helpers: screen clearing and cursor save/restore

# Function to clear the screen and position cursor at the top
clear_screen_last_caller_name=""
clear_screen() {
    local caller_name="${FUNCNAME[1]}"

    # Ignore if the previous caller function matches any of the arguements after $1
    # Good to avoid clearing the screen multiple times as part of the same menu tree.
    if [[ "$1" == "ignore" ]]; then
        for arg in "${@:2}"; do
            if [[ "$arg" == "$clear_screen_last_caller_name" ]]; then
                clear_screen_last_caller_name="$caller_name"
                return
            fi
        done
    fi

    # If "force" is specified, clear the screen regardless of the last caller, otherwise, don't clear twice for same caller
    if [[ "$1" = "force" || "$caller_name" != "$clear_screen_last_caller_name" ]]; then
        # \e[3J erases the scrollback buffer, \e[2J the visible screen, \e[H homes
        # the cursor — together they give a true refresh with no scroll-up history.
        echo -e "\e[3J\e[H\e[2J"
        clear_screen_last_caller_name="$caller_name"
    fi
}

# Save the cursor position
save_cursor_position() {
    if [ "$1" == "alt" ]; then
        # echo -en "\e7"
        tput sc
    else
        echo -en "\e[s"
    fi
}
restore_cursor_position() {
    if [ "$1" == "alt" ]; then
        # Restore the cursor position and clear from there to the saved cursor position using the "alt" approach
        # echo -en "\e8\e[2J"
        tput rc
        tput ed
        # Re-save the cursor position
        # echo -en "\e7"
        tput sc
    else
        # Restore the cursor position and clear from there to the end of the screen (default approach)
        echo -en "\e[u\e[J"
        # Re-save the cursor position
        echo -en "\e[s"
    fi

}

# Parse a user index selection ( "1,3,6", a range "1-10,15", or "all"/"a" ) against
# a maximum count. On success echoes the space-separated 1-based indexes and returns
# 0; on any invalid or empty input echoes nothing and returns 1.
parse_index_selection() {
    local input="${1,,}"
    local count="$2"
    local -a chosen=()
    local i

    if [ "$input" == "all" ] || [ "$input" == "a" ]; then
        for ((i = 1; i <= count; i++)); do chosen+=("$i"); done
    elif [ -z "$input" ]; then
        return 1
    else
        local -a parts=()
        local p lo hi n
        IFS=', ' read -ra parts <<<"$input"
        for p in "${parts[@]}"; do
            [ -z "$p" ] && continue
            if [[ "$p" =~ ^[0-9]+$ ]]; then
                if [ "$p" -ge 1 ] && [ "$p" -le "$count" ]; then
                    chosen+=("$p")
                else
                    return 1
                fi
            elif [[ "$p" =~ ^([0-9]+)-([0-9]+)$ ]]; then
                lo="${BASH_REMATCH[1]}"
                hi="${BASH_REMATCH[2]}"
                if [ "$lo" -ge 1 ] && [ "$hi" -le "$count" ] && [ "$lo" -le "$hi" ]; then
                    for ((n = lo; n <= hi; n++)); do chosen+=("$n"); done
                else
                    return 1
                fi
            else
                return 1
            fi
        done
    fi

    [ "${#chosen[@]}" -eq 0 ] && return 1
    echo "${chosen[@]}"
    return 0
}
