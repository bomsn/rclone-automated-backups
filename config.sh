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
CRON_FILE="/etc/cron.d/rclone-automated-backups"
# Shared lock file: every generated backup script grabs this lock so that, no
# matter how many cron entries fire at once, backups run strictly one-at-a-time.
LOCK_FILE="/tmp/rclone-automated-backups.lock"
# Back-compat constants. The tool was originally called
# "rclone-automated-backups-for-wordpress" and stored its cron entries and lock
# file under "-by-alikhallad" paths. After the rename to "rclone-automated-backups"
# we keep reading and locking against the legacy paths so an existing install
# that just runs "git pull" keeps its scheduled backups visible and mutually
# excludes against any in-flight script generated before the rename. Cron reads
# every file in /etc/cron.d/ so leaving the legacy file in place is harmless.
COMPAT_CRON_FILE="/etc/cron.d/rclone-automated-backups-by-alikhallad"
COMPAT_LOCK_FILE="/tmp/rclone-automated-backups-by-alikhallad.lock"
# How long ( seconds ) a queued backup waits for the shared lock before giving
# up for this cycle. 18h is long enough for a full nightly queue to drain.
LOCK_TIMEOUT=64800
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

# Resolve the directory this script lives in, so the lib/ modules load regardless
# of the current working directory.
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Load the function modules
source "$SCRIPT_DIR/lib/ui.sh"
source "$SCRIPT_DIR/lib/definitions.sh"
source "$SCRIPT_DIR/lib/domains.sh"
source "$SCRIPT_DIR/lib/rclone.sh"
source "$SCRIPT_DIR/lib/backup-create.sh"
source "$SCRIPT_DIR/lib/restore.sh"
source "$SCRIPT_DIR/lib/backup-manage.sh"
source "$SCRIPT_DIR/lib/notifications.sh"
source "$SCRIPT_DIR/lib/menu.sh"
source "$SCRIPT_DIR/lib/headless.sh"

# True when the given php binary is the CLI SAPI, false for cgi-fcgi / fpm /
# anything else. wp-cli refuses to run under non-cli SAPIs ( cPanel's
# /usr/local/bin/php is cgi-fcgi, for example ), so we must validate before
# accepting a candidate.
_is_cli_php() {
  [ -x "$1" ] && "$1" -v 2>/dev/null | head -1 | grep -q '(cli)'
}

resolve_wp_cli_runtime() {
  WP_CLI_PATH=""
  WP_PHP_BIN=""

  if command -v wp &>/dev/null; then
    WP_CLI_PATH="$(command -v wp)"
  elif [ -f "/usr/local/bin/wp" ]; then
    WP_CLI_PATH="/usr/local/bin/wp"
  else
    return 1
  fi

  # If the php on PATH is the CLI SAPI we can leave WP_PHP_BIN empty and let
  # wp's "#!/usr/bin/env php" shebang find it. Otherwise we MUST pick an
  # explicit CLI binary, because env would otherwise hand wp a cgi-fcgi php
  # ( the common case on cPanel ) and wp-cli would refuse to run.
  local php_on_path=""
  command -v php &>/dev/null && php_on_path="$(command -v php)"
  if [ -n "$php_on_path" ] && _is_cli_php "$php_on_path"; then
    return 0
  fi

  local php_candidate
  for php_candidate in \
    $(find /opt/plesk/php -mindepth 3 -maxdepth 3 -path '*/bin/php' -type f -perm -111 2>/dev/null | sort -Vr) \
    $(find /opt/cpanel -mindepth 5 -maxdepth 5 -path '*/ea-php*/root/usr/bin/php' -type f -perm -111 2>/dev/null | sort -Vr) \
    /usr/local/bin/php /usr/bin/php; do
    if _is_cli_php "$php_candidate"; then
      WP_PHP_BIN="$php_candidate"
      return 0
    fi
  done

  return 0
}

wp_cli_display() {
  if [ -n "$WP_PHP_BIN" ]; then
    printf '%s %s' "$WP_PHP_BIN" "$WP_CLI_PATH"
  else
    printf '%s' "$WP_CLI_PATH"
  fi
}

run_wp_cli() {
  if [ -n "$WP_PHP_BIN" ]; then
    "$WP_PHP_BIN" "$WP_CLI_PATH" "$@"
  else
    "$WP_CLI_PATH" "$@"
  fi
}

run_wp_cli_as() {
  local wp_user="$1"
  shift

  if [ -n "$WP_PHP_BIN" ]; then
    sudo -u "$wp_user" -s -- "$WP_PHP_BIN" "$WP_CLI_PATH" "$@"
  else
    sudo -u "$wp_user" -s -- "$WP_CLI_PATH" "$@"
  fi
}

# Disable terminal bracketed-paste mode so pasted input ( file paths, lists of
# numbers, etc. ) is read cleanly, without the wrapping markers some terminals
# add. Interactive only - skipped in headless mode to keep its output clean.
[ $# -eq 0 ] && printf '\e[?2004l'

# Clear the screen for the interactive menu ( skipped in headless mode )
[ $# -eq 0 ] && clear_screen

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
  [ $# -eq 0 ] && echo -e "${GREEN}1. Current user has sudo privileges.${RESET}"
else
  echo -e "${RED}1. Current user does not have sudo privileges. This script is only available for sudo users.${RESET}"
  echo ""
  exit 1
fi

# Check if wp cli is available
if resolve_wp_cli_runtime; then
  [ $# -eq 0 ] && echo -e "${GREEN}2. wp cli is available.${RESET}"
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

# Verify wp-cli can run end-to-end. `wp --info` is the broadest sanity test:
# it works on every wp-cli version we support, does not require --allow-root
# on modern releases ( it is purely diagnostic ), and exercises the same
# PHP-resolution path a real backup would use. `cli version --allow-root` is
# kept as a fallback for older / stricter wp-cli builds.
if ! run_wp_cli --info &>/dev/null && ! run_wp_cli cli version --allow-root &>/dev/null; then
  echo -e "${RED}2b. wp-cli could not run - no usable PHP CLI binary was found.${RESET}"
  echo -e "${RED}    Install php-cli, or make sure /opt/plesk/php/*/bin/php ( Plesk )${RESET}"
  echo -e "${RED}    or /opt/cpanel/ea-php*/root/usr/bin/php ( cPanel ) exists.${RESET}"
  echo ""
  exit 1
fi
[ $# -eq 0 ] && echo -e "${GREEN}2b. wp-cli runs ( $(wp_cli_display) ).${RESET}"

# Check if rclone is available
if command -v rclone &>/dev/null; then
  [ $# -eq 0 ] && echo -e "${GREEN}3. rclone is available.${RESET}"
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
  [ $# -eq 0 ] && echo -e "${GREEN}4. restic is available.${RESET}"
  RESTIC_AVAILABLE=true
elif [ -f "/usr/local/bin/restic" ]; then
  [ $# -eq 0 ] && echo -e "${YELLOW}4. restic found in /usr/local/bin/restic. To make it available system-wide:${RESET}"
  [ $# -eq 0 ] && echo -e "${YELLOW}Run: ${RESET}${BOLD}${YELLOW}sudo ln -s /usr/local/bin/restic /usr/bin/restic${RESET}"
  RESTIC_AVAILABLE=false
else
  [ $# -eq 0 ] && echo -e "${YELLOW}4. restic is not available ( optional for incremental backups ).${RESET}"
  RESTIC_AVAILABLE=false
fi

# Show the system-check summary banner ( interactive mode only )
if [ $# -eq 0 ]; then
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
fi

####################################################################################################
################################# OUTPUT THE CONFIGURATION OPTIONS #################################
####################################################################################################

# Headless / non-interactive mode: when arguments are passed, create a single
# backup straight from CLI flags and exit without showing the interactive menu.
if [ $# -gt 0 ]; then
  run_headless "$@"
  exit $?
fi

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
