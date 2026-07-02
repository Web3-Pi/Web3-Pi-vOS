#!/bin/bash
#
# Web3 Pi Control Panel - Monitoring Module
#

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
            START_TIME=$SECONDS
            dialog --title "Sync Status (auto-refresh 5s)" \
                   --ok-label "Back" \
                   --timeout 5 \
                   --msgbox "$(echo -e "$INFO")" \
                   20 50
            EXIT_CODE=$?
            ELAPSED=$((SECONDS - START_TIME))
            # Back pressed (0) = exit to menu
            # ESC pressed (255 but quick, < 4 sec) = exit to menu
            if [ $EXIT_CODE -eq 0 ] || ([ $EXIT_CODE -eq 255 ] && [ $ELAPSED -lt 4 ]); then
                clear
                break
            fi
            # timeout (255 after ~5 sec) = continue loop (auto-refresh)
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
