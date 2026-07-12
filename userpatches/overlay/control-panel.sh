#!/bin/bash
#
# Web3 Pi Staking - Control Panel
# TUI configurator using whiptail
#
# Usage: sudo /opt/web3pi/control-panel.sh
#

# Determine script location (handle symlinks)
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
MODULE_DIR="${SCRIPT_DIR}/control-panel"

# Source common library
if [ ! -f "${MODULE_DIR}/lib/common.sh" ]; then
    echo "Error: Cannot find control panel modules at ${MODULE_DIR}"
    echo "Make sure the control-panel directory exists alongside this script."
    exit 1
fi

source "${MODULE_DIR}/lib/common.sh"

# Source all modules
for module in "${MODULE_DIR}/modules/"*.sh; do
    if [ -f "$module" ]; then
        source "$module"
    fi
done

#------------------------------------------------------------------------------
# Main Menu
#------------------------------------------------------------------------------

main_menu() {
    # Get hostname and IP for title
    HOSTNAME=$(hostname)
    IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "N/A")

    while true; do
        CHOICE=$(whiptail --title "Web3 Pi Staking [$HOSTNAME - $IP]" \
            --menu "Select an option:" $TERM_HEIGHT $TERM_WIDTH 12 \
            "1" "Eth Network Configuration" \
            "2" "SSH Security" \
            "3" "LUKS Encrypted Storage" \
            "4" "Initial Sync" \
            "5" "Service Management" \
            "6" "Monitoring" \
            "7" "Data Management" \
            "8" "System" \
            "9" "Validator Management" \
            "A" "Arkiv [coming soon]" \
            "F" "Internet Failover (LTE)" \
            "0" "Exit" \
            3>&1 1>&2 2>&3)

        case $CHOICE in
            1) network_menu ;;
            2) ssh_menu ;;
            3) luks_menu ;;
            4) sync_menu ;;
            5) service_menu ;;
            6) monitoring_menu ;;
            7) data_menu ;;
            8) system_menu ;;
            9) validator_menu ;;
            A) msg_box "Arkiv" "This feature is coming soon." ;;
            F) failover_menu ;;
            0|"") exit 0 ;;
        esac
    done
}

#------------------------------------------------------------------------------
# Main
#------------------------------------------------------------------------------

check_root

# Single instance: concurrent panels race on the config file — save_config
# rewrites it wholesale from (possibly stale) shell state, so a second session
# would clobber the first one's changes.
exec 9>/run/web3pi-control-panel.lock
if ! flock -n 9; then
    echo "Another control-panel session is already running (config would be clobbered)."
    exit 1
fi

main_menu
