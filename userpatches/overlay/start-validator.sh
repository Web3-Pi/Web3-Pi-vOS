#!/bin/bash
#
# start-validator.sh - Start nimbus validator client
#
# This script checks if LUKS partition is unlocked and mounted,
# then starts the nimbus-validator service.
#
# Usage: sudo /opt/web3pi/start-validator.sh
#

L_MOUNTPOINT="/home/signer"

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root: sudo $0"
    exit 1
fi

# Check if LUKS partition is mounted
if ! mountpoint -q "$L_MOUNTPOINT"; then
    echo ""
    echo "============================================================"
    echo "  ERROR: SIGNER HOME NOT MOUNTED"
    echo "============================================================"
    echo ""
    echo "  The encrypted partition is not unlocked."
    echo ""
    echo "  First run:"
    echo "    sudo /opt/web3pi/unlock-luks.sh"
    echo ""
    echo "  Then run this script again."
    echo ""
    echo "============================================================"
    echo ""
    exit 1
fi

# Check if validator is already running
if systemctl is-active --quiet nimbus-validator; then
    echo "Nimbus validator is already running."
    echo ""
    systemctl status nimbus-validator --no-pager
    exit 0
fi

# Start validator service
echo ""
echo "Starting nimbus validator..."
systemctl start nimbus-validator

sleep 2

echo ""
echo "============================================================"
echo "  VALIDATOR STARTED"
echo "============================================================"
echo ""
systemctl status nimbus-validator --no-pager
echo ""
echo "To check logs: journalctl -u nimbus-validator -f"
echo "To stop:       sudo systemctl stop nimbus-validator"
echo ""
