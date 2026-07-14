#!/bin/bash
#
# Web3 Pi Control Panel - Initial Sync Module
#

sync_menu() {
    while true; do
        load_config

        CHOICE=$(whiptail --title "Initial Sync" \
            --menu "Network: $W3P_NETWORK" \
            $TERM_HEIGHT $TERM_WIDTH $LIST_HEIGHT \
            "1" "Run Trusted Node Sync" \
            "2" "Select Server Manually" \
            "0" "Back to Main Menu" \
            3>&1 1>&2 2>&3)

        case $CHOICE in
            1)
                if yesno_box "Trusted Node Sync" "Run checkpoint sync for $W3P_NETWORK?\n\nThis will download a recent state snapshot."; then
                    clear
                    # Pass the network explicitly (same as sync_select_server):
                    # the panel's W3P_NETWORK is not exported, so the child
                    # script would otherwise re-derive it from the config file
                    # alone — it must sync the network this dialog displayed.
                    /opt/web3pi/trusted-node-sync.sh "$W3P_NETWORK"
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
    SERVERS_FILE="/opt/web3pi/servers_${W3P_NETWORK}.txt"

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
        --menu "Choose server for $W3P_NETWORK:" $TERM_HEIGHT $TERM_WIDTH $LIST_HEIGHT \
        "${MENU_ITEMS[@]}" \
        3>&1 1>&2 2>&3)

    if [ -n "$CHOICE" ]; then
        SERVER=$(sed -n "${CHOICE}p" "$SERVERS_FILE")
        if yesno_box "Confirm" "Sync from:\n$SERVER"; then
            clear
            /opt/web3pi/trusted-node-sync.sh "$W3P_NETWORK" "$SERVER"
            read -p "Press Enter to continue..."
        fi
    fi
}
