#!/bin/bash
#
# Web3 Pi Control Panel - MEV-Boost Module
#

MEV_BOOST_BIN="/usr/local/bin/mev-boost"
MEV_BOOST_LISTEN="127.0.0.1:18550"

# Relay catalog per network: "Name|URL|DefaultOn".
# URLs verified live 2026-07-12 (/eth/v1/builder/status -> HTTP 200); pubkeys
# cross-checked against the ethstaker MEV-relay-list and operator homepages.
# "filters OFAC" = relay censors sanctioned transactions; "non-filtering" = no
# transaction filtering. The default set mixes both — adjust to taste.
MEV_RELAY_CATALOG_MAINNET=(
    "Flashbots (filters OFAC)|https://0xac6e77dfe25ecd6110b8e780608cce0dab71fdd5ebea22a16c0205200f2f8e2e3ad3b71d3499c54ad14d6c21b41a37ae@boost-relay.flashbots.net|ON"
    "ultra sound (non-filtering)|https://0xa1559ace749633b997cb3fdacffb890aeebdb0f5a3b6aaa7eeeaf1a38af0a8fe88b9e4b1f61f236d2e64d95733327a62@relay.ultrasound.money|ON"
    "Aestus (non-filtering)|https://0xa15b52576bcbf1072f4a011c0f99f9fb6c66f3e1ff321f11f461d15e31b1cb359caa092c71bbded0bae5b5ea401aab7e@aestus.live|ON"
    "Titan Global (non-filtering)|https://0x8c4ed5e24fe5c6ae21018437bde147693f68cda427cd1122cf20819c30eda7ed74f72dece09bb313f2a1855595ab677d@global.titanrelay.xyz|ON"
    "Titan Regional (filters OFAC)|https://0x8c4ed5e24fe5c6ae21018437bde147693f68cda427cd1122cf20819c30eda7ed74f72dece09bb313f2a1855595ab677d@regional.titanrelay.xyz|OFF"
    "bloXroute Max Profit (non-filtering)|https://0x8b5d2e73e2a3a55c6c87b8b6eb92e0149a125c852751db1422fa951e42a09b82c142c3ea98d0d9930b056a3bc9896b8f@bloxroute.max-profit.blxrbdn.com|OFF"
    "bloXroute Regulated (filters OFAC)|https://0xb0b07cd0abef743db4260b0ed50619cf6ad4d82064cb4fbec9d3ec530f7c5e6793d9f286c4e082c0244ffb9f2658fe88@bloxroute.regulated.blxrbdn.com|OFF"
    "Agnostic Gnosis (non-filtering)|https://0xa7ab7a996c8584251c8f925da3170bdfd6ebc75d50f5ddc4050a6fdc77f2a3b5fce2cc750d0865e05d7228af97d69561@agnostic-relay.net|OFF"
    "Wenmerge (non-filtering)|https://0x8c7d33605ecef85403f8b7289c8058f440cbb6bf72b055dfe2f3e2c6695b6a1ea5a9cd0eb3a7982927a463feb4c3dae2@relay.wenmerge.com|OFF"
)
MEV_RELAY_CATALOG_HOODI=(
    "Flashbots|https://0xafa4c6985aa049fb79dd37010438cfebeb0f2bd42b115b89dd678dab0670c1de38da0c4e9138c9290a398ecd9a0b3110@boost-relay-hoodi.flashbots.net|ON"
    "Aestus|https://0x98f0ef62f00780cf8eb06701a7d22725b9437d4768bb19b363e882ae87129945ec206ec2dc16933f31d983f8225772b6@hoodi.aestus.live|ON"
    "Titan|https://0xaa58208899c6105603b74396734a6263cc7d947f444f396a90f7b7d3e65d102aec7e5e5291b27e08d02c50a050825c2f@hoodi.titanrelay.xyz|ON"
    "bloXroute|https://0x821f2a65afb70e7f2e820a925a9b4c80a159620582c1766b1b09729fec178b11ea22abb3a51f07b288be815a1a2ff516@bloxroute.hoodi.blxrbdn.com|ON"
)
# Holesky was shut down in September 2025 — no relays operate there (empty catalog).

# Print the catalog for a network, one "Name|URL|DefaultOn" entry per line.
mevboost_catalog() {
    case "$1" in
        mainnet) printf '%s\n' "${MEV_RELAY_CATALOG_MAINNET[@]}" ;;
        hoodi)   printf '%s\n' "${MEV_RELAY_CATALOG_HOODI[@]}" ;;
    esac
}

# Comma-joined URLs of the default-ON catalog entries for network $1.
# Used here and by network.sh when the network changes.
mevboost_default_relays() {
    local name url def out=""
    while IFS='|' read -r name url def; do
        [ "$def" = "ON" ] || continue
        out="${out:+$out,}$url"
    done < <(mevboost_catalog "$1")
    echo "$out"
}

mevboost_menu() {
    while true; do
        load_config
        # capture-then-default: is-active prints the state ("failed",
        # "activating"...) even when it exits nonzero, so `|| echo` would
        # garble the value into two lines
        SVC_STATUS=$(systemctl is-active mev-boost 2>/dev/null)
        SVC_STATUS=${SVC_STATUS:-inactive}
        MEV_ENABLED="${MEV_BOOST_ENABLED:-false}"
        RELAY_COUNT=0
        [ -n "$MEV_RELAYS" ] && RELAY_COUNT=$(echo "$MEV_RELAYS" | tr ',' '\n' | grep -c .)

        TOGGLE_LABEL="Enable MEV Boost"
        [ "$MEV_ENABLED" = "true" ] && TOGGLE_LABEL="Disable MEV Boost"

        CHOICE=$(whiptail --title "MEV Boost" \
            --menu "Enabled: $MEV_ENABLED | Service: $SVC_STATUS | Relays: $RELAY_COUNT | Net: $NETWORK" \
            $TERM_HEIGHT $TERM_WIDTH $LIST_HEIGHT \
            "1" "$TOGGLE_LABEL" \
            "2" "Select Relays" \
            "3" "Add Custom Relay" \
            "4" "Test Relays" \
            "5" "View Status" \
            "6" "View Logs" \
            "0" "Back" \
            3>&1 1>&2 2>&3)

        case $CHOICE in
            1) mevboost_toggle ;;
            2) mevboost_select_relays ;;
            3) mevboost_add_custom ;;
            4) mevboost_test_relays ;;
            5) mevboost_status ;;
            6) clear; journalctl -u mev-boost -n 100 --no-pager; read -p "Press Enter to continue..." ;;
            0|"") return ;;
        esac
    done
}

# Wait until mev-boost serves its builder API. mev-boost opens the listen
# socket only after -relay-check passes, and Type=simple units are "active"
# the instant the process forks — so is-active right after a start would race
# the in-flight relay probes and report false success. Polling the local
# endpoint proves both "process survived relay-check" and "API is serving".
mevboost_wait_ready() {
    local i
    for i in $(seq 1 15); do
        if curl -sf -o /dev/null --max-time 2 "http://${MEV_BOOST_LISTEN}/eth/v1/builder/status"; then
            return 0
        fi
        # fast-fail: don't burn the remaining budget on a unit already dead
        systemctl is-failed --quiet mev-boost && return 1
        sleep 1
    done
    return 1
}

# Restart the Nimbus processes so they pick up the new payload-builder flags.
# BN and VC each only if currently running (VC is LUKS-gated, may be down).
mevboost_restart_nimbus() {
    local restarted=""
    if systemctl is-active --quiet nimbus-beacon-node; then
        systemctl restart nimbus-beacon-node && restarted="beacon node"
    fi
    if systemctl is-active --quiet nimbus-validator; then
        systemctl restart nimbus-validator && restarted="${restarted:+$restarted + }validator"
    fi
    echo "${restarted:-none running}"
}

mevboost_toggle() {
    load_config

    if [ "${MEV_BOOST_ENABLED:-false}" = "true" ]; then
        if ! yesno_box "Disable MEV Boost" "Disable MEV Boost?\n\nThe mev-boost service will be stopped and Nimbus will\nreturn to local block production only (restart required)."; then
            return
        fi
        MEV_BOOST_ENABLED=false
        save_config
        systemctl disable --now mev-boost 2>/dev/null
        RESTARTED=$(mevboost_restart_nimbus)
        msg_box "MEV Boost Disabled" "mev-boost stopped and disabled.\n\nNimbus restarted without payload-builder flags: $RESTARTED"
        return
    fi

    # --- Enable path ---
    if [ ! -x "$MEV_BOOST_BIN" ]; then
        msg_box "Binary Missing" "mev-boost binary not found at:\n  $MEV_BOOST_BIN\n\nIt is normally pre-installed in the image. Reinstall:\n  https://github.com/flashbots/mev-boost/releases"
        return
    fi

    if [ -z "$(mevboost_catalog "$NETWORK")" ] && [ -z "$MEV_RELAYS" ]; then
        msg_box "No Relays on $NETWORK" "No MEV relays operate on network '$NETWORK'.\n\n(Holesky was shut down in September 2025 —\nuse hoodi for validator testing.)"
        return
    fi

    if [ -z "$MEV_RELAYS" ]; then
        mevboost_select_relays
        load_config
        if [ -z "$MEV_RELAYS" ]; then
            msg_box "No Relays Selected" "MEV Boost needs at least one relay.\n\nNot enabled."
            return
        fi
    fi

    MSG="Enable MEV Boost?\n\n"
    MSG+="This will:\n"
    MSG+="  1. Start mev-boost on $MEV_BOOST_LISTEN\n"
    MSG+="  2. Restart Nimbus (beacon node + validator if running)\n"
    MSG+="     with --payload-builder=true\n\n"
    MSG+="Your blocks will be built by external builders via relays.\n"
    MSG+="Nimbus falls back to local block production if the\n"
    MSG+="builder is unavailable or its bid is not competitive."
    if ! yesno_box "Enable MEV Boost" "$MSG"; then
        return
    fi

    MEV_BOOST_ENABLED=true
    save_config
    # enable + restart (not enable --now): an already-running unit would make
    # --now a no-op and keep serving a stale relay list; restart re-reads the
    # EnvironmentFile, and on an inactive unit it behaves like start.
    systemctl enable mev-boost 2>/dev/null
    systemctl restart mev-boost 2>/dev/null

    if ! mevboost_wait_ready; then
        # Roll back so the nimbus units are not left pointing at a dead builder.
        MEV_BOOST_ENABLED=false
        save_config
        systemctl disable --now mev-boost 2>/dev/null
        msg_box "Start Failed" "mev-boost failed to start — MEV Boost rolled back\nto disabled.\n\nCheck: journalctl -u mev-boost -n 50\n(-relay-check fails startup when no relay responds)"
        return
    fi

    RESTARTED=$(mevboost_restart_nimbus)
    RELAY_COUNT=$(echo "$MEV_RELAYS" | tr ',' '\n' | grep -c .)
    msg_box "MEV Boost Enabled" "mev-boost running on $MEV_BOOST_LISTEN\nRelays: $RELAY_COUNT\n\nNimbus restarted with payload-builder flags: $RESTARTED\n\nNote: if the validator was not running, it picks up the\nflags automatically on its next start."
}

# If MEV Boost is enabled and running, restart mev-boost to apply a relay change.
# Nimbus does NOT need a restart for relay-only changes (builder URL unchanged).
mevboost_apply_relay_change() {
    load_config
    [ "${MEV_BOOST_ENABLED:-false}" = "true" ] || return 0
    if ! systemctl restart mev-boost 2>/dev/null; then
        msg_box "Restart Failed" "Could not restart mev-boost.\n\nCheck: journalctl -u mev-boost -n 50"
        return
    fi
    if mevboost_wait_ready; then
        msg_box "Relays Applied" "mev-boost restarted with the new relay list."
    else
        msg_box "Relays NOT Applied" "mev-boost is not serving after the relay change\n(-relay-check found no working relay?).\n\nMEV is effectively OFF: Nimbus falls back to local\nblock production.\n\nCheck: journalctl -u mev-boost -n 50\nThen fix the list via 'Select Relays' / 'Test Relays'."
    fi
}

mevboost_select_relays() {
    load_config

    CATALOG=$(mevboost_catalog "$NETWORK")
    if [ -z "$CATALOG" ]; then
        msg_box "No Relays on $NETWORK" "No MEV relays operate on network '$NETWORK'.\n\n(Holesky was shut down in September 2025 —\nuse hoodi for validator testing.)"
        return
    fi

    # Build the checklist: catalog entries first, preserving the current
    # selection (fresh setup -> catalog defaults), then any custom relays
    # already in MEV_RELAYS that are not in the catalog (always ON).
    local urls=() items=() idx=0
    local name url def state
    while IFS='|' read -r name url def; do
        [ -z "$url" ] && continue
        if [ -n "$MEV_RELAYS" ]; then
            state="OFF"
            [[ ",$MEV_RELAYS," == *",$url,"* ]] && state="ON"
        else
            state="$def"
        fi
        urls+=("$url")
        items+=("$idx" "$name" "$state")
        ((idx++))
    done <<< "$CATALOG"

    local r known
    for r in ${MEV_RELAYS//,/ }; do
        known=0
        for url in "${urls[@]}"; do
            [ "$r" = "$url" ] && known=1 && break
        done
        if [ "$known" -eq 0 ]; then
            urls+=("$r")
            items+=("$idx" "Custom: ${r#*@}" "ON")
            ((idx++))
        fi
    done

    SELECTION=$(whiptail --title "Select MEV Relays [$NETWORK]" \
        --checklist "Space = toggle, Enter = save.\n'filters OFAC' relays censor sanctioned transactions." \
        $TERM_HEIGHT $TERM_WIDTH $LIST_HEIGHT \
        "${items[@]}" \
        3>&1 1>&2 2>&3)

    # Cancelled (Esc) -> keep current selection
    [ $? -ne 0 ] && return

    local new="" tag
    for tag in $SELECTION; do
        tag="${tag//\"/}"
        new="${new:+$new,}${urls[$tag]}"
    done

    if [ -z "$new" ]; then
        msg_box "No Relays" "At least one relay is required.\n\nSelection unchanged."
        return
    fi

    [ "$new" = "$MEV_RELAYS" ] && return

    MEV_RELAYS="$new"
    save_config
    mevboost_apply_relay_change
}

mevboost_add_custom() {
    load_config

    NEW_RELAY=$(input_box "Add Custom Relay" "Full relay URL (https://0x<96-hex-pubkey>@host):" "")
    [ -z "$NEW_RELAY" ] && return

    if [[ ! "$NEW_RELAY" =~ ^https://0x[0-9a-fA-F]{96}@[A-Za-z0-9._-]+$ ]]; then
        msg_box "Invalid Relay URL" "Expected format:\n  https://0x<96 hex chars>@hostname\n\nExample:\n  https://0xac6e...a37ae@boost-relay.flashbots.net"
        return
    fi

    if [[ ",$MEV_RELAYS," == *",$NEW_RELAY,"* ]]; then
        msg_box "Already Added" "This relay is already in the list."
        return
    fi

    MEV_RELAYS="${MEV_RELAYS:+$MEV_RELAYS,}$NEW_RELAY"
    save_config
    mevboost_apply_relay_change
    msg_box "Relay Added" "Added:\n  ${NEW_RELAY#*@}\n\nTotal relays: $(echo "$MEV_RELAYS" | tr ',' '\n' | grep -c .)"
}

mevboost_test_relays() {
    load_config

    if [ -z "$MEV_RELAYS" ]; then
        msg_box "No Relays" "No relays configured.\n\nUse 'Select Relays' first."
        return
    fi

    clear
    echo ""
    echo "Testing relays (GET /eth/v1/builder/status, 10s timeout)..."
    echo ""

    INFO="Relay status:\n"
    INFO+="─────────────────────────────────────────────────────────\n"
    local r host code
    for r in ${MEV_RELAYS//,/ }; do
        host="${r#*@}"
        echo "  checking $host ..."
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://${host}/eth/v1/builder/status" 2>/dev/null)
        if [ "$code" = "200" ]; then
            INFO+="  [OK]   $host\n"
        else
            INFO+="  [FAIL] $host (HTTP ${code:-000})\n"
        fi
    done

    whiptail --title "Relay Test" --scrolltext --msgbox "$INFO" $TERM_HEIGHT $TERM_WIDTH
}

mevboost_status() {
    load_config

    INFO="═══════════════════════════════════════════════════════════\n"
    INFO+="                    MEV BOOST STATUS\n"
    INFO+="═══════════════════════════════════════════════════════════\n\n"

    SVC_STATUS=$(systemctl is-active mev-boost 2>/dev/null)
    SVC_STATUS=${SVC_STATUS:-inactive}
    SVC_ENABLED=$(systemctl is-enabled mev-boost 2>/dev/null)
    SVC_ENABLED=${SVC_ENABLED:-disabled}

    INFO+="▶ SERVICE\n"
    INFO+="─────────────────────────────────────────────────────────\n"
    INFO+="  Status: $SVC_STATUS\n"
    INFO+="  Boot: $SVC_ENABLED\n"
    INFO+="  Listen: $MEV_BOOST_LISTEN\n"

    INFO+="\n▶ CONFIGURATION\n"
    INFO+="─────────────────────────────────────────────────────────\n"
    INFO+="  Enabled: ${MEV_BOOST_ENABLED:-false}\n"
    INFO+="  Network: $NETWORK\n"
    INFO+="  Nimbus BN flags: ${MEV_BOOST_BN_FLAGS:-none}\n"
    INFO+="  Nimbus VC flags: ${MEV_BOOST_VC_FLAGS:-none}\n"

    INFO+="\n▶ RELAYS\n"
    INFO+="─────────────────────────────────────────────────────────\n"
    if [ -n "$MEV_RELAYS" ]; then
        local r
        for r in ${MEV_RELAYS//,/ }; do
            INFO+="  ${r#*@}\n"
        done
    else
        INFO+="  none configured\n"
    fi

    INFO+="\n▶ NOTES\n"
    INFO+="─────────────────────────────────────────────────────────\n"
    INFO+="  Nimbus keeps a local block as fallback and prefers it\n"
    INFO+="  unless a builder bid beats it by >10%\n"
    INFO+="  (--local-block-value-boost default).\n"
    INFO+="  Flag changes require a Nimbus restart.\n"

    whiptail --title "MEV Boost Status" --scrolltext --msgbox "$INFO" 24 $TERM_WIDTH
}
