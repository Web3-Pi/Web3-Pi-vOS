#!/bin/bash
#
# Web3 Pi Staking - Control Panel
# TUI configurator using whiptail
#
# Usage: sudo /opt/web3pi/control-panel.sh
#

# Configuration
CONFIG_FILE="/opt/web3pi/config"
SSH_DIR="/home/ethereum/.ssh"
AUTH_KEYS="$SSH_DIR/authorized_keys"
SSHD_CONFIG="/etc/ssh/sshd_config"

# Terminal dimensions
TERM_HEIGHT=20
TERM_WIDTH=70
LIST_HEIGHT=10

# Colors for whiptail
export NEWT_COLORS='
root=,blue
window=,lightgray
border=black,lightgray
textbox=black,lightgray
button=black,cyan
'

#------------------------------------------------------------------------------
# Helper functions
#------------------------------------------------------------------------------

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "Please run as root: sudo $0"
        exit 1
    fi
}

load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    fi
}

save_config() {
    cat > "$CONFIG_FILE" << EOF
# Web3 Pi Staking Configuration

# Network: hoodi, holesky, or mainnet
NETWORK=${NETWORK:-hoodi}

# Geth P2P port (TCP/UDP)
GETH_PORT=${GETH_PORT:-30303}

# Nimbus P2P port (TCP/UDP)
NIMBUS_PORT=${NIMBUS_PORT:-9000}

# NOTE: If you change ports, update UFW firewall rules:
#   sudo ufw delete allow <old_port>/tcp
#   sudo ufw delete allow <old_port>/udp
#   sudo ufw allow <new_port>/tcp
#   sudo ufw allow <new_port>/udp
#   sudo systemctl daemon-reload
#   sudo systemctl restart geth nimbus-beacon-node
EOF
}

msg_box() {
    whiptail --title "$1" --msgbox "$2" $TERM_HEIGHT $TERM_WIDTH
}

yesno_box() {
    whiptail --title "$1" --yesno "$2" $TERM_HEIGHT $TERM_WIDTH
}

input_box() {
    whiptail --title "$1" --inputbox "$2" $TERM_HEIGHT $TERM_WIDTH "$3" 3>&1 1>&2 2>&3
}

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
            "9" "Validator Keys [coming soon]" \
            "A" "Arkiv [coming soon]" \
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
            9) msg_box "Validator Keys" "This feature is coming soon.\n\nValidator key management will allow you to:\n- Import validator keys\n- View validator status\n- Manage fee recipient" ;;
            A) msg_box "Arkiv" "This feature is coming soon." ;;
            0|"") exit 0 ;;
        esac
    done
}

#------------------------------------------------------------------------------
# 1. Eth Network Configuration
#------------------------------------------------------------------------------

network_menu() {
    while true; do
        load_config
        CHOICE=$(whiptail --title "Network Configuration" \
            --menu "Current: NETWORK=$NETWORK, GETH_PORT=$GETH_PORT, NIMBUS_PORT=$NIMBUS_PORT" \
            $TERM_HEIGHT $TERM_WIDTH $LIST_HEIGHT \
            "1" "Select Network" \
            "2" "Configure Geth P2P Port" \
            "3" "Configure Nimbus P2P Port" \
            "4" "View Current Config" \
            "0" "Back to Main Menu" \
            3>&1 1>&2 2>&3)

        case $CHOICE in
            1) network_select ;;
            2) network_geth_port ;;
            3) network_nimbus_port ;;
            4) msg_box "Current Configuration" "$(cat $CONFIG_FILE)" ;;
            0|"") return ;;
        esac
    done
}

network_select() {
    load_config
    NETWORK=$(whiptail --title "Select Network" \
        --radiolist "Choose Ethereum network:" $TERM_HEIGHT $TERM_WIDTH 4 \
        "hoodi" "Testnet (recommended for testing)" $([ "$NETWORK" = "hoodi" ] && echo "ON" || echo "OFF") \
        "holesky" "Testnet (alternative)" $([ "$NETWORK" = "holesky" ] && echo "ON" || echo "OFF") \
        "mainnet" "Production (real ETH!)" $([ "$NETWORK" = "mainnet" ] && echo "ON" || echo "OFF") \
        3>&1 1>&2 2>&3)

    if [ -n "$NETWORK" ]; then
        save_config
        msg_box "Network Changed" "Network set to: $NETWORK\n\nRemember to:\n1. Run trusted node sync\n2. Restart services"
    fi
}

network_geth_port() {
    load_config
    NEW_PORT=$(input_box "Geth P2P Port" "Enter Geth P2P port (current: $GETH_PORT):" "$GETH_PORT")

    if [ -n "$NEW_PORT" ] && [ "$NEW_PORT" != "$GETH_PORT" ]; then
        OLD_PORT=$GETH_PORT
        GETH_PORT=$NEW_PORT
        save_config
        msg_box "Port Changed" "Geth port changed: $OLD_PORT -> $NEW_PORT\n\nUpdate firewall:\n  sudo ufw delete allow $OLD_PORT/tcp\n  sudo ufw delete allow $OLD_PORT/udp\n  sudo ufw allow $NEW_PORT/tcp\n  sudo ufw allow $NEW_PORT/udp"
    fi
}

network_nimbus_port() {
    load_config
    NEW_PORT=$(input_box "Nimbus P2P Port" "Enter Nimbus P2P port (current: $NIMBUS_PORT):" "$NIMBUS_PORT")

    if [ -n "$NEW_PORT" ] && [ "$NEW_PORT" != "$NIMBUS_PORT" ]; then
        OLD_PORT=$NIMBUS_PORT
        NIMBUS_PORT=$NEW_PORT
        save_config
        msg_box "Port Changed" "Nimbus port changed: $OLD_PORT -> $NEW_PORT\n\nUpdate firewall:\n  sudo ufw delete allow $OLD_PORT/tcp\n  sudo ufw delete allow $OLD_PORT/udp\n  sudo ufw allow $NEW_PORT/tcp\n  sudo ufw allow $NEW_PORT/udp"
    fi
}

#------------------------------------------------------------------------------
# 2. SSH Security
#------------------------------------------------------------------------------

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

#------------------------------------------------------------------------------
# 3. LUKS Encrypted Storage
#------------------------------------------------------------------------------

luks_menu() {
    while true; do
        # Check LUKS status
        LUKS_STATUS="Not configured"
        if [ -b /dev/mapper/signer_crypt ]; then
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

    if [ -b /dev/mapper/signer_crypt ]; then
        STATUS+="Encrypted volume: UNLOCKED\n"
        STATUS+="Mount point: $(findmnt -n -o TARGET /dev/mapper/signer_crypt 2>/dev/null || echo 'Not mounted')\n"
        STATUS+="\nVolume info:\n$(cryptsetup status signer_crypt 2>/dev/null || echo 'N/A')"
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

#------------------------------------------------------------------------------
# 4. Initial Sync
#------------------------------------------------------------------------------

sync_menu() {
    while true; do
        load_config

        CHOICE=$(whiptail --title "Initial Sync" \
            --menu "Network: $NETWORK" \
            $TERM_HEIGHT $TERM_WIDTH $LIST_HEIGHT \
            "1" "Run Trusted Node Sync" \
            "2" "Select Server Manually" \
            "0" "Back to Main Menu" \
            3>&1 1>&2 2>&3)

        case $CHOICE in
            1)
                if yesno_box "Trusted Node Sync" "Run checkpoint sync for $NETWORK?\n\nThis will download a recent state snapshot."; then
                    clear
                    /opt/web3pi/trusted-node-sync.sh
                    read -p "Press Enter to continue..."
                fi
                ;;
            2) sync_select_server ;;
            0|"") return ;;
        esac
    done
}

sync_select_server() {
    load_config
    SERVERS_FILE="/opt/web3pi/servers_${NETWORK}.txt"

    if [ ! -f "$SERVERS_FILE" ]; then
        msg_box "Error" "Server list not found: $SERVERS_FILE"
        return
    fi

    # Build menu from servers
    MENU_ITEMS=()
    i=1
    while IFS= read -r server; do
        [ -z "$server" ] && continue
        MENU_ITEMS+=("$i" "$server")
        ((i++))
    done < "$SERVERS_FILE"

    CHOICE=$(whiptail --title "Select Checkpoint Server" \
        --menu "Choose server for $NETWORK:" $TERM_HEIGHT $TERM_WIDTH $LIST_HEIGHT \
        "${MENU_ITEMS[@]}" \
        3>&1 1>&2 2>&3)

    if [ -n "$CHOICE" ]; then
        SERVER=$(sed -n "${CHOICE}p" "$SERVERS_FILE")
        if yesno_box "Confirm" "Sync from:\n$SERVER"; then
            clear
            /opt/web3pi/trusted-node-sync.sh "$NETWORK" "$SERVER"
            read -p "Press Enter to continue..."
        fi
    fi
}

#------------------------------------------------------------------------------
# 5. Service Management
#------------------------------------------------------------------------------

service_menu() {
    while true; do
        # Get service statuses
        GETH_STATUS=$(systemctl is-active geth 2>/dev/null || echo "inactive")
        NIMBUS_BN_STATUS=$(systemctl is-active nimbus-beacon-node 2>/dev/null || echo "inactive")
        NIMBUS_VC_STATUS=$(systemctl is-active nimbus-validator 2>/dev/null || echo "inactive")

        CHOICE=$(whiptail --title "Service Management" \
            --menu "Geth: $GETH_STATUS | Beacon: $NIMBUS_BN_STATUS | Validator: $NIMBUS_VC_STATUS" \
            $TERM_HEIGHT $TERM_WIDTH $LIST_HEIGHT \
            "1" "Geth (Execution Layer)" \
            "2" "Nimbus Beacon Node (Consensus Layer)" \
            "3" "Nimbus Validator" \
            "4" "View Logs" \
            "5" "Start All Services" \
            "6" "Stop All Services" \
            "0" "Back to Main Menu" \
            3>&1 1>&2 2>&3)

        case $CHOICE in
            1) service_control "geth" "Geth" ;;
            2) service_control "nimbus-beacon-node" "Nimbus Beacon Node" ;;
            3) service_control "nimbus-validator" "Nimbus Validator" ;;
            4) service_logs ;;
            5)
                systemctl start geth nimbus-beacon-node
                msg_box "Services Started" "Geth and Nimbus Beacon Node started."
                ;;
            6)
                systemctl stop nimbus-validator nimbus-beacon-node geth 2>/dev/null
                msg_box "Services Stopped" "All services stopped."
                ;;
            0|"") return ;;
        esac
    done
}

service_control() {
    SERVICE=$1
    NAME=$2

    while true; do
        STATUS=$(systemctl is-active $SERVICE 2>/dev/null || echo "inactive")
        ENABLED=$(systemctl is-enabled $SERVICE 2>/dev/null || echo "disabled")

        CHOICE=$(whiptail --title "$NAME" \
            --menu "Status: $STATUS | Boot: $ENABLED" \
            $TERM_HEIGHT $TERM_WIDTH $LIST_HEIGHT \
            "1" "Start" \
            "2" "Stop" \
            "3" "Restart" \
            "4" "Enable (start on boot)" \
            "5" "Disable (don't start on boot)" \
            "6" "View Status" \
            "0" "Back" \
            3>&1 1>&2 2>&3)

        case $CHOICE in
            1) systemctl start $SERVICE && msg_box "Success" "$NAME started." ;;
            2) systemctl stop $SERVICE && msg_box "Success" "$NAME stopped." ;;
            3) systemctl restart $SERVICE && msg_box "Success" "$NAME restarted." ;;
            4) systemctl enable $SERVICE && msg_box "Success" "$NAME enabled." ;;
            5) systemctl disable $SERVICE && msg_box "Success" "$NAME disabled." ;;
            6)
                STATUS_OUT=$(systemctl status $SERVICE 2>&1 | head -20)
                whiptail --title "$NAME Status" --scrolltext --msgbox "$STATUS_OUT" $TERM_HEIGHT $TERM_WIDTH
                ;;
            0|"") return ;;
        esac
    done
}

service_logs() {
    CHOICE=$(whiptail --title "View Logs" \
        --menu "Select service:" $TERM_HEIGHT $TERM_WIDTH $LIST_HEIGHT \
        "1" "Geth" \
        "2" "Nimbus Beacon Node" \
        "3" "Nimbus Validator" \
        "0" "Back" \
        3>&1 1>&2 2>&3)

    case $CHOICE in
        1) clear; journalctl -u geth -n 100 --no-pager; read -p "Press Enter to continue..." ;;
        2) clear; journalctl -u nimbus-beacon-node -n 100 --no-pager; read -p "Press Enter to continue..." ;;
        3) clear; journalctl -u nimbus-validator -n 100 --no-pager; read -p "Press Enter to continue..." ;;
    esac
}

#------------------------------------------------------------------------------
# 6. Monitoring
#------------------------------------------------------------------------------

monitoring_menu() {
    while true; do
        CHOICE=$(whiptail --title "Monitoring" \
            --menu "Real-time system monitoring:" \
            $TERM_HEIGHT $TERM_WIDTH $LIST_HEIGHT \
            "1" "Sync Status (Geth & Nimbus)" \
            "2" "Peer Connections" \
            "3" "Resource Usage (RAM, CPU)" \
            "4" "Disk Usage" \
            "5" "System Overview" \
            "6" "Network Info (IP, Hostname)" \
            "0" "Back to Main Menu" \
            3>&1 1>&2 2>&3)

        case $CHOICE in
            1) monitoring_sync_status ;;
            2) monitoring_peers ;;
            3) monitoring_resources ;;
            4) monitoring_disk ;;
            5) monitoring_overview ;;
            6) monitoring_network ;;
            0|"") return ;;
        esac
    done
}

# Helper: Detect Nimbus backfill progress from journal logs
get_nimbus_backfill() {
    local LOG=$(journalctl -u nimbus-beacon-node -n 20 --no-pager 2>/dev/null | grep -o 'backfill: [^)]*%)' | tail -1)
    if [ -n "$LOG" ]; then
        echo "$LOG"
    fi
}

# Helper: Detect Geth indexing progress from journal logs
get_geth_indexing() {
    local LOG=$(journalctl -u geth -n 20 --no-pager 2>/dev/null | grep -i 'index.*progress\|indexing' | tail -1)
    if [ -n "$LOG" ]; then
        echo "indexing in progress"
    fi
}

monitoring_sync_status() {
    while true; do
        INFO=""

        # Geth sync status
        INFO+="GETH (Execution Layer)\n"
        INFO+="─────────────────────────────────────────────\n"
        if systemctl is-active --quiet geth; then
            GETH_SYNC=$(curl -sS --max-time 3 -H "Content-Type: application/json" \
                --data '{"jsonrpc":"2.0","method":"eth_syncing","params":[],"id":1}' \
                http://127.0.0.1:8545 2>/dev/null)

            if [ -n "$GETH_SYNC" ]; then
                RESULT=$(echo "$GETH_SYNC" | jq -r '.result')

                if [ "$RESULT" = "false" ]; then
                    BLOCK_RESP=$(curl -sS --max-time 3 -H "Content-Type: application/json" \
                        --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
                        http://127.0.0.1:8545 2>/dev/null)
                    BLOCK_HEX=$(echo "$BLOCK_RESP" | jq -r '.result // "0x0"' | sed 's/0x//')
                    BLOCK=$((16#${BLOCK_HEX:-0}))
                    INDEXING=$(get_geth_indexing)
                    if [ -n "$INDEXING" ]; then
                        INFO+="  Status: HEAD SYNCED (indexing...)\n"
                    else
                        INFO+="  Status: SYNCED\n"
                    fi
                    INFO+="  Block:  $BLOCK\n"
                else
                    CURRENT_HEX=$(echo "$GETH_SYNC" | jq -r '.result.currentBlock // "0x0"' | sed 's/0x//')
                    HIGHEST_HEX=$(echo "$GETH_SYNC" | jq -r '.result.highestBlock // "0x0"' | sed 's/0x//')
                    CURRENT=$((16#${CURRENT_HEX:-0}))
                    HIGHEST=$((16#${HIGHEST_HEX:-0}))
                    INFO+="  Status: SYNCING\n"
                    INFO+="  Current Block: $CURRENT\n"
                    INFO+="  Highest Block: $HIGHEST\n"
                fi
            else
                INFO+="  Status: API not responding\n"
            fi
        else
            INFO+="  Status: NOT RUNNING\n"
        fi

        INFO+="\nNIMBUS (Consensus Layer)\n"
        INFO+="─────────────────────────────────────────────\n"
        if systemctl is-active --quiet nimbus-beacon-node; then
            NIMBUS_DATA=$(curl -s http://127.0.0.1:5052/eth/v1/node/syncing 2>/dev/null)
            if [ -n "$NIMBUS_DATA" ]; then
                IS_SYNCING=$(echo "$NIMBUS_DATA" | jq -r '.data.is_syncing // "unknown"')
                HEAD_SLOT=$(echo "$NIMBUS_DATA" | jq -r '.data.head_slot // "0"')
                SYNC_DIST=$(echo "$NIMBUS_DATA" | jq -r '.data.sync_distance // "0"')
                IS_OPTIMISTIC=$(echo "$NIMBUS_DATA" | jq -r '.data.is_optimistic // "unknown"')

                if [ "$SYNC_DIST" = "0" ] || [ "$SYNC_DIST" -le 2 ] 2>/dev/null; then
                    BACKFILL=$(get_nimbus_backfill)
                    if [ -n "$BACKFILL" ]; then
                        INFO+="  Status: HEAD SYNCED\n"
                        INFO+="  Head Slot: $HEAD_SLOT\n"
                        INFO+="  Backfill: $BACKFILL\n"
                    else
                        INFO+="  Status: SYNCED\n"
                        INFO+="  Head Slot: $HEAD_SLOT\n"
                    fi
                elif [ "$IS_SYNCING" = "false" ]; then
                    INFO+="  Status: SYNCED\n"
                    INFO+="  Head Slot: $HEAD_SLOT\n"
                else
                    INFO+="  Status: SYNCING\n"
                    INFO+="  Head Slot: $HEAD_SLOT\n"
                    INFO+="  Sync Distance: $SYNC_DIST slots\n"
                    if [ "$IS_OPTIMISTIC" = "true" ]; then
                        INFO+="  Note: Waiting for EL sync\n"
                    fi
                fi
            else
                INFO+="  Status: API not responding\n"
            fi
        else
            INFO+="  Status: NOT RUNNING\n"
        fi

        # Use dialog --msgbox with timeout for auto-refresh
        if command -v dialog &>/dev/null; then
            dialog --title "Sync Status (auto-refresh 5s)" \
                   --ok-label "Back" \
                   --timeout 5 \
                   --msgbox "$(echo -e "$INFO")" \
                   20 50
            EXIT_CODE=$?
            # Back pressed (0) = exit to menu
            if [ $EXIT_CODE -eq 0 ]; then
                clear
                break
            fi
            # timeout or ESC (255) = continue loop (auto-refresh)
        else
            # Fallback to whiptail msgbox if dialog not available
            whiptail --title "Sync Status" --msgbox "$(echo -e "$INFO")" 20 $TERM_WIDTH
            break
        fi
    done
}

monitoring_peers() {
    INFO="═══════════════════════════════════════════════════════════\n"
    INFO+="                    PEER CONNECTIONS\n"
    INFO+="═══════════════════════════════════════════════════════════\n\n"

    # Geth peers (using JSON-RPC API)
    INFO+="▶ GETH PEERS\n"
    INFO+="─────────────────────────────────────────────────────────\n"
    if systemctl is-active --quiet geth; then
        PEER_RESP=$(curl -sS --max-time 3 -H "Content-Type: application/json" \
            --data '{"jsonrpc":"2.0","method":"net_peerCount","params":[],"id":1}' \
            http://127.0.0.1:8545 2>/dev/null)
        PEER_HEX=$(echo "$PEER_RESP" | jq -r '.result // "0x0"' | sed 's/0x//')
        GETH_PEERS=$((16#${PEER_HEX:-0}))
        INFO+="  Connected: $GETH_PEERS peers\n"
    else
        INFO+="  Geth not running\n"
    fi

    # Nimbus peers
    INFO+="\n▶ NIMBUS PEERS\n"
    INFO+="─────────────────────────────────────────────────────────\n"
    if systemctl is-active --quiet nimbus-beacon-node; then
        NIMBUS_PEERS=$(curl -s http://127.0.0.1:5052/eth/v1/node/peer_count 2>/dev/null | jq -r '.data.connected // "N/A"')
        INFO+="  Connected: $NIMBUS_PEERS peers\n"
    else
        INFO+="  Nimbus not running\n"
    fi

    msg_box "Peer Connections" "$INFO"
}

monitoring_resources() {
    INFO="═══════════════════════════════════════════════════════════\n"
    INFO+="                    RESOURCE USAGE\n"
    INFO+="═══════════════════════════════════════════════════════════\n\n"

    # Overall memory (in MB)
    INFO+="▶ SYSTEM MEMORY\n"
    INFO+="─────────────────────────────────────────────────────────\n"
    MEM_INFO=$(free -m | grep Mem)
    MEM_TOTAL=$(echo "$MEM_INFO" | awk '{print $2}')
    MEM_USED=$(echo "$MEM_INFO" | awk '{print $3}')
    MEM_PCT=$(free | grep Mem | awk '{printf "%.1f", $3/$2 * 100}')
    INFO+="  Total: ${MEM_TOTAL} MB | Used: ${MEM_USED} MB ($MEM_PCT%)\n"

    # Process memory
    INFO+="\n▶ PROCESS MEMORY (RSS)\n"
    INFO+="─────────────────────────────────────────────────────────\n"

    # Geth
    GETH_MEM=$(ps -o rss= -C geth 2>/dev/null | awk '{sum+=$1} END {printf "%.0f", sum/1024}')
    [ -z "$GETH_MEM" ] && GETH_MEM="0"
    INFO+="  Geth:            ${GETH_MEM} MB\n"

    # Nimbus beacon
    NIMBUS_BN_MEM=$(ps -o rss= -C nimbus_beacon_node 2>/dev/null | awk '{sum+=$1} END {printf "%.0f", sum/1024}')
    [ -z "$NIMBUS_BN_MEM" ] && NIMBUS_BN_MEM="0"
    INFO+="  Nimbus Beacon:   ${NIMBUS_BN_MEM} MB\n"

    # Nimbus validator
    NIMBUS_VC_MEM=$(ps -o rss= -C nimbus_validator 2>/dev/null | awk '{sum+=$1} END {printf "%.0f", sum/1024}')
    [ -z "$NIMBUS_VC_MEM" ] && NIMBUS_VC_MEM="0"
    INFO+="  Nimbus Validator: ${NIMBUS_VC_MEM} MB\n"

    # CPU Load
    INFO+="\n▶ CPU LOAD\n"
    INFO+="─────────────────────────────────────────────────────────\n"
    LOAD=$(cat /proc/loadavg | cut -d' ' -f1-3)
    CPU_CORES=$(nproc)
    INFO+="  Load Average: $LOAD\n"
    INFO+="  CPU Cores: $CPU_CORES\n"

    # Temperatures
    INFO+="\n▶ TEMPERATURES\n"
    INFO+="─────────────────────────────────────────────────────────\n"
    CPU_TEMP=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null | awk '{printf "%.1f", $1/1000}')
    [ -z "$CPU_TEMP" ] && CPU_TEMP="N/A"
    INFO+="  CPU: ${CPU_TEMP}°C\n"

    # GPU temp (RPi specific)
    GPU_TEMP=$(vcgencmd measure_temp 2>/dev/null | grep -oP '[0-9.]+' || echo "")
    if [ -n "$GPU_TEMP" ]; then
        INFO+="  GPU: ${GPU_TEMP}°C\n"
    fi

    # NVMe temp
    NVME_TEMP=$(cat /sys/class/nvme/nvme0/hwmon*/temp1_input 2>/dev/null | awk '{printf "%.1f", $1/1000}')
    if [ -n "$NVME_TEMP" ]; then
        INFO+="  NVMe: ${NVME_TEMP}°C\n"
    fi

    whiptail --title "Resource Usage" --scrolltext --msgbox "$INFO" 24 $TERM_WIDTH
}

monitoring_disk() {
    INFO="═══════════════════════════════════════════════════════════\n"
    INFO+="                    DISK USAGE\n"
    INFO+="═══════════════════════════════════════════════════════════\n\n"

    # Overall disk
    INFO+="▶ FILESYSTEM\n"
    INFO+="─────────────────────────────────────────────────────────\n"
    DISK_INFO=$(df -h / | tail -1)
    DISK_SIZE=$(echo "$DISK_INFO" | awk '{print $2}')
    DISK_USED=$(echo "$DISK_INFO" | awk '{print $3}')
    DISK_FREE=$(echo "$DISK_INFO" | awk '{print $4}')
    DISK_PCT=$(echo "$DISK_INFO" | awk '{print $5}')
    INFO+="  Total: $DISK_SIZE | Used: $DISK_USED | Free: $DISK_FREE\n"
    INFO+="  Usage: $DISK_PCT\n"

    # Per-directory usage
    INFO+="\n▶ ETHEREUM DATA\n"
    INFO+="─────────────────────────────────────────────────────────\n"

    GETH_SIZE=$(du -sh /var/lib/el 2>/dev/null | cut -f1 || echo "N/A")
    INFO+="  Geth (/var/lib/el):        $GETH_SIZE\n"

    NIMBUS_SIZE=$(du -sh /var/lib/cl 2>/dev/null | cut -f1 || echo "N/A")
    INFO+="  Nimbus (/var/lib/cl):      $NIMBUS_SIZE\n"

    SIGNER_SIZE=$(du -sh /home/signer 2>/dev/null | cut -f1 || echo "N/A")
    INFO+="  Signer (/home/signer):     $SIGNER_SIZE\n"

    # Per-user usage
    INFO+="\n▶ USER HOME DIRECTORIES\n"
    INFO+="─────────────────────────────────────────────────────────\n"

    ETH_HOME=$(du -sh /home/ethereum 2>/dev/null | cut -f1 || echo "N/A")
    INFO+="  ethereum: $ETH_HOME\n"

    EL_HOME=$(du -sh /var/lib/el 2>/dev/null | cut -f1 || echo "N/A")
    INFO+="  el:       $EL_HOME\n"

    CL_HOME=$(du -sh /var/lib/cl 2>/dev/null | cut -f1 || echo "N/A")
    INFO+="  cl:       $CL_HOME\n"

    whiptail --title "Disk Usage" --scrolltext --msgbox "$INFO" 24 $TERM_WIDTH
}

monitoring_overview() {
    INFO="═══════════════════════════════════════════════════════════\n"
    INFO+="                    SYSTEM OVERVIEW\n"
    INFO+="═══════════════════════════════════════════════════════════\n\n"

    # Services
    GETH_ST=$(systemctl is-active geth 2>/dev/null || echo "inactive")
    NIMBUS_BN_ST=$(systemctl is-active nimbus-beacon-node 2>/dev/null || echo "inactive")
    NIMBUS_VC_ST=$(systemctl is-active nimbus-validator 2>/dev/null || echo "inactive")

    INFO+="▶ SERVICES\n"
    INFO+="─────────────────────────────────────────────────────────\n"
    [ "$GETH_ST" = "active" ] && G="✓" || G="✗"
    [ "$NIMBUS_BN_ST" = "active" ] && N="✓" || N="✗"
    [ "$NIMBUS_VC_ST" = "active" ] && V="✓" || V="✗"
    INFO+="  [$G] Geth    [$N] Nimbus Beacon    [$V] Validator\n"

    # Quick stats
    INFO+="\n▶ QUICK STATS\n"
    INFO+="─────────────────────────────────────────────────────────\n"

    # Uptime
    UPTIME=$(uptime -p | sed 's/up //')
    INFO+="  Uptime: $UPTIME\n"

    # Load
    LOAD=$(cat /proc/loadavg | cut -d' ' -f1)
    INFO+="  Load: $LOAD\n"

    # Memory
    MEM_PCT=$(free | grep Mem | awk '{printf "%.0f", $3/$2 * 100}')
    INFO+="  Memory: ${MEM_PCT}%\n"

    # Disk
    DISK_PCT=$(df / | tail -1 | awk '{print $5}')
    INFO+="  Disk: $DISK_PCT\n"

    # CPU temp
    CPU_TEMP=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null | awk '{printf "%.0f", $1/1000}')
    INFO+="  CPU Temp: ${CPU_TEMP}°C\n"

    # Peers (if running)
    if [ "$GETH_ST" = "active" ]; then
        PEER_RESP=$(curl -sS --max-time 3 -H "Content-Type: application/json" \
            --data '{"jsonrpc":"2.0","method":"net_peerCount","params":[],"id":1}' \
            http://127.0.0.1:8545 2>/dev/null)
        PEER_HEX=$(echo "$PEER_RESP" | jq -r '.result // "0x0"' | sed 's/0x//')
        GETH_PEERS=$((16#${PEER_HEX:-0}))
        INFO+="  Geth Peers: $GETH_PEERS\n"
    fi
    if [ "$NIMBUS_BN_ST" = "active" ]; then
        NIMBUS_PEERS=$(curl -s http://127.0.0.1:5052/eth/v1/node/peer_count 2>/dev/null | jq -r '.data.connected // "?"')
        INFO+="  Nimbus Peers: $NIMBUS_PEERS\n"
    fi

    msg_box "System Overview" "$INFO"
}

monitoring_network() {
    INFO="═══════════════════════════════════════════════════════════\n"
    INFO+="                    NETWORK INFO\n"
    INFO+="═══════════════════════════════════════════════════════════\n\n"

    INFO+="▶ HOSTNAME\n"
    INFO+="─────────────────────────────────────────────────────────\n"
    INFO+="  $(hostname)\n"

    INFO+="\n▶ IP ADDRESSES\n"
    INFO+="─────────────────────────────────────────────────────────\n"
    # Get all IPs
    while read -r line; do
        INFO+="  $line\n"
    done < <(hostname -I | tr ' ' '\n' | grep -v '^$')

    msg_box "Network Info" "$INFO"
}

#------------------------------------------------------------------------------
# 7. Data Management
#------------------------------------------------------------------------------

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

#------------------------------------------------------------------------------
# 7. System
#------------------------------------------------------------------------------

system_menu() {
    while true; do
        CHOICE=$(whiptail --title "System" \
            --menu "System management options:" \
            $TERM_HEIGHT $TERM_WIDTH $LIST_HEIGHT \
            "1" "Change ethereum Password" \
            "2" "System Information" \
            "3" "Reboot System" \
            "4" "Shutdown System" \
            "0" "Back to Main Menu" \
            3>&1 1>&2 2>&3)

        case $CHOICE in
            1) system_change_password ;;
            2) system_info ;;
            3)
                if yesno_box "Reboot" "Reboot the system now?"; then
                    reboot
                fi
                ;;
            4)
                if yesno_box "Shutdown" "Shutdown the system now?"; then
                    poweroff
                fi
                ;;
            0|"") return ;;
        esac
    done
}

system_change_password() {
    if yesno_box "Change Password" "Change password for user 'ethereum'?"; then
        clear
        passwd ethereum
        read -p "Press Enter to continue..."
    fi
}

system_info() {
    INFO="═══════════════════════════════════════════════════════════\n"
    INFO+="                    SYSTEM INFORMATION\n"
    INFO+="═══════════════════════════════════════════════════════════\n\n"

    # Hardware info
    INFO+="▶ HARDWARE\n"
    INFO+="─────────────────────────────────────────────────────────\n"

    # RPi model
    RPI_MODEL=$(cat /proc/device-tree/model 2>/dev/null | tr -d '\0' || echo "Unknown")
    INFO+="  Model: $RPI_MODEL\n"

    # Serial number
    SERIAL=$(cat /proc/cpuinfo 2>/dev/null | grep Serial | awk '{print $3}' || echo "N/A")
    INFO+="  Serial: $SERIAL\n"

    # CPU info
    CPU_MODEL=$(lscpu 2>/dev/null | grep "Model name" | cut -d: -f2 | xargs || echo "N/A")
    CPU_CORES=$(nproc)
    CPU_FREQ=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null | awk '{printf "%.0f MHz", $1/1000}' || echo "N/A")
    INFO+="  CPU: $CPU_MODEL\n"
    INFO+="  Cores: $CPU_CORES @ $CPU_FREQ\n"

    # RAM (in MB)
    RAM_TOTAL=$(free -m | grep Mem | awk '{print $2}')
    INFO+="  RAM: ${RAM_TOTAL} MB\n"

    # Operating System
    INFO+="\n▶ OPERATING SYSTEM\n"
    INFO+="─────────────────────────────────────────────────────────\n"

    # OS info
    if [ -f /etc/os-release ]; then
        OS_NAME=$(grep "PRETTY_NAME" /etc/os-release | cut -d'"' -f2)
    else
        OS_NAME=$(uname -o)
    fi
    INFO+="  OS: $OS_NAME\n"

    # Kernel
    KERNEL=$(uname -r)
    INFO+="  Kernel: $KERNEL\n"

    # Architecture
    ARCH=$(uname -m)
    INFO+="  Architecture: $ARCH\n"

    # Hostname
    INFO+="  Hostname: $(hostname)\n"

    # Uptime
    UPTIME=$(uptime -p)
    INFO+="  Uptime: $UPTIME\n"

    # Firmware
    INFO+="\n▶ FIRMWARE\n"
    INFO+="─────────────────────────────────────────────────────────\n"

    # EEPROM version
    if command -v rpi-eeprom-update &>/dev/null; then
        EEPROM_VER=$(rpi-eeprom-update 2>/dev/null | grep "CURRENT" | sed 's/.*CURRENT: //' || echo "N/A")
        INFO+="  EEPROM: $EEPROM_VER\n"
    fi

    # Bootloader
    if [ -f /boot/firmware/config.txt ]; then
        INFO+="  Boot: UEFI/NVMe\n"
    else
        INFO+="  Boot: Legacy\n"
    fi

    # Network
    INFO+="\n▶ NETWORK\n"
    INFO+="─────────────────────────────────────────────────────────\n"
    IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "N/A")
    MAC=$(cat /sys/class/net/eth0/address 2>/dev/null || cat /sys/class/net/end0/address 2>/dev/null || echo "N/A")
    INFO+="  IP: $IP\n"
    INFO+="  MAC: $MAC\n"

    # Current status
    INFO+="\n▶ CURRENT STATUS\n"
    INFO+="─────────────────────────────────────────────────────────\n"

    # Load
    LOAD=$(cat /proc/loadavg | cut -d' ' -f1-3)
    INFO+="  Load: $LOAD\n"

    # Memory usage
    MEM_PCT=$(free | grep Mem | awk '{printf "%.1f%%", $3/$2 * 100}')
    INFO+="  Memory: $MEM_PCT used\n"

    # Disk usage
    DISK_PCT=$(df / | tail -1 | awk '{print $5}')
    INFO+="  Disk: $DISK_PCT used\n"

    # Temperatures
    CPU_TEMP=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null | awk '{printf "%.1f", $1/1000}')
    INFO+="  CPU Temp: ${CPU_TEMP}°C\n"

    # GPU temp (RPi specific)
    GPU_TEMP=$(vcgencmd measure_temp 2>/dev/null | grep -oP '[0-9.]+' || echo "N/A")
    if [ "$GPU_TEMP" != "N/A" ]; then
        INFO+="  GPU Temp: ${GPU_TEMP}°C\n"
    fi

    # NVMe temp
    NVME_TEMP=$(cat /sys/class/nvme/nvme0/hwmon*/temp1_input 2>/dev/null | awk '{printf "%.1f", $1/1000}')
    if [ -n "$NVME_TEMP" ]; then
        INFO+="  NVMe Temp: ${NVME_TEMP}°C\n"
    fi

    # Throttling status
    THROTTLE=$(vcgencmd get_throttled 2>/dev/null | cut -d= -f2 || echo "N/A")
    if [ "$THROTTLE" = "0x0" ]; then
        INFO+="  Throttling: None ✓\n"
    elif [ "$THROTTLE" != "N/A" ]; then
        INFO+="  Throttling: Active! ($THROTTLE)\n"
    fi

    whiptail --title "System Information" --scrolltext --msgbox "$INFO" 30 $TERM_WIDTH
}

#------------------------------------------------------------------------------
# Main
#------------------------------------------------------------------------------

check_root
main_menu
