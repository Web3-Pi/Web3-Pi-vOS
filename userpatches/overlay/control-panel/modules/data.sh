#!/bin/bash
#
# Web3 Pi Control Panel - Data Management Module
#

data_menu() {
    while true; do
        CHOICE=$(whiptail --title "Data Management" \
            --menu "WARNING: Data deletion is irreversible!" \
            $TERM_HEIGHT $TERM_WIDTH $LIST_HEIGHT \
            "1" "Wipe Geth Data (/var/lib/el)" \
            "2" "Wipe Nimbus Beacon Data (/var/lib/cl)" \
            "3" "Wipe Signer Data (/home/signer)" \
            "4" "Wipe ALL Data" \
            "5" "View Disk Usage" \
            "0" "Back to Main Menu" \
            3>&1 1>&2 2>&3)

        case $CHOICE in
            1) data_wipe "geth" "/var/lib/el" "Geth" ;;
            2) data_wipe "nimbus-beacon-node" "/var/lib/cl" "Nimbus Beacon" ;;
            3) data_wipe "nimbus-validator" "/home/signer" "Signer" ;;
            4) data_wipe_all ;;
            5) data_disk_usage ;;
            0|"") return ;;
        esac
    done
}

data_wipe() {
    SERVICE=$1
    DIR=$2
    NAME=$3

    if ! yesno_box "WARNING" "This will DELETE all $NAME data!\n\nDirectory: $DIR\n\nThis action is IRREVERSIBLE!\n\nContinue?"; then
        return
    fi

    # Double confirm
    CONFIRM=$(input_box "Confirm Deletion" "Type 'DELETE' to confirm:" "")
    if [ "$CONFIRM" != "DELETE" ]; then
        msg_box "Cancelled" "Deletion cancelled."
        return
    fi

    # Stop service
    systemctl stop $SERVICE 2>/dev/null

    # Wipe data
    if [ -d "$DIR" ]; then
        rm -rf "$DIR"/*
        msg_box "Success" "$NAME data deleted.\n\nYou will need to re-sync."
    else
        msg_box "Error" "Directory not found: $DIR"
    fi
}

data_wipe_all() {
    if ! yesno_box "DANGER" "This will DELETE ALL Ethereum data!\n\n- Geth data\n- Nimbus beacon data\n- Signer data (validator keys!)\n\nThis action is IRREVERSIBLE!\n\nContinue?"; then
        return
    fi

    CONFIRM=$(input_box "Confirm Deletion" "Type 'DELETE ALL' to confirm:" "")
    if [ "$CONFIRM" != "DELETE ALL" ]; then
        msg_box "Cancelled" "Deletion cancelled."
        return
    fi

    # Stop all services
    systemctl stop nimbus-validator nimbus-beacon-node geth 2>/dev/null

    # Wipe all data
    rm -rf /var/lib/el/*
    rm -rf /var/lib/cl/*
    rm -rf /home/signer/* 2>/dev/null

    msg_box "Success" "All Ethereum data deleted.\n\nYou will need to:\n1. Run trusted node sync\n2. Re-import validator keys"
}

data_disk_usage() {
    USAGE="Disk Usage:\n\n"
    USAGE+="Geth (/var/lib/el):\n  $(du -sh /var/lib/el 2>/dev/null | cut -f1 || echo 'N/A')\n\n"
    USAGE+="Nimbus (/var/lib/cl):\n  $(du -sh /var/lib/cl 2>/dev/null | cut -f1 || echo 'N/A')\n\n"
    USAGE+="Signer (/home/signer):\n  $(du -sh /home/signer 2>/dev/null | cut -f1 || echo 'N/A')\n\n"
    USAGE+="Total disk:\n$(df -h / | tail -1 | awk '{print "  Used: "$3" / "$2" ("$5")"}')"

    msg_box "Disk Usage" "$USAGE"
}
