#!/bin/bash
#
# Web3 Pi Control Panel - Network Configuration Module
#

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
        msg_box "Port Changed" "Geth port changed: $OLD_PORT -> $NEW_PORT\n\nUpdate /etc/nftables.conf:\n  Change 'dport $OLD_PORT' to 'dport $NEW_PORT'\n  Then: sudo systemctl restart nftables"
    fi
}

network_nimbus_port() {
    load_config
    NEW_PORT=$(input_box "Nimbus P2P Port" "Enter Nimbus P2P port (current: $NIMBUS_PORT):" "$NIMBUS_PORT")

    if [ -n "$NEW_PORT" ] && [ "$NEW_PORT" != "$NIMBUS_PORT" ]; then
        OLD_PORT=$NIMBUS_PORT
        NIMBUS_PORT=$NEW_PORT
        save_config
        msg_box "Port Changed" "Nimbus port changed: $OLD_PORT -> $NEW_PORT\n\nUpdate /etc/nftables.conf:\n  Change 'dport $OLD_PORT' to 'dport $NEW_PORT'\n  Then: sudo systemctl restart nftables"
    fi
}
