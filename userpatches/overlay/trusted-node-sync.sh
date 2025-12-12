#!/bin/bash
#
# Web3 Pi Staking - Trusted Node Sync
# Fast initial sync using checkpoint sync servers
#
# Usage: sudo /opt/web3pi/trusted-node-sync.sh [network] [server]
#   network: hoodi (default) or mainnet
#   server: optional checkpoint sync URL (uses server list if not provided)
#

set -e

# Source config for default network
CONFIG_FILE="/opt/web3pi/config"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

NETWORK="${1:-${NETWORK:-hoodi}}"
SERVER="$2"
DATA_DIR="/var/lib/cl"
SERVERS_FILE="/opt/web3pi/servers_${NETWORK}.txt"

# Validate network parameter
if [[ "$NETWORK" != "hoodi" && "$NETWORK" != "mainnet" ]]; then
    echo "Error: Invalid network '$NETWORK'. Use 'hoodi' or 'mainnet'."
    exit 1
fi

# Check if servers file exists (only if no server provided)
if [ -z "$SERVER" ] && [ ! -f "$SERVERS_FILE" ]; then
    echo "Error: Server list file not found: $SERVERS_FILE"
    exit 1
fi

echo "============================================================"
echo "  TRUSTED NODE SYNC - $NETWORK"
echo "============================================================"
echo ""
echo "  Data directory: $DATA_DIR"
echo ""

# Function to run trustedNodeSync
run_sync() {
    local url="$1"
    echo "Syncing from: $url"
    echo ""
    sudo -u cl nimbus_beacon_node trustedNodeSync \
        --network="$NETWORK" \
        --data-dir="$DATA_DIR" \
        --trusted-node-url="$url" \
        --backfill=false
}

if [ -n "$SERVER" ]; then
    # Use provided server
    run_sync "$SERVER"
else
    # Try servers from list
    echo "Trying servers from $SERVERS_FILE..."
    echo ""

    while IFS= read -r server || [ -n "$server" ]; do
        # Skip empty lines
        [ -z "$server" ] && continue

        echo "------------------------------------------------------------"
        echo "Trying: $server"
        echo "------------------------------------------------------------"

        if run_sync "$server"; then
            echo ""
            echo "============================================================"
            echo "  SYNC COMPLETED SUCCESSFULLY"
            echo "============================================================"
            echo ""
            echo "  You can now start the beacon node:"
            echo "    sudo systemctl start nimbus-beacon-node"
            echo ""
            exit 0
        else
            echo ""
            echo "Failed with $server, trying next..."
            echo ""
        fi
    done < "$SERVERS_FILE"

    echo ""
    echo "Error: All servers failed. Please try again later or specify a server manually."
    exit 1
fi
