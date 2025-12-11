#!/bin/bash

# arguments: $RELEASE $LINUXFAMILY $BOARD $BUILD_DESKTOP
#
# This is the image customization script

# NOTE: It is copied to /tmp directory inside the image
# and executed there inside chroot environment
# so don't reference any files that are not already installed

# NOTE: If you want to transfer files between chroot and host
# userpatches/overlay directory on host is bind-mounted to /tmp/overlay in chroot
# The sd card's root path is accessible via $SDCARD variable.

RELEASE=$1
LINUXFAMILY=$2
BOARD=$3
BUILD_DESKTOP=$4

# Path to a file indicating that the operations have already been executed
INIT_FLAG_CUSTOMIZE_IMAGE_SH="/root/.customize-image.sh.firstrun.done"

## CHECKS ###################################################################################
# If the inode number for '/' differs from the real root, we are inside chroot
if [ "$(stat -c %i /)" != "$(stat -c %i /proc/1/root/.)" ]; then
    echo "Running in chroot environment."
else
    echo "Running on a regular host system."
    exit 0
fi

# Check if the script has already been run
if [ ! -f "$INIT_FLAG_CUSTOMIZE_IMAGE_SH" ]; then
    echo "Running customize-image.sh in chroot for the first time."
else
    echo "One-time tasks have already been completed. Skipping customize-image.sh."
    exit 0
fi
#--------------------------------------------------------------------------------------------

## Pre-create users #########################################################################
# Pre-create 'ethereum' user without home directory
useradd -M -s /bin/bash ethereum
echo "ethereum:ethereum" | chpasswd

# Pre-create 'el' user without home directory
useradd -M -s /bin/bash el
# echo "el:el" | chpasswd

# Pre-create 'cl' user without home directory
useradd -M -s /bin/bash cl
# echo "cl:cl" | chpasswd

# Pre-create 'signer' user without home directory
useradd -M -s /bin/bash signer
# echo "signer:signer" | chpasswd
#--------------------------------------------------------------------------------------------

## Misc #####################################################################################
rm /root/.not_logged_in_yet     # Remove any first-login instructions
# chmod +x /etc/update-motd.d/*   # Enable motd
#--------------------------------------------------------------------------------------------

## rc.local #################################################################################
# Add rc.local file and rc-local.service
cp /tmp/overlay/rc.local /etc/rc.local
chmod +x /etc/rc.local
cp /tmp/overlay/rc-local.service /etc/systemd/system/rc-local.service
systemctl enable rc-local.service
#--------------------------------------------------------------------------------------------

