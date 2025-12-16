# Web3 Pi Staking

> **WARNING: EARLY DEVELOPMENT STAGE**
>
> This project is in early development. Do NOT use in production environments.
> Use at your own risk. Always test on testnets (hoodi) before considering mainnet.

Ethereum staking OS image for Raspberry Pi 5, based on Armbian.

## Overview

Web3 Pi Staking provides a pre-configured environment for running:
- **Geth** - Execution Layer client
- **Nimbus** - Consensus Layer client (beacon node + validator)

With security features:
- nftables firewall with restrictive egress policy (IPv6 disabled)
- LUKS encrypted storage for validator keys
- SSH key-based authentication
- Separate system users for each component

## Hardware Requirements

- Raspberry Pi 5 (16GB RAM recommended)
- NVMe SSD (2TB+ recommended for mainnet)
- Boot from NVMe (no SD card)
- Stable internet connection
- Active cooling

---

## Quick Start Guide

### 1. Flash the Image

Download the latest image and flash it to your NVMe drive using Balena Etcher.

Insert NVMe SSD into your Raspberry Pi 5 and power on.

---

### 2. First Boot & SSH Login

The system will boot and configure itself. Wait ~1-3 minutes for first boot setup.

Find your Pi's IP address (check your router or use `nmap`):

```bash
ssh ethereum@<IP_ADDRESS>
```

**Default credentials:**
- Username: `ethereum`
- Password: `ethereum`

> You will be prompted to change the password on first login.

---

### 3. Launch Control Panel

All configuration is done through the Control Panel TUI:

```bash
sudo /opt/web3pi/control-panel.sh
```

The Control Panel provides:

| Option | Description |
|--------|-------------|
| **Eth Network Configuration** | Set network (hoodi/mainnet), ports, fee recipient |
| **SSH Security** | Add SSH keys, disable password auth |
| **LUKS Encrypted Storage** | Setup and unlock encrypted validator key storage |
| **Initial Sync** | Trusted node sync (checkpoint sync) |
| **Service Management** | Start/stop/enable Geth, Nimbus services |
| **Monitoring** | View logs, sync status, system resources |
| **Data Management** | Manage blockchain data |
| **System** | Hostname, timezone, reboot, shutdown |
| **Validator Management** | Import keys, configure validator |

---

### 4. Recommended Setup Order

1. **SSH Security** → Add your SSH public key, then disable password authentication
2. **Eth Network Configuration** → Select network (hoodi for testnet, mainnet for production)
3. **LUKS Encrypted Storage** → Setup encrypted partition for validator keys
4. **Initial Sync** → Perform trusted node sync (checkpoint sync)
5. **Service Management** → Enable and start Geth and Nimbus services
6. **Monitoring** → Monitor sync progress until fully synced
7. **Validator Management** → Import validator keys and start validating

---

### 5. Monitor Synchronization

Use **Monitoring** in Control Panel to view:
- Service status
- Sync progress
- Live logs

Or manually check:

```bash
# Service status
sudo systemctl status geth
sudo systemctl status nimbus-beacon-node

# Geth sync (returns false when synced)
geth attach --datadir /var/lib/el --exec "eth.syncing"

# Nimbus sync
curl -s http://127.0.0.1:5052/eth/v1/node/syncing | jq
```

Wait for both EL and CL to fully synchronize before setting up validator.

---

## After Reboot

After each system reboot, use Control Panel to:

1. **LUKS Encrypted Storage** → Unlock encrypted storage
2. **Service Management** → Verify services are running

> Geth and Nimbus beacon node start automatically if enabled.

---

## Importing Validator Keys

After your node is fully synced, import your validator keys:

### Option A: Via SSH (recommended)

1. Copy keystore files from your local machine:
   ```bash
   scp keystore-*.json ethereum@<IP_ADDRESS>:~/validator_keys/
   ```

2. On the Pi, open Control Panel:
   ```bash
   sudo /opt/web3pi/control-panel.sh
   ```

3. Navigate to: **Validator Management** → **Import Validator Keys** → **From ~/validator_keys**

4. Enter your keystore password when prompted

5. After successful import, keystore files will be moved to the encrypted LUKS partition (needed for Voluntary Exit)

### Option B: Via USB Drive

1. Copy keystore files to a USB drive
2. Insert USB into Raspberry Pi
3. Use Control Panel: **Validator Management** → **Import Validator Keys** → **From USB drive**

> **Note:** Always keep a backup of your keystore files in a secure offline location. These files are required for Voluntary Exit.

---

## File Locations

| Component | Directory |
|-----------|-----------|
| Configuration | `/opt/web3pi/config` |
| Geth data | `/var/lib/el` |
| Nimbus beacon data | `/var/lib/cl` |
| Validator keys | `/home/signer/keys` (encrypted LUKS) |
| Keystore files | `/home/signer/keys/*.json` (for Voluntary Exit) |
| Key import staging | `~/validator_keys` |
| Scripts | `/opt/web3pi/` |
| Logs | `/opt/web3pi/logs/` |

---

## Useful Commands

```bash
# Launch Control Panel (main configuration tool)
sudo /opt/web3pi/control-panel.sh

# Service control
sudo systemctl start|stop|restart|status geth
sudo systemctl start|stop|restart|status nimbus-beacon-node
sudo systemctl start|stop|restart|status nimbus-validator

# Firewall status
sudo nft list ruleset

# Disk usage
df -h
```

---

## Network Ports

| Port | Protocol | Service | Description |
|------|----------|---------|-------------|
| 22 | TCP | SSH | Remote access (rate limited) |
| 30303 | TCP/UDP | Geth | P2P communication |
| 9000 | TCP/UDP | Nimbus | P2P communication |

Internal only (localhost):
- 8545 - Geth HTTP RPC
- 8551 - Geth Auth RPC (Engine API)
- 5052 - Nimbus REST API

---

## Troubleshooting

### Services won't start
Use Control Panel → **Monitoring** to view logs, or manually:
```bash
sudo journalctl -u geth -n 50
sudo journalctl -u nimbus-beacon-node -n 50
```

### Sync issues
- Use Control Panel → **Eth Network Configuration** to verify correct network
- Check internet connectivity
- Verify firewall allows P2P ports: `sudo nft list ruleset`

### LUKS issues
- Use Control Panel → **LUKS Encrypted Storage** to manage encryption
- Ensure you're using the correct passphrase
- Check if partition exists: `lsblk`

---

## Additional Security Hardening (Optional)

The default firewall configuration allows DNS queries to any server (for DHCP compatibility). For maximum security, you can restrict DNS to specific trusted resolvers.

### Restrict DNS to Trusted Resolvers

1. Edit `/etc/nftables.conf` and replace:
   ```nft
   # DNS - open to all (DHCP compatibility)
   udp dport 53 accept
   tcp dport 53 accept
   ```

   With:
   ```nft
   # DNS - restricted to trusted resolvers
   udp dport 53 ip daddr { 1.1.1.1, 8.8.8.8, 9.9.9.9 } accept
   tcp dport 53 ip daddr { 1.1.1.1, 8.8.8.8, 9.9.9.9 } accept
   ```

2. Configure systemd-networkd to use these DNS servers (ignore DHCP DNS):

   Create `/etc/systemd/network/10-eth.network`:
   ```ini
   [Match]
   Name=eth* end*

   [Network]
   DHCP=yes
   DNS=1.1.1.1
   DNS=8.8.8.8
   DNS=9.9.9.9

   [DHCP]
   UseDNS=false
   ```

3. Apply changes:
   ```bash
   sudo systemctl restart systemd-networkd
   sudo systemctl restart nftables
   ```

This configuration:
- Prevents DNS hijacking from malicious DHCP servers
- Ensures consistent DNS resolution
- Blocks outbound DNS to unauthorized servers

---