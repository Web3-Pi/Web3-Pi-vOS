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

echo "MARKPOINT"
# Pre-create 'el'
adduser --system --home /var/lib/el --group el

# Pre-create 'cl'
adduser --system --home /var/lib/cl --group cl

# Pre-create 'signer'
adduser --system --no-create-home --shell /usr/sbin/nologin --group signer
#--------------------------------------------------------------------------------------------

## Misc #####################################################################################
rm /root/.not_logged_in_yet     # Remove any first-login instructions
# chmod +x /etc/update-motd.d/*   # Enable motd
#--------------------------------------------------------------------------------------------

## Directories structure ####################################################################
mkdir -p /opt/web3pi                                    # Create a directory for Web3 Pi
mkdir -p /opt/web3pi/logs                               # Create a directory for Web3 Pi logs
chown -R ethereum:ethereum /opt/web3pi 					# Set ownership to 'ethereum' user
#--------------------------------------------------------------------------------------------

## rc.local #################################################################################
# Add rc.local file and rc-local.service
cp /tmp/overlay/rc.local /etc/rc.local
chmod +x /etc/rc.local
cp /tmp/overlay/rc-local.service /etc/systemd/system/rc-local.service
systemctl enable rc-local.service
#--------------------------------------------------------------------------------------------

## Install APT packets ######################################################################
# ToDo: cleanup unnecessary packages
apt update
apt install -y software-properties-common apt-utils chrony avahi-daemon git git-extras build-essential
apt install -y nvme-cli jq speedtest-cli file vim net-tools telnet apt-transport-https gdisk iotop 
apt install -y screen bpytop
apt install -y unattended-upgrades
# development packages
apt install -y python3-pip python3-netifaces python3-dev libpython3-dev python3-venv
apt install -y gcc libraspberrypi-bin screen ccze iw flashrom figlet neofetch 
#apt install -y iproute2 iputils-ping dnsutils gawk bsdutils # for Wan Failover script
#apt install -y apcupsd # For UPS support
#--------------------------------------------------------------------------------------------

## UFW (firewall) ###########################################################################
apt install -y ufw
# ToDo: set up firewall rules
ufw allow 22/tcp comment "SSH"
ufw --force enable
#--------------------------------------------------------------------------------------------

## Add APT repository #######################################################################
# Nimbus repository
echo 'deb https://apt.status.im/nimbus all main' | tee /etc/apt/sources.list.d/nimbus.list
# Import the GPG key
curl https://apt.status.im/pubkey.asc -o /etc/apt/trusted.gpg.d/apt-status-im.asc

# Ethereum PPA for Geth
add-apt-repository -y ppa:ethereum/ethereum 

apt-get update     # Update the package list to include the new repositories
#--------------------------------------------------------------------------------------------

## Install Ethereum clients #################################################################
apt-get install -y nimbus-beacon-node nimbus-validator-client ethereum
#--------------------------------------------------------------------------------------------

## Clone rpi-eeprom #########################################################################
# Ubuntu have old rpi-eeprom app
git-force-clone -b master https://github.com/raspberrypi/rpi-eeprom /opt/web3pi/rpi-eeprom
# This is later used in install.sh to update the firmware
#--------------------------------------------------------------------------------------------

## Basic Security hardening #######################################################################
# Lock the root account
passwd --lock root
# Disable root login via SSH
sed -i 's/^PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config
## Disable password authentication via SSH
#ToDo
#sed -i 's/^PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
#sed -i 's/^#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
#--------------------------------------------------------------------------------------------

exit 0