#!/bin/bash

# Email failure-notification configuration

# Configure the single email address that receives backup failure alerts.
# The address is stored in the definitions file and read by every backup
# script at run time, so setting it once covers all backups.
configure_notifications() {

    clear_screen
    echo -e "${BOLD}${UNDERLINE}Configure email notifications${RESET}"
    echo ""

    # Show the current state
    if [ -n "$NOTIFY_EMAIL" ]; then
        echo -e "${BOLD}Current address:${RESET} $NOTIFY_EMAIL"
    else
        echo -e "${YELLOW}Email notifications are currently disabled.${RESET}"
    fi
    echo ""

    # Warn if the server has no way to send mail
    if ! command -v mail &>/dev/null && ! command -v sendmail &>/dev/null; then
        echo -e "${YELLOW}Warning: neither 'mail' nor 'sendmail' was found on this server.${RESET}"
        echo -e "${YELLOW}Install a mail client (eg; ${BOLD}apt-get install mailutils${RESET}${YELLOW}) or configure an MTA,${RESET}"
        echo -e "${YELLOW}otherwise failure alerts cannot be delivered.${RESET}"
        echo ""
    fi

    echo -e "An email is sent only when a backup ${BOLD}fails${RESET} ( one alert per failed run )."
    echo -e "Enter an email address, type ${BOLD}disable${RESET} to turn alerts off, or ${BOLD}q${RESET} to go back."
    read -p "$(echo -e "${BOLD}${BLUE}Email address: ${RESET}")" input

    # Go back without changes
    if [ "${input,,}" == "q" ]; then
        clear_screen "force"
        return
    fi

    # Disable notifications
    if [ "${input,,}" == "disable" ]; then
        NOTIFY_EMAIL=""
        update_definitions
        clear_screen "force"
        echo -e "${GREEN}Email notifications have been disabled.${RESET}"
        echo ""
        return
    fi

    # Validate the email address
    local email_pattern="^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"
    if [[ ! "$input" =~ $email_pattern ]]; then
        clear_screen "force"
        echo -e "${RED}'$input' is not a valid email address.${RESET}"
        echo ""
        return
    fi

    # Save it ( applies to all existing and future backups on their next run )
    NOTIFY_EMAIL="$input"
    update_definitions
    clear_screen "force"
    echo -e "${GREEN}Backup failure alerts will be sent to:${RESET} ${BOLD}$NOTIFY_EMAIL${RESET}"
    echo ""
}
