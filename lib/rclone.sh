#!/bin/bash

# rclone configuration wrapper

# A wrapper function that triggers `rclone config` to allow using to create new remotes, edit existing..etc
configure_rclone() {

    clear_screen

    local configure_rclone=false
    # If there is an existing list of remotes, allow user to decide whether to configure rclone or not
    if sudo rclone listremotes --long 2>&1 | grep -qEv 'NOTICE:'; then
        # Add a title
        echo -e "${BOLD}${UNDERLINE}Re-configure rclone${RESET}"

        read -p "$(echo -e "${BOLD}${BLUE}Rclone has existing remotes, would you like to re-configure it (y/n): ${RESET}")" config
        if [ "${config,,}" == "y" ] || [ "${config,,}" == "yes" ]; then
            # Configure rclone
            configure_rclone=true
        fi
    else
        # Add a title
        echo -e "${BOLD}${UNDERLINE}Configure rclone${RESET}"

        # Configure rclone
        configure_rclone=true
    fi

    if [ $configure_rclone == true ]; then

        # Clear screen
        clear_screen "force"
        # Show a message
        echo -e "${YELLOW}Initializing rclone configuration ...${RESET}"
        echo ""
        # Start the configuration
        sudo rclone config
    fi

    # Clear screen
    clear_screen "force"

    # Update definitions state variables
    update_definitions_state
}
