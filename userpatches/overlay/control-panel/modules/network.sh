#!/bin/bash
#
# Web3 Pi Control Panel - Network Configuration Module
#

network_menu() {
    while true; do
        load_config
        CHOICE=$(whiptail --title "Network Configuration" \
            --menu "Current: W3P_NETWORK=$W3P_NETWORK, W3P_GETH_PORT=$W3P_GETH_PORT, W3P_NIMBUS_PORT=$W3P_NIMBUS_PORT" \
            $TERM_HEIGHT $TERM_WIDTH $LIST_HEIGHT \
            "1" "Select Network" \
            "2" "Configure Geth P2P Port" \
            "3" "Configure Nimbus P2P Port" \
            "4" "Geth Chain History (disk usage)" \
            "5" "View Current Config" \
            "0" "Back to Main Menu" \
            3>&1 1>&2 2>&3)

        case $CHOICE in
            1) network_select ;;
            2) network_geth_port ;;
            3) network_nimbus_port ;;
            4) network_geth_history ;;
            5) msg_box "Current Configuration" "$(cat $CONFIG_FILE)" ;;
            0|"") return ;;
        esac
    done
}

# Geth chain-history retention. Controls how much pre-Merge/pre-Prague history
# Geth keeps on disk (validator duties are unaffected). Stored in the config as
# the full W3P_GETH_HISTORY_FLAG fragment, or empty to omit the flag entirely.
network_geth_history() {
    load_config

    # Derive the current selection token from the stored flag. Colon-less default
    # matches save_config: an explicit empty value means "off", only a truly-unset
    # variable falls back to postprague.
    local current_flag="${W3P_GETH_HISTORY_FLAG-"--history.chain=postprague"}"
    local current_token
    if [ -z "$current_flag" ]; then
        current_token="off"
    else
        current_token="${current_flag##*=}"
    fi

    local CHOICE
    CHOICE=$(whiptail --title "Geth Chain History" \
        --radiolist "Less history = less disk. Validator is unaffected.\nCurrent: $current_token" \
        $TERM_HEIGHT $TERM_WIDTH 5 \
        "postprague" "Prune pre-Prague (~1TB less, recommended)" $([ "$current_token" = "postprague" ] && echo "ON" || echo "OFF") \
        "postmerge"  "Prune pre-Merge (keeps more history)"      $([ "$current_token" = "postmerge" ] && echo "ON" || echo "OFF") \
        "all"        "Keep full history (Geth default, most disk)" $([ "$current_token" = "all" ] && echo "ON" || echo "OFF") \
        "off"        "Do not set the flag (Geth default = all)"   $([ "$current_token" = "off" ] && echo "ON" || echo "OFF") \
        3>&1 1>&2 2>&3)

    # Cancelled (Esc / empty selection)
    [ -z "$CHOICE" ] && return

    # Map the chosen token back to the stored flag fragment.
    local new_flag
    if [ "$CHOICE" = "off" ]; then
        new_flag=""
    else
        new_flag="--history.chain=$CHOICE"
    fi

    # No change -> nothing to do.
    if [ "$new_flag" = "$current_flag" ]; then
        return
    fi

    W3P_GETH_HISTORY_FLAG="$new_flag"
    save_config

    local applied
    if [ "$CHOICE" = "off" ]; then
        applied="flag removed (Geth uses its default: keep all history)"
    else
        applied="$new_flag"
    fi

    if yesno_box "Geth History Changed" "Geth chain history set to: $CHOICE\n$applied\n\nApplies on the next Geth start. On an already-synced node this does NOT resize the DB by itself:\n- to a LESS-pruned mode: missing history is not back-filled (resync to populate)\n- to a MORE-pruned mode: existing data is not deleted (run 'geth prune-history' offline to reclaim disk)\n\nA freshly-synced node simply uses the chosen mode.\n\nRestart Geth now to apply?"; then
        if systemctl restart geth 2>/dev/null; then
            msg_box "Geth Restarted" "Geth restarted with the new history setting."
        else
            msg_box "Restart Failed" "Could not restart Geth.\n\nCheck: systemctl status geth"
        fi
    fi
}

network_select() {
    load_config
    local OLD_NETWORK="$W3P_NETWORK"
    # Capture into a local and only assign W3P_NETWORK on a real choice:
    # a cancelled dialog returns "", and assigning that would leave
    # W3P_NETWORK set-but-empty — save_config would then default it to
    # hoodi, silently switching the configured network.
    local NEW_NETWORK
    NEW_NETWORK=$(whiptail --title "Select Network" \
        --radiolist "Choose Ethereum network:" $TERM_HEIGHT $TERM_WIDTH 4 \
        "hoodi" "Testnet (recommended for testing)" $([ "$W3P_NETWORK" = "hoodi" ] && echo "ON" || echo "OFF") \
        "holesky" "Testnet (alternative)" $([ "$W3P_NETWORK" = "holesky" ] && echo "ON" || echo "OFF") \
        "mainnet" "Production (real ETH!)" $([ "$W3P_NETWORK" = "mainnet" ] && echo "ON" || echo "OFF") \
        3>&1 1>&2 2>&3)

    if [ -n "$NEW_NETWORK" ]; then
        W3P_NETWORK="$NEW_NETWORK"
        # MEV relays are network-specific: on a network change replace the list
        # with the new network's defaults (mevboost.sh). A network with no
        # relays (holesky, shut down 2025) force-disables MEV Boost.
        # Only variables are mutated here; systemd actions run AFTER save_config,
        # because a restart re-reads EnvironmentFile from disk (a restart before
        # the save would relaunch mev-boost with the OLD network/relays).
        local MEV_NOTE="" MEV_RESTART=false
        if [ "$W3P_NETWORK" != "$OLD_NETWORK" ] && { [ "${W3P_MEV_BOOST_ENABLED:-false}" = "true" ] || [ -n "$W3P_MEV_RELAYS" ]; }; then
            W3P_MEV_RELAYS="$(mevboost_default_relays "$W3P_NETWORK")"
            if [ -z "$W3P_MEV_RELAYS" ] && [ "${W3P_MEV_BOOST_ENABLED:-false}" = "true" ]; then
                W3P_MEV_BOOST_ENABLED=false
                systemctl disable --now mev-boost 2>/dev/null
                MEV_NOTE="\n\nMEV Boost: DISABLED (no relays operate on $W3P_NETWORK)"
            elif [ -n "$W3P_MEV_RELAYS" ]; then
                MEV_NOTE="\n\nMEV relays reset to $W3P_NETWORK defaults."
                [ "${W3P_MEV_BOOST_ENABLED:-false}" = "true" ] && MEV_RESTART=true
            fi
        fi
        save_config
        [ "$MEV_RESTART" = "true" ] && systemctl try-restart mev-boost 2>/dev/null
        msg_box "Network Changed" "Network set to: $W3P_NETWORK\n\nRemember to:\n1. Run trusted node sync\n2. Restart services$MEV_NOTE"
    fi
}

network_geth_port() {
    load_config
    NEW_PORT=$(input_box "Geth P2P Port" "Enter Geth P2P port (current: $W3P_GETH_PORT):" "$W3P_GETH_PORT")

    if [ -n "$NEW_PORT" ] && [ "$NEW_PORT" != "$W3P_GETH_PORT" ]; then
        OLD_PORT=$W3P_GETH_PORT
        W3P_GETH_PORT=$NEW_PORT
        save_config
        msg_box "Port Changed" "Geth port changed: $OLD_PORT -> $NEW_PORT\n\nUpdate /etc/nftables.conf:\n  Change 'dport $OLD_PORT' to 'dport $NEW_PORT'\n  Then: sudo systemctl restart nftables"
    fi
}

network_nimbus_port() {
    load_config
    NEW_PORT=$(input_box "Nimbus P2P Port" "Enter Nimbus P2P port (current: $W3P_NIMBUS_PORT):" "$W3P_NIMBUS_PORT")

    if [ -n "$NEW_PORT" ] && [ "$NEW_PORT" != "$W3P_NIMBUS_PORT" ]; then
        OLD_PORT=$W3P_NIMBUS_PORT
        W3P_NIMBUS_PORT=$NEW_PORT
        save_config
        msg_box "Port Changed" "Nimbus port changed: $OLD_PORT -> $NEW_PORT\n\nUpdate /etc/nftables.conf:\n  Change 'dport $OLD_PORT' to 'dport $NEW_PORT'\n  Then: sudo systemctl restart nftables"
    fi
}
