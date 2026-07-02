#!/bin/bash
#
# unlock-luks.sh - Unlock LUKS partition and mount /home/signer
#
# Usage: sudo /opt/web3pi/unlock-luks.sh
#

set -e

L_PART="/dev/nvme0n1p3"
L_MAPPER="signer_home"
L_MOUNTPOINT="/home/signer"

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root: sudo $0"
    exit 1
fi

# Check if partition exists
if [ ! -b "$L_PART" ]; then
    echo "ERROR: Partition $L_PART does not exist."
    echo "Run setup first: sudo /opt/web3pi/setup-luks.sh"
    exit 1
fi

# Check if LUKS is set up
if ! cryptsetup isLuks "$L_PART" 2>/dev/null; then
    echo "ERROR: $L_PART is not a LUKS partition."
    echo "Run setup first: sudo /opt/web3pi/setup-luks.sh"
    exit 1
fi

# Check if already mounted
if mountpoint -q "$L_MOUNTPOINT"; then
    echo "Signer home is already mounted at $L_MOUNTPOINT"
    exit 0
fi

echo ""
echo "============================================================"
echo "  UNLOCK LUKS PARTITION"
echo "============================================================"
echo ""

# Check if LUKS is already open
if [ -b "/dev/mapper/$L_MAPPER" ]; then
    echo "LUKS partition already unlocked, mounting..."
else
    echo "Enter LUKS password to unlock signer home:"
    echo ""

    if ! cryptsetup open "$L_PART" "$L_MAPPER"; then
        echo ""
        echo "ERROR: Failed to unlock LUKS partition."
        echo "Check your password and try again."
        exit 1
    fi

    echo ""
    echo "LUKS partition unlocked successfully."
fi

# Mount the partition
echo "Mounting $L_MOUNTPOINT..."
mkdir -p "$L_MOUNTPOINT"
mount "/dev/mapper/$L_MAPPER" "$L_MOUNTPOINT"
chown signer:signer "$L_MOUNTPOINT"
chmod 700 "$L_MOUNTPOINT"

echo ""
echo "============================================================"
echo "  SIGNER HOME UNLOCKED"
echo "============================================================"
echo ""
echo "  /home/signer is now mounted and accessible."
echo ""
echo "  To start the validator, run:"
echo "    sudo /opt/web3pi/start-validator.sh"
echo ""
echo "============================================================"
echo ""
