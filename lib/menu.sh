#!/bin/bash

# Backup management menu

# Function to manage automated backups
manage_backups() {
    while true; do

        # Go back to the main menu in case all backups has been deleted
        if [ $HAS_AUTOMATED_BACKUPS == false ]; then
            clear_screen
            return
        fi

        # Shpw the backup management menu
        clear_screen "ignore" "generate_backup_script" "manage_automated_backups"
        echo -e "${BOLD}${UNDERLINE}Manage backups${RESET}"
        echo "1. Manage automated backups"
        echo "2. Create a new automated backup"
        echo "3. Configure email notifications"
        echo "4. Return to the previous menu"
        read -p "$(echo -e "${BOLD}${BLUE}Enter your choice: ${RESET}")" choice

        case "$choice" in
        1)
            manage_automated_backups
            ;;
        2)
            generate_backup_script
            ;;
        3)
            configure_notifications
            ;;
        4)
            clear_screen "force"
            return
            ;;
        *)
            clear_screen "force"
            echo -e "${RED}Invalid choice. Please select a valid option.${RESET}"
            ;;
        esac
    done
}
