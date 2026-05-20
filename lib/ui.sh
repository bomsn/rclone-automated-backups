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
