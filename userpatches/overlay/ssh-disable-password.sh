#!/bin/bash
#
# ssh-disable-password.sh - Disable SSH password authentication
#
# After running this script, only SSH key authentication will work.
# Make sure you have added your public key first!
#
# Usage: sudo /opt/web3pi/ssh-disable-password.sh
#

SSHD_CONFIG="/etc/ssh/sshd_config"
AUTH_KEYS="/home/ethereum/.ssh/authorized_keys"

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root: sudo $0"
    exit 1
fi

echo ""
echo "============================================================"
echo "  DISABLE SSH PASSWORD AUTHENTICATION"
echo "============================================================"
echo ""

# Check if authorized_keys exists and has keys
if [ ! -f "$AUTH_KEYS" ]; then
    echo "ERROR: No SSH keys found!"
    echo ""
    echo "You must add an SSH public key first:"
    echo "  sudo /opt/web3pi/ssh-add-key.sh"
    echo ""
    echo "Otherwise you will be locked out of the system!"
    exit 1
fi

KEY_COUNT=$(grep -c "^ssh-" "$AUTH_KEYS" 2>/dev/null || echo "0")
if [ "$KEY_COUNT" -eq 0 ]; then
    echo "ERROR: No valid SSH keys in authorized_keys!"
    echo ""
    echo "Add an SSH public key first:"
    echo "  sudo /opt/web3pi/ssh-add-key.sh"
    echo ""
    exit 1
fi

echo "Found $KEY_COUNT SSH key(s) in authorized_keys."
echo ""
echo "WARNING: After this change, password login will be disabled!"
echo "         Make sure your SSH key authentication works first."
echo ""
read -p "Continue? (yes/no): " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
    echo "Aborted."
    exit 0
fi

# Backup sshd_config
cp "$SSHD_CONFIG" "${SSHD_CONFIG}.backup.$(date +%Y%m%d%H%M%S)"

# Disable password authentication
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' "$SSHD_CONFIG"
sed -i 's/^#*ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' "$SSHD_CONFIG"
sed -i 's/^#*UsePAM.*/UsePAM no/' "$SSHD_CONFIG"

# Ensure pubkey authentication is enabled
sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' "$SSHD_CONFIG"

# If settings don't exist, add them
grep -q "^PasswordAuthentication" "$SSHD_CONFIG" || echo "PasswordAuthentication no" >> "$SSHD_CONFIG"
grep -q "^PubkeyAuthentication" "$SSHD_CONFIG" || echo "PubkeyAuthentication yes" >> "$SSHD_CONFIG"

# Restart SSH service
systemctl restart sshd

echo ""
echo "============================================================"
echo "  PASSWORD AUTHENTICATION DISABLED"
echo "============================================================"
echo ""
echo "  SSH password login is now disabled."
echo "  Only key-based authentication will work."
echo ""
echo "  IMPORTANT: Test your SSH key login in a NEW terminal"
echo "  before closing this session!"
echo ""
echo "    ssh ethereum@<ip-address>"
echo ""
echo "  If you get locked out, you'll need physical access"
echo "  to recover the system."
echo ""
echo "============================================================"
echo ""
