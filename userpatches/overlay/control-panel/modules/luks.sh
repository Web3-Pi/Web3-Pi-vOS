#!/bin/bash
#
# Web3 Pi Control Panel - LUKS Encrypted Storage Module
#

luks_menu() {
    while true; do
        # Check LUKS status
        LUKS_STATUS="Not configured"
        if [ -b /dev/mapper/signer_home ]; then
            LUKS_STATUS="Unlocked and mounted"
        elif lsblk -o NAME,TYPE | grep -q "crypt"; then
            LUKS_STATUS="Configured but locked"
        fi

        CHOICE=$(whiptail --title "LUKS Encrypted Storage" \
            --menu "Status: $LUKS_STATUS" \
            $TERM_HEIGHT $TERM_WIDTH $LIST_HEIGHT \
            "1" "Setup LUKS Partition" \
            "2" "Unlock LUKS" \
            "3" "Check Status" \
            "4" "Change Passphrase" \
            "0" "Back to Main Menu" \
            3>&1 1>&2 2>&3)

        case $CHOICE in
            1)
                if yesno_box "Setup LUKS" "This will create an encrypted partition for validator keys.\n\nContinue?"; then
                    clear
                    /opt/web3pi/setup-luks.sh
                    read -p "Press Enter to continue..."
                fi
                ;;
            2)
                clear
                /opt/web3pi/unlock-luks.sh
                read -p "Press Enter to continue..."
                ;;
            3) luks_status ;;
            4) luks_change_passphrase ;;
            0|"") return ;;
        esac
    done
}

luks_status() {
    STATUS="LUKS Status:\n\n"

    if [ -b /dev/mapper/signer_home ]; then
        STATUS+="Encrypted volume: UNLOCKED\n"
        STATUS+="Mount point: $(findmnt -n -o TARGET /dev/mapper/signer_home 2>/dev/null || echo 'Not mounted')\n"
        STATUS+="\nVolume info:\n$(cryptsetup status signer_home 2>/dev/null || echo 'N/A')"
    else
        STATUS+="Encrypted volume: LOCKED or not configured\n"
        STATUS+="\nTo unlock: sudo /opt/web3pi/unlock-luks.sh"
    fi

    msg_box "LUKS Status" "$STATUS"
}

luks_change_passphrase() {
    if ! lsblk -o NAME,TYPE | grep -q "crypt"; then
        msg_box "Error" "No LUKS partition found.\n\nRun 'Setup LUKS Partition' first."
        return
    fi

    # Find LUKS device
    LUKS_DEV=$(lsblk -o NAME,TYPE -rn | grep "part" | head -1 | awk '{print "/dev/"$1}')

    if yesno_box "Change Passphrase" "Change LUKS passphrase?\n\nYou will need to enter the current passphrase first."; then
        clear
        echo "Changing LUKS passphrase..."
        cryptsetup luksChangeKey "$LUKS_DEV"
        read -p "Press Enter to continue..."
    fi
}
