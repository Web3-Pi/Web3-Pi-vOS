#!/bin/bash

set -e

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

# Add ethereum user to required groups
# sudo - allows executing commands as root
# netdev - manage network interfaces without sudo
# systemd-journal - view system logs with journalctl
# dialout - access serial ports (UART, Arduino)
# plugdev - access hot-plugged devices (USB)
for grp in sudo netdev systemd-journal dialout plugdev; do
    usermod -aG $grp ethereum
done

# Pre-create 'el'
adduser --system --home /var/lib/el --group el

# Pre-create 'cl'
adduser --system --home /var/lib/cl --group cl

# Set secure permissions for client data directories
chmod 750 /var/lib/el  # 750: group el can access (cl needs jwt.hex)
chmod 700 /var/lib/cl  # 700: Nimbus requirement

# Pre-create 'signer'
adduser --system --no-create-home --shell /usr/sbin/nologin --group signer
#--------------------------------------------------------------------------------------------

## Misc #####################################################################################
rm /root/.not_logged_in_yet     # Remove any first-login instructions
chmod +x /etc/update-motd.d/*   # Enable motd

# Fix MOTD banner (workaround for Armbian build bug that doesn't write VENDORPRETTYNAME)
echo 'VENDORPRETTYNAME="Web3 Pi Staking"' >> /etc/armbian-image-release
#--------------------------------------------------------------------------------------------

## Directories structure ####################################################################
mkdir -p /opt/web3pi                                    # Create a directory for Web3 Pi
mkdir -p /opt/web3pi/logs                               # Create a directory for Web3 Pi logs
chown -R ethereum:ethereum /opt/web3pi 					# Set ownership to 'ethereum' user

# Create home directory for ethereum user (deferred from useradd -M)
mkdir -p /home/ethereum
chown ethereum:ethereum /home/ethereum
chmod 750 /home/ethereum

# Staging directory for validator keystore import (easy SCP access)
mkdir -p /home/ethereum/validator_keys
chown ethereum:ethereum /home/ethereum/validator_keys
chmod 700 /home/ethereum/validator_keys
#--------------------------------------------------------------------------------------------

## Configuration file #######################################################################
# Central configuration file (NETWORK=hoodi/mainnet)
cp /tmp/overlay/config /opt/web3pi/config
#--------------------------------------------------------------------------------------------

## rc.local #################################################################################
# Add rc.local file and rc-local.service
cp /tmp/overlay/rc.local /etc/rc.local
chmod +x /etc/rc.local
cp /tmp/overlay/rc-local.service /etc/systemd/system/rc-local.service
systemctl enable rc-local.service
#--------------------------------------------------------------------------------------------

## SSH key generation service (runs before ssh.service) ######################################
cp /tmp/overlay/ssh-keygen.service /etc/systemd/system/ssh-keygen.service
systemctl enable ssh-keygen.service
#--------------------------------------------------------------------------------------------

## JWT secret for EL-CL communication #######################################################
# Generate JWT secret (will be used by both Geth and Nimbus)
openssl rand -hex 32 > /var/lib/el/jwt.hex
chown el:el /var/lib/el/jwt.hex
chmod 640 /var/lib/el/jwt.hex
# Add 'cl' user to 'el' group so nimbus can read JWT
usermod -aG el cl
#--------------------------------------------------------------------------------------------

## Install APT packets ######################################################################
# ToDo: cleanup unnecessary packages
apt update
apt install -y software-properties-common apt-utils chrony avahi-daemon git git-extras build-essential
apt install -y nvme-cli jq speedtest-cli file vim net-tools telnet apt-transport-https gdisk iotop 
apt install -y screen bpytop cryptsetup unattended-upgrades dialog
# development packages
apt install -y smartmontools fio stress-ng neofetch 
# apt install -y python3-pip python3-netifaces python3-dev libpython3-dev python3-venv
# apt install -y gcc libraspberrypi-bin screen ccze iw flashrom figlet neofetch 
#apt install -y iproute2 iputils-ping dnsutils gawk bsdutils # for Wan Failover script
#apt install -y apcupsd # For UPS support
#--------------------------------------------------------------------------------------------

## nftables (firewall) ######################################################################
apt install -y nftables

# Disable IPv6 at system level
cat >> /etc/sysctl.d/99-disable-ipv6.conf << EOF
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF

# Copy nftables configuration
cp /tmp/overlay/etc/nftables.conf /etc/nftables.conf

# Enable nftables service
systemctl enable nftables
#-------------------------------------------------------------------------------------------

## WiFi stability fix #######################################################################
# Disable WiFi power save when wlan0 interface comes up (udev rule)
mkdir -p /etc/udev/rules.d
cp /tmp/overlay/etc/udev/rules.d/99-wifi-powersave.rules /etc/udev/rules.d/
#-------------------------------------------------------------------------------------------

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


## Geth service (Execution Layer) ###########################################################
cp /tmp/overlay/geth.service /etc/systemd/system/geth.service
# systemctl enable geth.service
#--------------------------------------------------------------------------------------------

## Nimbus beacon node service (Consensus Layer) #############################################
cp /tmp/overlay/nimbus-beacon-node.service /etc/systemd/system/nimbus-beacon-node.service
# systemctl enable nimbus-beacon-node.service
#--------------------------------------------------------------------------------------------

## Nimbus validator service #################################################################
# Service for nimbus_validator_client (not enabled - manual start after LUKS unlock)
cp /tmp/overlay/nimbus-validator.service /etc/systemd/system/nimbus-validator.service
# Don't enable - started manually via unlock-validator.sh
#--------------------------------------------------------------------------------------------

## LUKS setup script ########################################################################
# One-time script to create LUKS partition for validator keys
cp /tmp/overlay/setup-luks.sh /opt/web3pi/setup-luks.sh
chmod +x /opt/web3pi/setup-luks.sh
#--------------------------------------------------------------------------------------------

## LUKS unlock script #######################################################################
# Script to unlock LUKS partition and mount /home/signer
cp /tmp/overlay/unlock-luks.sh /opt/web3pi/unlock-luks.sh
chmod +x /opt/web3pi/unlock-luks.sh
#--------------------------------------------------------------------------------------------

## Validator start script ###################################################################
# Script to start validator (checks if LUKS is unlocked first)
cp /tmp/overlay/start-validator.sh /opt/web3pi/start-validator.sh
chmod +x /opt/web3pi/start-validator.sh
#--------------------------------------------------------------------------------------------

## Control Panel script #####################################################################
# Control panel for managing Web3 Pi node (symlinked to /home/ethereum in rc.local)
cp /tmp/overlay/control-panel.sh /opt/web3pi/control-panel.sh
chmod +x /opt/web3pi/control-panel.sh

# Copy control panel modules
cp -r /tmp/overlay/control-panel /opt/web3pi/control-panel
chmod +x /opt/web3pi/control-panel/lib/*.sh
chmod +x /opt/web3pi/control-panel/modules/*.sh
#--------------------------------------------------------------------------------------------

## Trusted node sync script #################################################################
# Script for fast initial sync using checkpoint sync servers
cp /tmp/overlay/trusted-node-sync.sh /opt/web3pi/trusted-node-sync.sh
chmod +x /opt/web3pi/trusted-node-sync.sh

# Checkpoint sync server lists
cp /tmp/overlay/servers_hoodi.txt /opt/web3pi/servers_hoodi.txt
cp /tmp/overlay/servers_holesky.txt /opt/web3pi/servers_holesky.txt
cp /tmp/overlay/servers_mainnet.txt /opt/web3pi/servers_mainnet.txt
#--------------------------------------------------------------------------------------------

## SSH key management scripts ###############################################################
# Script to add SSH public key
cp /tmp/overlay/ssh-add-key.sh /opt/web3pi/ssh-add-key.sh
chmod +x /opt/web3pi/ssh-add-key.sh

# Script to disable SSH password authentication
cp /tmp/overlay/ssh-disable-password.sh /opt/web3pi/ssh-disable-password.sh
chmod +x /opt/web3pi/ssh-disable-password.sh
#--------------------------------------------------------------------------------------------

systemctl daemon-reload


## Clone rpi-eeprom #########################################################################
# Ubuntu have old rpi-eeprom app
git-force-clone -b master https://github.com/raspberrypi/rpi-eeprom /opt/web3pi/rpi-eeprom
# This is later used in install.sh to update the firmware
#--------------------------------------------------------------------------------------------


## Install Web3 Pi UPS agent (w3p-ups) ######################################################
# Pre-install the latest released agent so the image boots with UPS monitoring
# and graceful shutdown ready. Falls back silently if the release tarball can't
# be fetched at build time — control-panel still has an "install/update" path.
W3P_UPS_VERSION=$(curl -fsSL "https://api.github.com/repos/Web3-Pi/Web3-Pi-UPS-Service/releases/latest" 2>/dev/null | grep '"tag_name":' | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
if [ -z "$W3P_UPS_VERSION" ]; then
    echo "WARN: could not resolve latest w3p-ups release tag; skipping pre-install"
else
    W3P_UPS_TARBALL_URL="https://github.com/Web3-Pi/Web3-Pi-UPS-Service/releases/download/${W3P_UPS_VERSION}/w3p-ups-${W3P_UPS_VERSION}-aarch64.tar.gz"
    W3P_UPS_TMP=$(mktemp -d)
    if curl -fsSL "$W3P_UPS_TARBALL_URL" -o "${W3P_UPS_TMP}/w3p-ups.tar.gz"; then
        tar -xzf "${W3P_UPS_TMP}/w3p-ups.tar.gz" -C "${W3P_UPS_TMP}"
        install -m 755 "${W3P_UPS_TMP}/w3p-ups" /usr/local/bin/w3p-ups
        mkdir -p /etc/w3p-ups
        # config.toml.example becomes the default config; existing-file checks in
        # the agent's installer aren't applicable here since the image is fresh.
        install -m 644 "${W3P_UPS_TMP}/config.toml.example" /etc/w3p-ups/config.toml
        install -m 755 "${W3P_UPS_TMP}/shutdown.sh" /etc/w3p-ups/shutdown.sh
        install -m 644 "${W3P_UPS_TMP}/w3p-ups.service" /etc/systemd/system/w3p-ups.service
        systemctl daemon-reload
        systemctl enable w3p-ups.service
        echo "w3p-ups ${W3P_UPS_VERSION} installed; service enabled."
    else
        echo "WARN: failed to download w3p-ups tarball from $W3P_UPS_TARBALL_URL"
    fi
    rm -rf "${W3P_UPS_TMP}"
fi
#--------------------------------------------------------------------------------------------


## Basic Security hardening #######################################################################
# Lock the root account
passwd --lock root
# Disable root login via SSH
sed -i 's/^PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config
## Disable password authentication via SSH
# ToDo
#sed -i 's/^PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
#sed -i 's/^#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
# Note: This can be configured later via control panel
#--------------------------------------------------------------------------------------------

exit 0