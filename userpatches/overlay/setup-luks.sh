#!/bin/bash
#
# setup-luks.sh - One-time LUKS partition setup for validator keys
#
# This script:
# 1. Creates partition on NVMe (if not exists)
# 2. Formats as LUKS2 with user password
# 3. Creates ext4 filesystem
# 4. Sets up /home/signer directory structure
#
# Usage: sudo /opt/web3pi/setup-luks.sh
#
# Run this ONCE after first boot, then use unlock-validator.sh for daily use.
#

set -e

L_DISK="/dev/nvme0n1"
L_PART="${L_DISK}p3"
L_MAPPER="signer_home"
L_MOUNTPOINT="/home/signer"
L_SIZE_END="-2GiB"   # 2 GiB partition for signer home

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root: sudo $0"
    exit 1
fi

echo ""
echo "============================================================"
echo "  LUKS SETUP FOR VALIDATOR KEYS"
echo "============================================================"
echo ""

# Check if already set up
if cryptsetup isLuks "$L_PART" 2>/dev/null; then
    echo "LUKS partition already exists on $L_PART"
    echo ""
    echo "If you want to start the validator, run:"
    echo "  sudo /opt/web3pi/unlock-validator.sh"
    echo ""
    exit 0
fi

# Check if partition exists, create if not
echo "[1/6] Checking partition..."
if ! lsblk -no NAME | grep -q "nvme0n1p3"; then
    echo "Creating partition $L_PART..."

    # Detect partition table type (GPT vs MBR)
    PT_TYPE=$(parted -s $L_DISK print 2>/dev/null | grep "Partition Table" | awk '{print $3}')
    if [ "$PT_TYPE" = "gpt" ]; then
        parted -s $L_DISK -- mkpart signer "$L_SIZE_END" 100%
    else
        parted -s $L_DISK -- mkpart primary "$L_SIZE_END" 100%
    fi
    partprobe $L_DISK
    sleep 1

    # Verify
    if ! lsblk -no NAME | grep -q "nvme0n1p3"; then
        echo "ERROR: Failed to create partition $L_PART"
        exit 1
    fi
    echo "Partition created."
else
    echo "Partition $L_PART already exists."
fi

echo ""
echo "[2/6] LUKS Encryption Setup"
echo ""
echo "  You will now create a password to encrypt the signer"
echo "  home directory. This password will be required every"
echo "  time you want to start the validator after a reboot."
echo ""
echo "  IMPORTANT: Remember this password! Without it, you"
echo "  cannot access your validator keys."
echo ""
echo "============================================================"
echo ""

# Format as LUKS
if ! cryptsetup luksFormat $L_PART --type luks2 --cipher aes-xts-plain64 --key-size 512 --pbkdf argon2id; then
    echo ""
    echo "ERROR: LUKS formatting failed."
    exit 1
fi

echo ""
echo "[3/6] Opening LUKS partition..."
echo "Enter your password again:"
echo ""

if ! cryptsetup open $L_PART $L_MAPPER; then
    echo "ERROR: Failed to open LUKS partition."
    exit 1
fi

echo ""
echo "[4/6] Creating ext4 filesystem..."
mkfs.ext4 /dev/mapper/$L_MAPPER

echo ""
echo "[5/6] Setting up signer home directory..."
mkdir -p $L_MOUNTPOINT
mount /dev/mapper/$L_MAPPER $L_MOUNTPOINT

# Create directory structure for validator keys
mkdir -p $L_MOUNTPOINT/keys
mkdir -p $L_MOUNTPOINT/.bash_history_dir
chown -R signer:signer $L_MOUNTPOINT
chmod 700 $L_MOUNTPOINT
chmod 700 $L_MOUNTPOINT/keys

echo ""
echo "[6/6] Unmounting and closing LUKS..."
umount $L_MOUNTPOINT
cryptsetup close $L_MAPPER

echo ""
echo "============================================================"
echo "  LUKS SETUP COMPLETE"
echo "============================================================"
echo ""
echo "  To start the validator, run:"
echo ""
echo "    sudo /opt/web3pi/unlock-validator.sh"
echo ""
echo "  This will unlock the encrypted partition and start"
echo "  the nimbus validator client."
echo ""
echo "============================================================"
echo ""
