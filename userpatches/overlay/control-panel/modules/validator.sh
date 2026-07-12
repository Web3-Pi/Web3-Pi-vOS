#!/bin/bash
#
# Web3 Pi Control Panel - Validator Management Module
#

# Staging directory for validator keystore import (easy SCP access)
VALIDATOR_KEYS_STAGING="/home/ethereum/validator_keys"

validator_menu() {
    while true; do
        load_config
        # Get validator status
        VC_STATUS=$(systemctl is-active nimbus-validator 2>/dev/null || echo "inactive")
        LUKS_MOUNTED="No"
        mountpoint -q /home/signer 2>/dev/null && LUKS_MOUNTED="Yes"

        # Count imported validators
        VALIDATOR_COUNT=0
        if [ -d /home/signer/keys/validators ]; then
            VALIDATOR_COUNT=$(find /home/signer/keys/validators -maxdepth 1 -type d -name "0x*" 2>/dev/null | wc -l)
        fi

        # Shorten fee recipient for display
        FEE_SHORT="${FEE_RECIPIENT:0:10}...${FEE_RECIPIENT: -4}"

        CHOICE=$(whiptail --title "Validator Management" \
            --menu "Status: $VC_STATUS | LUKS: $LUKS_MOUNTED | Validators: $VALIDATOR_COUNT" \
            $TERM_HEIGHT $TERM_WIDTH $LIST_HEIGHT \
            "1" "Import Validator Keys" \
            "2" "List Validators" \
            "3" "Configure Fee Recipient [$FEE_SHORT]" \
            "4" "Configure Graffiti [$GRAFFITI]" \
            "5" "Start Validator" \
            "6" "Stop Validator" \
            "7" "View Validator Status" \
            "8" "Voluntary Exit (EXIT STAKING)" \
            "0" "Back to Main Menu" \
            3>&1 1>&2 2>&3)

        case $CHOICE in
            1) validator_import_keys ;;
            2) validator_list ;;
            3) validator_fee_recipient ;;
            4) validator_graffiti ;;
            5) validator_start ;;
            6) validator_stop ;;
            7) validator_status ;;
            8) validator_voluntary_exit ;;
            0|"") return ;;
        esac
    done
}

validator_import_keys() {
    # Check if LUKS is mounted
    if ! mountpoint -q /home/signer 2>/dev/null; then
        msg_box "Error" "LUKS partition not mounted!\n\nFirst unlock the encrypted storage:\n  Menu -> LUKS Encrypted Storage -> Unlock LUKS"
        return
    fi

    # Create keys directory if it doesn't exist
    mkdir -p /home/signer/keys
    chown signer:signer /home/signer/keys
    chmod 700 /home/signer/keys

    CHOICE=$(whiptail --title "Import Validator Keys" \
        --menu "Select key source:" $TERM_HEIGHT $TERM_WIDTH $LIST_HEIGHT \
        "1" "From ~/validator_keys (copy keys via SSH first)" \
        "2" "From USB drive" \
        "0" "Back" \
        3>&1 1>&2 2>&3)

    case $CHOICE in
        1) validator_import_from_staging ;;
        2) validator_import_from_usb ;;
    esac
}

validator_import_from_staging() {
    # Ensure staging directory exists
    mkdir -p "$VALIDATOR_KEYS_STAGING"
    chown ethereum:ethereum "$VALIDATOR_KEYS_STAGING"
    chmod 700 "$VALIDATOR_KEYS_STAGING"

    # Find keystore files in staging directory
    KEYSTORES=$(find "$VALIDATOR_KEYS_STAGING" -maxdepth 1 -name "keystore-*.json" 2>/dev/null)

    if [ -z "$KEYSTORES" ]; then
        msg_box "No Keys Found" "No keystore files found in ~/validator_keys/\n\nCopy your keystore files first:\n  scp keystore-*.json ethereum@<ip>:~/validator_keys/"
        return
    fi

    # Count and list keystores
    COUNT=$(echo "$KEYSTORES" | wc -l)
    LIST=$(echo "$KEYSTORES" | xargs -n1 basename | head -10)
    if [ "$COUNT" -gt 10 ]; then
        LIST="$LIST\n... and $((COUNT-10)) more"
    fi

    if ! yesno_box "Import Keys" "Found $COUNT keystore file(s):\n\n$LIST\n\nImport these keys?"; then
        return
    fi

    # Run import
    clear
    echo ""
    echo "============================================================"
    echo "  IMPORTING VALIDATOR KEYS"
    echo "============================================================"
    echo ""
    echo "You will be prompted to enter the keystore password."
    echo ""

    # Run nimbus import command (source: staging dir, destination: LUKS partition)
    if nimbus_beacon_node deposits import --data-dir=/home/signer/keys "$VALIDATOR_KEYS_STAGING"; then
        echo ""
        echo "Setting permissions..."
        chown -R signer:signer /home/signer/keys
        chmod -R 700 /home/signer/keys

        # Count imported validators
        NEW_COUNT=$(find /home/signer/keys/validators -maxdepth 1 -type d -name "0x*" 2>/dev/null | wc -l)

        echo ""
        echo "============================================================"
        echo "  IMPORT COMPLETE"
        echo "============================================================"
        echo ""
        echo "Successfully imported! Total validators: $NEW_COUNT"
        echo ""
        echo "Next steps:"
        echo "  1. Configure fee recipient (IMPORTANT!)"
        echo "  2. Start the validator"
        echo ""

        read -p "Press Enter to continue..."

        # Offer to clean up original keystore files
        validator_cleanup_staging "$KEYSTORES"
    else
        echo ""
        echo "============================================================"
        echo "  IMPORT FAILED"
        echo "============================================================"
        echo ""
        echo "Check error messages above."
        echo ""
        read -p "Press Enter to continue..."
    fi
}

validator_cleanup_staging() {
    KEYSTORES="$1"
    COUNT=$(echo "$KEYSTORES" | wc -l)
    LIST=$(echo "$KEYSTORES" | xargs -n1 basename)

    MSG="The original keystore files will be moved to the encrypted\n"
    MSG+="LUKS partition. They are needed for Voluntary Exit.\n\n"
    MSG+="Move the following $COUNT file(s) to encrypted storage?\n\n"
    MSG+="$LIST"

    if yesno_box "Move to Encrypted Storage" "$MSG"; then
        mv $KEYSTORES /home/signer/keys/
        chown signer:signer /home/signer/keys/keystore-*.json 2>/dev/null
        chmod 600 /home/signer/keys/keystore-*.json 2>/dev/null
        msg_box "Move Complete" "Keystore files moved to encrypted LUKS partition.\n\nLocation: /home/signer/keys/\n\nThese files are needed for Voluntary Exit."
    else
        msg_box "Files Kept in Staging" "Files kept in ~/validator_keys/\n\nWARNING: This location is NOT encrypted!\nConsider moving them manually:\n  sudo mv ~/validator_keys/*.json /home/signer/keys/"
    fi
}

validator_import_from_usb() {
    # Detect USB devices
    USB_DEVICES=$(lsblk -o NAME,SIZE,TYPE,TRAN -d -n 2>/dev/null | grep -E "usb" | awk '{print $1}')

    if [ -z "$USB_DEVICES" ]; then
        msg_box "No USB Found" "No USB drives detected.\n\nPlug in your USB drive and try again."
        return
    fi

    # Build menu from USB devices
    MENU_ITEMS=()
    for DEV in $USB_DEVICES; do
        SIZE=$(lsblk -o SIZE -d -n /dev/$DEV 2>/dev/null)
        MENU_ITEMS+=("$DEV" "$SIZE")
    done

    DEV_CHOICE=$(whiptail --title "Select USB Drive" \
        --menu "Choose USB drive:" $TERM_HEIGHT $TERM_WIDTH $LIST_HEIGHT \
        "${MENU_ITEMS[@]}" \
        3>&1 1>&2 2>&3)

    if [ -z "$DEV_CHOICE" ]; then
        return
    fi

    # Find partitions on the device
    PARTITIONS=$(lsblk -o NAME -n /dev/$DEV_CHOICE 2>/dev/null | tail -n +2)
    if [ -z "$PARTITIONS" ]; then
        # No partitions, use the device itself
        USB_PART="/dev/$DEV_CHOICE"
    else
        # Use first partition
        USB_PART="/dev/$(echo "$PARTITIONS" | head -1 | tr -d ' ')"
    fi

    # Mount USB
    mkdir -p /mnt/usb

    if ! mount "$USB_PART" /mnt/usb 2>/dev/null; then
        msg_box "Mount Error" "Failed to mount $USB_PART\n\nTry a different filesystem format (FAT32, exFAT, ext4)."
        return
    fi

    # Find keystore files on USB
    KEYSTORES=$(find /mnt/usb -name "keystore-*.json" 2>/dev/null)

    if [ -z "$KEYSTORES" ]; then
        umount /mnt/usb 2>/dev/null
        msg_box "No Keys Found" "No keystore-*.json files found on USB drive."
        return
    fi

    COUNT=$(echo "$KEYSTORES" | wc -l)

    if ! yesno_box "Copy Keys" "Found $COUNT keystore file(s) on USB.\n\nCopy to staging directory?"; then
        umount /mnt/usb 2>/dev/null
        return
    fi

    # Ensure staging directory exists
    mkdir -p "$VALIDATOR_KEYS_STAGING"
    chown ethereum:ethereum "$VALIDATOR_KEYS_STAGING"
    chmod 700 "$VALIDATOR_KEYS_STAGING"

    # Copy keystores to staging directory
    cp $KEYSTORES "$VALIDATOR_KEYS_STAGING/"
    chown ethereum:ethereum "$VALIDATOR_KEYS_STAGING"/keystore-*.json
    chmod 600 "$VALIDATOR_KEYS_STAGING"/keystore-*.json

    # Unmount USB
    umount /mnt/usb 2>/dev/null

    msg_box "Keys Copied" "$COUNT keystore file(s) copied to ~/validator_keys/\n\nProceeding to import..."

    # Automatically proceed to import
    validator_import_from_staging
}

validator_list() {
    if ! mountpoint -q /home/signer 2>/dev/null; then
        msg_box "Error" "LUKS partition not mounted!"
        return
    fi

    if [ ! -d /home/signer/keys/validators ]; then
        msg_box "No Validators" "No validators imported yet.\n\nUse 'Import Validator Keys' first."
        return
    fi

    INFO="Imported Validators:\n"
    INFO+="─────────────────────────────────────────────────────────\n\n"

    COUNT=0
    for DIR in /home/signer/keys/validators/0x*/; do
        if [ -d "$DIR" ]; then
            PUBKEY=$(basename "$DIR")
            # Full pubkey (98 chars) split across two lines to fit the dialog width
            INFO+="  ${PUBKEY:0:50}\n"
            INFO+="    ${PUBKEY:50}\n\n"
            ((COUNT++))
        fi
    done

    if [ "$COUNT" -eq 0 ]; then
        INFO+="  No validators found.\n"
    else
        INFO+="─────────────────────────────────────────────────────────\n"
        INFO+="Total: $COUNT validator(s)\n"
    fi

    whiptail --title "Validator List" --scrolltext --msgbox "$INFO" $TERM_HEIGHT $TERM_WIDTH
}

validator_fee_recipient() {
    load_config

    CURRENT="${FEE_RECIPIENT:-0x0000000000000000000000000000000000000000}"

    NEW_ADDR=$(whiptail --title "Configure Fee Recipient" \
        --inputbox "Enter Ethereum address for block rewards:\n\nCurrent: $CURRENT\n\nThis address will receive transaction fees from blocks your validator proposes." \
        $TERM_HEIGHT $TERM_WIDTH "$CURRENT" 3>&1 1>&2 2>&3)

    if [ -z "$NEW_ADDR" ]; then
        return
    fi

    # Validate Ethereum address format
    if [[ ! "$NEW_ADDR" =~ ^0x[a-fA-F0-9]{40}$ ]]; then
        msg_box "Invalid Address" "Invalid Ethereum address format.\n\nMust be 0x followed by 40 hex characters."
        return
    fi

    if [ "$NEW_ADDR" = "$CURRENT" ]; then
        return
    fi

    FEE_RECIPIENT="$NEW_ADDR"
    save_config

    msg_box "Fee Recipient Set" "Fee recipient updated to:\n$NEW_ADDR\n\nRestart the validator for changes to take effect."
}

validator_graffiti() {
    load_config

    CURRENT="${GRAFFITI:-Web3Pi}"

    NEW_GRAFFITI=$(whiptail --title "Configure Graffiti" \
        --inputbox "Enter graffiti message (max 32 characters):\n\nThis text appears in blocks your validator proposes.\n\nCurrent: $CURRENT" \
        $TERM_HEIGHT $TERM_WIDTH "$CURRENT" 3>&1 1>&2 2>&3)

    if [ -z "$NEW_GRAFFITI" ]; then
        return
    fi

    # Check length (max 32 bytes)
    if [ ${#NEW_GRAFFITI} -gt 32 ]; then
        msg_box "Too Long" "Graffiti must be 32 characters or less.\n\nYour input: ${#NEW_GRAFFITI} characters"
        return
    fi

    if [ "$NEW_GRAFFITI" = "$CURRENT" ]; then
        return
    fi

    GRAFFITI="$NEW_GRAFFITI"
    save_config

    msg_box "Graffiti Set" "Graffiti updated to:\n$NEW_GRAFFITI\n\nRestart the validator for changes to take effect."
}

validator_start() {
    load_config

    # Check LUKS
    if ! mountpoint -q /home/signer 2>/dev/null; then
        msg_box "Error" "LUKS partition not mounted!\n\nFirst unlock the encrypted storage."
        return
    fi

    # Check for imported validators
    VALIDATOR_COUNT=0
    if [ -d /home/signer/keys/validators ]; then
        VALIDATOR_COUNT=$(find /home/signer/keys/validators -maxdepth 1 -type d -name "0x*" 2>/dev/null | wc -l)
    fi

    if [ "$VALIDATOR_COUNT" -eq 0 ]; then
        msg_box "No Validators" "No validators imported!\n\nImport validator keys first."
        return
    fi

    # Warn about zero fee recipient
    if [ "$FEE_RECIPIENT" = "0x0000000000000000000000000000000000000000" ]; then
        if ! yesno_box "Warning: Zero Fee Recipient" "Fee recipient is set to zero address!\n\nTransaction fees will be LOST.\n\nConfigure fee recipient first?\n\n(No = start anyway)"; then
            # User chose No, proceed anyway
            :
        else
            # User chose Yes, go to fee recipient config
            validator_fee_recipient
            return
        fi
    fi

    # Check if already running
    if systemctl is-active --quiet nimbus-validator; then
        msg_box "Already Running" "Nimbus validator is already running."
        return
    fi

    # Start validator
    systemctl start nimbus-validator

    sleep 2

    if systemctl is-active --quiet nimbus-validator; then
        msg_box "Validator Started" "Nimbus validator started successfully!\n\nValidators: $VALIDATOR_COUNT\nFee Recipient: $FEE_RECIPIENT\nGraffiti: $GRAFFITI\n\nView logs: journalctl -u nimbus-validator -f"
    else
        msg_box "Start Failed" "Failed to start validator.\n\nCheck logs: journalctl -u nimbus-validator -n 50"
    fi
}

validator_stop() {
    if ! systemctl is-active --quiet nimbus-validator; then
        msg_box "Not Running" "Nimbus validator is not running."
        return
    fi

    if yesno_box "Stop Validator" "Stop the Nimbus validator?\n\nYour validator will stop performing duties until restarted."; then
        systemctl stop nimbus-validator
        msg_box "Validator Stopped" "Nimbus validator stopped."
    fi
}

validator_status() {
    load_config

    INFO="═══════════════════════════════════════════════════════════\n"
    INFO+="                    VALIDATOR STATUS\n"
    INFO+="═══════════════════════════════════════════════════════════\n\n"

    # Service status
    VC_STATUS=$(systemctl is-active nimbus-validator 2>/dev/null || echo "inactive")
    VC_ENABLED=$(systemctl is-enabled nimbus-validator 2>/dev/null || echo "disabled")

    INFO+="▶ SERVICE\n"
    INFO+="─────────────────────────────────────────────────────────\n"
    INFO+="  Status: $VC_STATUS\n"
    INFO+="  Boot: $VC_ENABLED\n"

    # LUKS status
    INFO+="\n▶ ENCRYPTED STORAGE\n"
    INFO+="─────────────────────────────────────────────────────────\n"
    if mountpoint -q /home/signer 2>/dev/null; then
        INFO+="  LUKS: Unlocked and mounted\n"
    else
        INFO+="  LUKS: LOCKED (validator cannot run)\n"
    fi

    # Validator count
    INFO+="\n▶ VALIDATORS\n"
    INFO+="─────────────────────────────────────────────────────────\n"
    VALIDATOR_COUNT=0
    if [ -d /home/signer/keys/validators ]; then
        VALIDATOR_COUNT=$(find /home/signer/keys/validators -maxdepth 1 -type d -name "0x*" 2>/dev/null | wc -l)
    fi
    INFO+="  Imported: $VALIDATOR_COUNT\n"

    # Configuration
    INFO+="\n▶ CONFIGURATION\n"
    INFO+="─────────────────────────────────────────────────────────\n"
    INFO+="  Fee Recipient: ${FEE_RECIPIENT:-not set}\n"
    INFO+="  Graffiti: ${GRAFFITI:-Web3Pi}\n"
    INFO+="  Beacon Node: http://127.0.0.1:5052\n"

    # Beacon node connection check
    INFO+="\n▶ BEACON NODE\n"
    INFO+="─────────────────────────────────────────────────────────\n"
    if systemctl is-active --quiet nimbus-beacon-node; then
        INFO+="  Status: Running\n"
        # Check sync status
        SYNC_DATA=$(curl -s http://127.0.0.1:5052/eth/v1/node/syncing 2>/dev/null)
        if [ -n "$SYNC_DATA" ]; then
            IS_SYNCING=$(echo "$SYNC_DATA" | jq -r '.data.is_syncing // "unknown"')
            if [ "$IS_SYNCING" = "false" ]; then
                INFO+="  Sync: Completed\n"
            else
                SYNC_DIST=$(echo "$SYNC_DATA" | jq -r '.data.sync_distance // "?"')
                INFO+="  Sync: In progress ($SYNC_DIST slots behind)\n"
            fi
        fi
    else
        INFO+="  Status: NOT RUNNING (validator needs beacon node!)\n"
    fi

    whiptail --title "Validator Status" --scrolltext --msgbox "$INFO" 24 $TERM_WIDTH
}

validator_voluntary_exit() {
    load_config

    # Check LUKS
    if ! mountpoint -q /home/signer 2>/dev/null; then
        msg_box "Error" "LUKS partition not mounted!\n\nFirst unlock the encrypted storage."
        return
    fi

    # Check beacon node is running
    if ! systemctl is-active --quiet nimbus-beacon-node; then
        msg_box "Error" "Beacon node is not running!\n\nStart beacon node first."
        return
    fi

    # Check sync status (use sync_distance, not is_syncing - backfill may have is_syncing=true)
    SYNC_DATA=$(curl -s http://127.0.0.1:5052/eth/v1/node/syncing 2>/dev/null)
    if [ -z "$SYNC_DATA" ]; then
        msg_box "Error" "Cannot connect to beacon node REST API.\n\nMake sure beacon node is running."
        return
    fi
    SYNC_DIST=$(echo "$SYNC_DATA" | jq -r '.data.sync_distance // "999999"')
    if [ "$SYNC_DIST" -gt 10 ] 2>/dev/null; then
        msg_box "Error" "Beacon node is still syncing!\n\nSync distance: $SYNC_DIST slots\n\nWait for sync to complete before exit."
        return
    fi

    # Find keystore files
    KEYSTORES=$(find /home/signer/keys -maxdepth 1 -name "keystore-*.json" 2>/dev/null)
    if [ -z "$KEYSTORES" ]; then
        msg_box "No Keystores" "No keystore files found in /home/signer/keys/\n\nKeystore files are required for voluntary exit.\n\nIf you imported keys, make sure the original\nkeystore-*.json files were moved to LUKS."
        return
    fi

    # Build selection menu
    MENU_ITEMS=()
    IDX=1
    while IFS= read -r KS; do
        BASENAME=$(basename "$KS")
        MENU_ITEMS+=("$IDX" "$BASENAME")
        ((IDX++))
    done <<< "$KEYSTORES"

    CHOICE=$(whiptail --title "Select Validator to Exit" \
        --menu "Choose keystore file to exit:" $TERM_HEIGHT $TERM_WIDTH $LIST_HEIGHT \
        "${MENU_ITEMS[@]}" \
        3>&1 1>&2 2>&3)

    [ -z "$CHOICE" ] && return

    # Get selected keystore
    SELECTED_KS=$(echo "$KEYSTORES" | sed -n "${CHOICE}p")
    SELECTED_NAME=$(basename "$SELECTED_KS")

    # First warning
    MSG="WARNING: VOLUNTARY EXIT\n"
    MSG+="═══════════════════════════════════════════════\n\n"
    MSG+="You are about to EXIT this validator:\n\n"
    MSG+="  $SELECTED_NAME\n\n"
    MSG+="THIS ACTION IS IRREVERSIBLE!\n\n"
    MSG+="• You will STOP earning staking rewards\n"
    MSG+="• You CANNOT re-activate this validator key\n"
    MSG+="• Funds withdrawable after ~27 hours\n"
    MSG+="• Keep node online until exit is finalized\n\n"
    MSG+="Are you ABSOLUTELY SURE you want to exit?"

    if ! yesno_box "CONFIRM VOLUNTARY EXIT" "$MSG"; then
        return
    fi

    # Second confirmation
    if ! yesno_box "FINAL CONFIRMATION" "This is your LAST CHANCE to cancel.\n\nProceed with voluntary exit?"; then
        return
    fi

    # Execute exit
    clear
    echo ""
    echo "============================================================"
    echo "  VOLUNTARY EXIT"
    echo "============================================================"
    echo ""
    echo "Validator: $SELECTED_NAME"
    echo ""
    echo "You will be prompted for your keystore password."
    echo ""

    if nimbus_beacon_node deposits exit \
        --network="$NETWORK" \
        --validator="$SELECTED_KS" \
        --rest-url=http://127.0.0.1:5052; then
        echo ""
        echo "============================================================"
        echo "  EXIT SUBMITTED SUCCESSFULLY"
        echo "============================================================"
        echo ""
        echo "Your voluntary exit has been broadcast to the network."
        echo ""
        echo "Timeline:"
        echo "  • Exit will be processed within a few epochs"
        echo "  • Funds withdrawable ~27 hours after exit epoch"
        echo "  • Keep your node online until exit is finalized"
        echo ""
    else
        echo ""
        echo "============================================================"
        echo "  EXIT FAILED"
        echo "============================================================"
        echo ""
        echo "Check error messages above."
        echo ""
    fi

    read -p "Press Enter to continue..."
}
