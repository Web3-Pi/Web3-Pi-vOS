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

# Pre-create 'el'
adduser --system --home /var/lib/el --group el

# Pre-create 'cl'
adduser --system --home /var/lib/cl --group cl

# Pre-create 'signer'
adduser --system --no-create-home --shell /usr/sbin/nologin --group signer
#--------------------------------------------------------------------------------------------

## Misc #####################################################################################
rm /root/.not_logged_in_yet     # Remove any first-login instructions
chmod +x /etc/update-motd.d/*   # Enable motd
#--------------------------------------------------------------------------------------------

## Directories structure ####################################################################
mkdir -p /opt/web3pi                                    # Create a directory for Web3 Pi
mkdir -p /opt/web3pi/logs                               # Create a directory for Web3 Pi logs
chown -R ethereum:ethereum /opt/web3pi 					# Set ownership to 'ethereum' user
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
# apt install -y python3-pip python3-netifaces python3-dev libpython3-dev python3-venv
# apt install -y gcc libraspberrypi-bin screen ccze iw flashrom figlet neofetch 
#apt install -y iproute2 iputils-ping dnsutils gawk bsdutils # for Wan Failover script
#apt install -y apcupsd # For UPS support
#--------------------------------------------------------------------------------------------

## UFW (firewall) ###########################################################################
apt install -y ufw

# Disable IPv6 in UFW (don't manage IPv6 rules)
sed -i 's/^IPV6=yes/IPV6=no/' /etc/default/ufw

# Disable IPv6 at system level
cat >> /etc/sysctl.d/99-disable-ipv6.conf << EOF
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF

# Default policies
ufw default deny incoming
ufw default allow outgoing

# SSH (rate limited)
ufw limit 22/tcp comment "SSH (rate limited)"

# Geth P2P
ufw allow 30303/tcp comment "Geth P2P TCP"
ufw allow 30303/udp comment "Geth P2P UDP"

# Nimbus P2P
ufw allow 9000/tcp comment "Nimbus P2P TCP"
ufw allow 9000/udp comment "Nimbus P2P UDP"

# Enable firewall
ufw --force enable
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