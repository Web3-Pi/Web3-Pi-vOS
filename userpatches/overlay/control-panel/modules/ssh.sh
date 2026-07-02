#!/bin/bash
#
# Web3 Pi Control Panel - SSH Security Module
#

ssh_menu() {
    while true; do
        # Get current SSH settings
        PASS_AUTH=$(grep -E "^PasswordAuthentication" $SSHD_CONFIG 2>/dev/null | awk '{print $2}')
        PUBKEY_AUTH=$(grep -E "^PubkeyAuthentication" $SSHD_CONFIG 2>/dev/null | awk '{print $2}')
        FIDO2_ONLY=$(grep -E "^PubkeyAcceptedKeyTypes sk-" $SSHD_CONFIG 2>/dev/null && echo "yes" || echo "no")

        [ -z "$PASS_AUTH" ] && PASS_AUTH="yes"
        [ -z "$PUBKEY_AUTH" ] && PUBKEY_AUTH="yes"

        CHOICE=$(whiptail --title "SSH Security" \
            --menu "Password: $PASS_AUTH | PubKey: $PUBKEY_AUTH | FIDO2 only: $FIDO2_ONLY" \
            $TERM_HEIGHT $TERM_WIDTH $LIST_HEIGHT \
            "1" "Add SSH Public Key" \
            "2" "List Authorized Keys" \
            "3" "Remove SSH Key" \
            "4" "Password Authentication [$PASS_AUTH]" \
            "5" "Public Key Authentication [$PUBKEY_AUTH]" \
            "6" "Require FIDO2 Hardware Key [$FIDO2_ONLY]" \
            "7" "Reload SSH Server" \
            "0" "Back to Main Menu" \
            3>&1 1>&2 2>&3)

        case $CHOICE in
            1) ssh_add_key ;;
            2) ssh_list_keys ;;
            3) ssh_remove_key ;;
            4) ssh_toggle_password ;;
            5) ssh_toggle_pubkey ;;
            6) ssh_toggle_fido2 ;;
            7) systemctl reload sshd && msg_box "Success" "SSH server reloaded." ;;
            0|"") return ;;
        esac
    done
}

ssh_add_key() {
    KEY=$(whiptail --title "Add SSH Public Key" \
        --inputbox "Paste your SSH public key:\n(ssh-ed25519, ssh-rsa, or sk-ssh-ed25519 for FIDO2)" \
        $TERM_HEIGHT $TERM_WIDTH 3>&1 1>&2 2>&3)

    if [ -z "$KEY" ]; then
        return
    fi

    # Validate key format
    if [[ ! "$KEY" =~ ^(ssh-(ed25519|rsa|ecdsa)|sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh\.com) ]]; then
        msg_box "Error" "Invalid SSH public key format.\n\nKey should start with:\n- ssh-ed25519\n- ssh-rsa\n- sk-ssh-ed25519@openssh.com"
        return
    fi

    # Create .ssh directory if needed
    mkdir -p "$SSH_DIR"
    chown ethereum:ethereum "$SSH_DIR"
    chmod 700 "$SSH_DIR"

    # Check if key exists
    if [ -f "$AUTH_KEYS" ] && grep -qF "$KEY" "$AUTH_KEYS"; then
        msg_box "Info" "This key is already in authorized_keys."
        return
    fi

    # Add key
    echo "$KEY" >> "$AUTH_KEYS"
    chown ethereum:ethereum "$AUTH_KEYS"
    chmod 600 "$AUTH_KEYS"

    msg_box "Success" "SSH key added successfully!\n\nTest login in a new terminal before disabling password auth."
}

ssh_list_keys() {
    if [ ! -f "$AUTH_KEYS" ] || [ ! -s "$AUTH_KEYS" ]; then
        msg_box "Authorized Keys" "No SSH keys found."
        return
    fi

    KEYS=$(cat "$AUTH_KEYS" | nl -ba)
    whiptail --title "Authorized Keys" --scrolltext --msgbox "$KEYS" $TERM_HEIGHT $TERM_WIDTH
}

ssh_remove_key() {
    if [ ! -f "$AUTH_KEYS" ] || [ ! -s "$AUTH_KEYS" ]; then
        msg_box "Error" "No SSH keys found."
        return
    fi

    # Build menu from keys
    MENU_ITEMS=()
    i=1
    while IFS= read -r line; do
        # Extract comment (last field) or show key type
        COMMENT=$(echo "$line" | awk '{print $NF}')
        TYPE=$(echo "$line" | awk '{print $1}')
        MENU_ITEMS+=("$i" "$TYPE - $COMMENT")
        ((i++))
    done < "$AUTH_KEYS"

    if [ ${#MENU_ITEMS[@]} -eq 0 ]; then
        msg_box "Error" "No SSH keys found."
        return
    fi

    CHOICE=$(whiptail --title "Remove SSH Key" \
        --menu "Select key to remove:" $TERM_HEIGHT $TERM_WIDTH $LIST_HEIGHT \
        "${MENU_ITEMS[@]}" \
        3>&1 1>&2 2>&3)

    if [ -n "$CHOICE" ]; then
        if yesno_box "Confirm" "Remove key #$CHOICE?"; then
            sed -i "${CHOICE}d" "$AUTH_KEYS"
            msg_box "Success" "Key removed."
        fi
    fi
}

ssh_toggle_password() {
    CURRENT=$(grep -E "^PasswordAuthentication" $SSHD_CONFIG 2>/dev/null | awk '{print $2}')
    [ -z "$CURRENT" ] && CURRENT="yes"

    if [ "$CURRENT" = "yes" ]; then
        if yesno_box "Disable Password Auth" "Disable password authentication?\n\nMake sure you have SSH key access first!"; then
            sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' $SSHD_CONFIG
            grep -q "^PasswordAuthentication" $SSHD_CONFIG || echo "PasswordAuthentication no" >> $SSHD_CONFIG
            systemctl reload sshd
            msg_box "Success" "Password authentication disabled."
        fi
    else
        if yesno_box "Enable Password Auth" "Enable password authentication?"; then
            sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' $SSHD_CONFIG
            systemctl reload sshd
            msg_box "Success" "Password authentication enabled."
        fi
    fi
}

ssh_toggle_pubkey() {
    CURRENT=$(grep -E "^PubkeyAuthentication" $SSHD_CONFIG 2>/dev/null | awk '{print $2}')
    [ -z "$CURRENT" ] && CURRENT="yes"

    if [ "$CURRENT" = "yes" ]; then
        if yesno_box "Disable PubKey Auth" "Disable public key authentication?\n\nWARNING: You may lose access!"; then
            sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication no/' $SSHD_CONFIG
            grep -q "^PubkeyAuthentication" $SSHD_CONFIG || echo "PubkeyAuthentication no" >> $SSHD_CONFIG
            systemctl reload sshd
            msg_box "Success" "Public key authentication disabled."
        fi
    else
        if yesno_box "Enable PubKey Auth" "Enable public key authentication?"; then
            sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' $SSHD_CONFIG
            systemctl reload sshd
            msg_box "Success" "Public key authentication enabled."
        fi
    fi
}

ssh_toggle_fido2() {
    CURRENT=$(grep -E "^PubkeyAcceptedKeyTypes sk-" $SSHD_CONFIG 2>/dev/null)

    if [ -z "$CURRENT" ]; then
        if yesno_box "Require FIDO2" "Require FIDO2 hardware key for SSH?\n\nOnly sk-ssh-ed25519 and sk-ecdsa keys will be accepted.\n\nMake sure you have a FIDO2 key configured!"; then
            # Remove any existing PubkeyAcceptedKeyTypes
            sed -i '/^PubkeyAcceptedKeyTypes/d' $SSHD_CONFIG
            echo "PubkeyAcceptedKeyTypes sk-ssh-ed25519@openssh.com,sk-ecdsa-sha2-nistp256@openssh.com" >> $SSHD_CONFIG
            systemctl reload sshd
            msg_box "Success" "FIDO2 hardware key required.\n\nOnly hardware-backed keys will work now."
        fi
    else
        if yesno_box "Disable FIDO2 Requirement" "Allow regular SSH keys again?"; then
            sed -i '/^PubkeyAcceptedKeyTypes sk-/d' $SSHD_CONFIG
            systemctl reload sshd
            msg_box "Success" "Regular SSH keys allowed again."
        fi
    fi
}
