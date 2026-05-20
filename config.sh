#!/bin/bash

#################################################################
# A bash script to setup automated backups for your WordPress websites using rclone and wp-cli
# By: Ali Khallad
# URL: https://alikhallad.com | https://wpali.com
# Tested on: Ubuntu 22.04
# Tested with: rclone v1.53.3, WP-CLI 2.6.0
#################################################################

####################################################################################################
############################## LOAD FUNCTIONS & VARIABLE DEFINITIONS ###############################
####################################################################################################

# Define main paths
CRON_SCRIPTS_DIR="cron_scripts"
TMP_DIR="$PWD/tmp"
DEFINITIONS_FILE="definitions"
LOG_FILE="$PWD/backup.log"
CRON_FILE="/etc/cron.d/rclone-automated-backups-by-alikhallad"
# Define ANSI color codes
BOLD="\033[1m"
UNDERLINE="\033[4m"
RED="\e[31m"
RED_BG="\e[41m"
GREEN="\e[32m"
GREEN_BG="\e[42m"
YELLOW="\e[33m"
BLUE="\e[34m"
BLUE_BG="\e[44m"
RESET="\e[0m" # Reset text formatting

# Load the functions file
source functions.sh

# Disable terminal bracketed-paste mode so pasted input ( file paths, lists of
# numbers, etc. ) is read cleanly, without the wrapping markers some terminals add
printf '\e[?2004l'

# Clear screen
clear_screen

# Check if the definitions file exists
if [ -f "$DEFINITIONS_FILE" ]; then
  # Load the definitions file
  source "$DEFINITIONS_FILE"
  # Update definitions state variables
  update_definitions_state

  # Define an array of required variables
  required_vars=("DOMAINS" "PATHS")

  # Check if all required variables are defined, otherwise update the definitions
  for var in "${required_vars[@]}"; do
    # Use -v to check if the variable is defined
    if ! declare -p "$var" &>/dev/null; then
      echo -e "${YELLOW}####################################################################################################${RESET}"
      echo -e "${YELLOW}# The definitions file is missing some required variables. A fresh copy has been generated.${RESET}"
      echo -e "${YELLOW}# - Previous configurations will be lost.${RESET}"
      echo -e "${YELLOW}# - Previosuly automated backups should continue to work as usual.${RESET}"
      echo -e "${YELLOW}####################################################################################################${RESET}"
      # Regenerate the file content and load it again
      update_definitions
      source "$DEFINITIONS_FILE"
      break
    fi
  done

else
  # If the file is missing, create it
  sudo touch "$DEFINITIONS_FILE"
  # Regenerate the file content and load it again
  update_definitions
  source "$DEFINITIONS_FILE"
fi

####################################################################################################
############################## AUTOMATED CHECKS TO VERIFY SYSTEM SETUP #############################
####################################################################################################

# Check if the user has sudo privileges
if sudo -n true 2>/dev/null; then
  echo -e "${GREEN}1. Current user has sudo privileges.${RESET}"
else
  echo -e "${RED}1. Current user does not have sudo privileges. This script is only available for sudo users.${RESET}"
  echo ""
  exit 1
fi

# Check if wp cli is available
if command -v wp &>/dev/null; then
  echo -e "${GREEN}2. wp cli is available.${RESET}"
elif [ -f "/usr/local/bin/wp" ]; then
  echo -e "${YELLOW}2. wp cli found in /usr/local/bin/wp. To make it available system-wide:${RESET}"
  echo -e "${YELLOW}Run: ${RESET}${BOLD}${YELLOW}sudo ln -s /usr/local/bin/wp /usr/bin/wp${RESET}"
  echo ""
  exit 1
else
  echo -e "${RED}2. wp cli is not available. Please install it before running the script.${RESET}"
  echo -e "${RED}To install wp-cli, follow this guide:${RESET}"
  echo -e "${RED}https://wp-cli.org/#installing${RESET}"
  echo ""
  exit 1
fi

# Check if rclone is available
if command -v rclone &>/dev/null; then
  echo -e "${GREEN}3. rclone is available.${RESET}"
elif [ -f "/usr/local/bin/rclone" ]; then
  echo -e "${YELLOW}3. rclone found in /usr/local/bin/rclone. To make it available system-wide:${RESET}"
  echo -e "${YELLOW}Run: ${RESET}${BOLD}${YELLOW}sudo ln -s /usr/local/bin/rclone /usr/bin/rclone${RESET}"
  echo ""
  exit 1
else
  echo -e "${RED}3. rclone is not available. Please install it before running the script.${RESET}"
  echo -e "${RED}To install rclone, follow this guide:${RESET}"
  echo -e "${RED}https://rclone.org/install/${RESET}"
  echo ""
  exit 1
fi

# Check if restic is available
if command -v restic &>/dev/null; then
  echo -e "${GREEN}4. restic is available.${RESET}"
  RESTIC_AVAILABLE=true
elif [ -f "/usr/local/bin/restic" ]; then
  echo -e "${YELLOW}4. restic found in /usr/local/bin/restic. To make it available system-wide:${RESET}"
  echo -e "${YELLOW}Run: ${RESET}${BOLD}${YELLOW}sudo ln -s /usr/local/bin/restic /usr/bin/restic${RESET}"
  RESTIC_AVAILABLE=false
else
  echo -e "${YELLOW}4. restic is not available ( optional for incremental backups ).${RESET}"
  RESTIC_AVAILABLE=false
fi

# Check if automated backups are configured correctly
if [ $HAS_AUTOMATED_BACKUPS == true ]; then

  echo -e "${GREEN}5. Automated backups has been configured.${RESET}"

  echo ""
  echo -e "${GREEN_BG}---------------------------------------------------------------------------${RESET}"
  echo -e "${GREEN_BG}-------------------- ALL CHECKS COMPLETED SUCCESSFULLY --------------------${RESET}"
  echo -e "${GREEN_BG}------------------------ MANAGE YOUR BACKUPS BELOW ------------------------${RESET}"
  echo -e "${GREEN_BG}---------------------------------------------------------------------------${RESET}"

else
  echo -e "${YELLOW}5. Automated backups has not been configured.${RESET}"

  echo ""
  echo -e "${GREEN_BG}---------------------------------------------------------------------------${RESET}"
  echo -e "${GREEN_BG}------------------- SYSTEM CHECKS COMPLETED SUCCESSFULLY ------------------${RESET}"
  echo -e "${GREEN_BG}------------------ CONFIGURE YOUR AUTOMATED BACKUPS BELOW -----------------${RESET}"
  echo -e "${GREEN_BG}---------------------------------------------------------------------------${RESET}"

fi

####################################################################################################
################################# OUTPUT THE CONFIGURATION OPTIONS #################################
####################################################################################################

while true; do
  # Reset the "clear_screen_last_caller_name" function each time the main menu is generated:
  clear_screen_last_caller_name=""

  echo ""
  ##########################################################
  ########################## 1. Q ##########################
  ##########################################################
  if [[ $ARE_DOMAINS_EMPTY == true && $ARE_DOMAINS_EMPTY != -1 ]]; then
    echo -e "${BLUE_BG}${BOLD}################# MAIN MENU ################${RESET}"
    echo -e "${BLUE_BG}${BOLD}############# Add a site/domain ############${RESET}"

    echo -e "${BOLD}1. Add a site/domain${RESET}"
    echo "2. Quit"
  ##########################################################
  ########################## 2. Q ##########################
  ##########################################################
  elif [ $IS_RCLONE_CONFIGURED == false ]; then
    echo -e "${BLUE_BG}${BOLD}################# MAIN MENU ################${RESET}"
    echo -e "${BLUE_BG}${BOLD}######### Configure rclone remotes #########${RESET}"

    if [ $ARE_DOMAINS_EMPTY == -1 ]; then
      echo "1. Add a site/domain"
    else
      echo "1. Manage sites/domains"
    fi

    echo -e "${BOLD}2. Configure rclone (remotes)${RESET}"
    echo "3. Quit"
  ##########################################################
  ########################## 3. Q ##########################
  ##########################################################
  elif [ $HAS_AUTOMATED_BACKUPS == false ]; then
    echo -e "${BLUE_BG}${BOLD}################# MAIN MENU ################${RESET}"
    echo -e "${BLUE_BG}${BOLD}######### Create an automated backup #######${RESET}"

    if [ $ARE_DOMAINS_EMPTY == -1 ]; then
      echo "1. Add a site/domain"
    else
      echo "1. Manage sites/domains"
    fi

    echo "2. Re-configure rclone (remotes)"
    echo -e "${BOLD}3. Create an automated backup${RESET}"
    echo "4. Quit"
  ##########################################################
  ########################## 4. Q ##########################
  ##########################################################
  else
    echo -e "${BLUE_BG}${BOLD}################# MAIN MENU ################${RESET}"

    if [ $ARE_DOMAINS_EMPTY == -1 ]; then
      echo "1. Add a site/domain"
    else
      echo "1. Manage sites/domains"
    fi

    echo "2. Re-configure rclone (remotes)"
    echo "3. Manage backups"
    echo "4. Quit"
  fi

  read -p "$(echo -e "${BOLD}${BLUE}Enter your choice: ${RESET}")" choice

  ##########################################################
  ########################## 1. A ##########################
  ##########################################################
  if [[ $ARE_DOMAINS_EMPTY == true && $ARE_DOMAINS_EMPTY != -1 ]]; then
    case "$choice" in
    1)
      manage_domains
      ;;
    2)
      # Quit
      clear_screen
      exit 0
      ;;
    *)
      # Show an error message if the used select invalid options
      clear_screen
      echo -e "${RED}Invalid choice. Please select a valid option.${RESET}"
      ;;
    esac
  ##########################################################
  ########################## 2. A ##########################
  ##########################################################
  elif [ $IS_RCLONE_CONFIGURED == false ]; then
    case "$choice" in
    1)
      manage_domains
      ;;
    2)
      configure_rclone
      ;;
    3)
      # Quit
      clear_screen
      exit 0
      ;;
    *)
      # Show an error message if the used select invalid options
      clear_screen
      echo -e "${RED}Invalid choice. Please select a valid option.${RESET}"
      ;;
    esac
  ##########################################################
  ########################## 3. A ##########################
  ##########################################################
  elif [ $HAS_AUTOMATED_BACKUPS == false ]; then
    case "$choice" in
    1)
      manage_domains
      ;;
    2)
      configure_rclone
      ;;
    3)
      generate_backup_script
      ;;
    4)
      # Quit
      clear_screen # clear screen
      exit 0
      ;;
    *)
      # Show an error message if the used select invalid options
      clear_screen
      echo -e "${RED}Invalid choice. Please select a valid option.${RESET}"
      ;;
    esac

  ##########################################################
  ########################## 4. A ##########################
  ##########################################################
  else
    case "$choice" in
    1)
      manage_domains
      ;;
    2)
      configure_rclone
      ;;
    3)
      manage_backups
      ;;
    4)
      # Quit
      clear_screen # clear screen
      exit 0
      ;;
    *)
      # Show an error message if the used select invalid options
      clear_screen
      echo -e "${RED}Invalid choice. Please select a valid option.${RESET}"
      ;;
    esac
  fi
done
