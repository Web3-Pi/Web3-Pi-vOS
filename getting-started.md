# Getting Started with Web3-Pi-vOS

Web3-Pi-vOS is a security-hardened operating system for Solo Ethereum Staking on Raspberry Pi 5.

> **WARNING: DEVELOPMENT STAGE**
>
> This project is in development.
> Use at your own risk. Always test on testnets (hoodi) before considering mainnet.

## Hardware Requirements

- Raspberry Pi 5 (16GB RAM)
- Active cooling
- Fast NVMe m.2 2TB
- Official power supply (5.1V 5A)
- Optional: Web3 Pi UPS for power protection

## Network Requirements

- Ethernet connection (WiFi or LTE not recommended for staking)
- DHCP
- **Router port forwarding:** Open ports **30303** and **9000** (TCP/UDP) to maximize peer connections

## Architecture Overview

### Client Stack

Web3-Pi-vOS runs a full Ethereum node and validator with three separate components:

| Component | Client | User | Data Location |
|-----------|--------|------|---------------|
| Execution Layer | Geth | `el` | `/var/lib/el` |
| Consensus Layer | nimbus-beacon-node | `cl` | `/var/lib/cl` |
| Validator | nimbus-validator-client | `signer` | `/home/signer` (LUKS) |

**Important:** Unlike typical Nimbus setups where beacon and validator run as a single process, Web3-Pi-vOS intentionally separates `nimbus-beacon-node` and `nimbus-validator-client`. This advanced configuration provides:

- **Isolation**: Each service runs under its own unprivileged user
- **Security**: Validator keys are accessible only to the `signer` user
- **Flexibility**: Services can be started/stopped independently

### User Model

| User | Purpose | Shell Access |
|------|---------|--------------|
| `ethereum` | Node operator (you) | Yes |
| `el` | Geth execution client | No (system user) |
| `cl` | Nimbus beacon node | No (system user) |
| `signer` | Validator key signing | No (`/usr/sbin/nologin`) |

### Security Design

1. **Service Isolation**: Each Ethereum client runs as a separate user with minimal privileges
2. **LUKS Encryption**: Validator keys stored on encrypted partition
3. **JWT Authentication**: EL-CL communication secured with shared secret
4. **Firewall**: Only P2P ports exposed; RPC/REST APIs on localhost only
5. **Systemd Sandboxing**: `ProtectSystem=strict`, `ProtectHome=yes`, `NoNewPrivileges=yes`

### LUKS Encrypted Storage

Validator keys require maximum protection. Web3-Pi-vOS stores them on a LUKS2-encrypted partition:

- **Partition**: `/dev/nvme0n1p3` (100 MiB)
- **Encryption**: AES-XTS-plain64 with Argon2id key derivation
- **Mount Point**: `/home/signer/.keys`
- **Access**: Only accessible when explicitly unlocked with your passphrase

**Flow:**
1. Setup LUKS partition (one-time, via control panel)
2. Unlock LUKS partition (after each reboot)
3. Import validator keys (once unlocked)
4. Start validator service

The `signer` user has no shell access—keys can only be used by the validator service, not extracted.

## Installation

### 1. Download Image

Download the latest Web3-Pi-vOS image from the releases page.

### 2. Flash to NVMe

Use [Balena Etcher](https://etcher.balena.io/) to write the image directly to your NVMe SSD.

**Note:** Web3-Pi-vOS boots from NVMe, not SD card. Connect your NVMe to your computer for flashing.

### 3. First Boot

1. Insert the NVMe into your Raspberry Pi 5
2. Connect Ethernet cable (required for initial setup)
3. Power on

System installation completes in approximately one minute.

### 4. Connect via SSH

Find your Pi's IP address:
- Check your router's DHCP client list, or
- Try mDNS: `ssh ethereum@rpi4b-w3p.local`

Connect:
```bash
ssh ethereum@<IP_ADDRESS>
```

Default credentials:
- **Username:** `ethereum`
- **Password:** `ethereum`

**You will be forced to change your password on first login.**

## Configuration

### Control Panel

The main configuration interface:

```bash
sudo ./control-panel.sh
```

The control panel provides a text-based menu for all operations:

1. **Eth Network Configuration** - Network and port settings
2. **SSH Security** - SSH key management
3. **LUKS Encrypted Storage** - Encrypted partition for validator keys
4. **Initial Sync** - Checkpoint sync for fast startup
5. **Service Management** - Control Geth/Nimbus services
6. **Monitoring** - Sync status, peers, resources
7. **Data Management** - Wipe blockchain data
8. **System** - Hardware settings, updates
9. **Validator Management** - Import keys, configure staking

### Recommended: Overclocking Settings

For Raspberry Pi 5 16GB with adequate cooling:

**System > Edit Boot Config**, add:

```
over_voltage_delta=30000
arm_freq=3000
core_freq=1000
core_freq_fixed=1
force_turbo=1
```

Default Pi 5 values for reference: `arm_freq=2400`, `core_freq=910`

**Reboot after changes.**

### Install Web3 Pi UPS Service

If using Web3 Pi UPS hardware for power protection:

**System > Web3 Pi UPS > Install Service**

Configure shutdown threshold and other settings after installation.

### Optional: Stress Test

Verify system stability with Pi-Under-Pressure:

**System > OC (Pi-Under-Pressure) > Install**

Then run a 5-minute stress test:

**System > OC (Pi-Under-Pressure) > Run Stress Test**

Monitor temperatures and check for throttling.

## Solo Staking Setup

### 1. Configure Network

**Eth Network Configuration > Select Network**

Choose your target network (mainnet, hoodi, holesky).

### 2. Setup LUKS Partition

**LUKS Encrypted Storage > Setup LUKS Partition**

- Enter a strong passphrase (this protects your validator keys)
- Remember this passphrase—you'll need it after every reboot

### 3. Run Trusted Node Sync

**Initial Sync > Run Trusted Node Sync**

This downloads a recent checkpoint state, reducing initial sync time from days to hours.

### 4. Start Nimbus Beacon Node (Consensus Layer)

**Service Management > Nimbus Beacon > Start**

### 5. Start Geth (Execution Layer)

**Service Management > Geth > Start**

### 6. Enable Services on Boot

To start Geth and Nimbus automatically after reboot:

- **Service Management > Geth > Enable**
- **Service Management > Nimbus Beacon > Enable**

**Note:** Do not enable the Validator service yet—it requires LUKS to be unlocked first, which must be done manually after each reboot.

### 7. Monitor Sync Progress

**Monitoring > Sync Status**

Wait for both Geth and Nimbus to fully sync before importing validator keys.

- **Geth**: Shows block number and sync progress
- **Nimbus**: Shows head slot and backfill progress

### 8. Unlock LUKS (if not already)

**LUKS Encrypted Storage > Unlock LUKS**

Enter your passphrase to mount the encrypted partition.

### 9. Import Validator Keys

Transfer your validator keystores to the Pi:

```bash
scp -r validator_keys/ ethereum@<PI_IP>:~/validator_keys/
```

Then import via control panel:

**Validator Management > Import Keys > From Staging Directory**

Enter your keystore password when prompted.

### 10. Configure Fee Recipient (REQUIRED)

**Validator Management > Configure Fee Recipient**

Enter your Ethereum address to receive block rewards and MEV.

### 11. Configure Graffiti (Optional)

**Validator Management > Configure Graffiti**

Custom message included in blocks you propose (max 32 characters).

### 12. Start Validator

**Validator Management > Start Validator**

The validator service will only start if LUKS is mounted.

## Daily Operations

### After Reboot

1. SSH into your Pi
2. Run `sudo ./control-panel.sh`
3. **LUKS Encrypted Storage > Unlock LUKS**
4. **Validator Management > Start Validator**

Or via command line:
```bash
sudo /opt/web3pi/unlock-luks.sh
sudo /opt/web3pi/start-validator.sh
```

### Monitoring

Check status anytime:
- **Monitoring > Sync Status** - Node sync health
- **Monitoring > Peer Connections** - Network connectivity
- **Monitoring > Resource Usage** - RAM/CPU usage
- **Service Management > View Logs** - Detailed service logs

### Service Management

Control individual services:
- **Service Management > Geth** - Execution layer
- **Service Management > Nimbus Beacon** - Consensus layer
- **Service Management > Nimbus Validator** - Validator client

## Network Ports

| Port | Protocol | Service | Exposed |
|------|----------|---------|---------|
| 22 | TCP | SSH | Yes (rate-limited) |
| 30303 | TCP/UDP | Geth P2P | Yes |
| 9000 | TCP/UDP | Nimbus P2P | Yes |
| 8545 | TCP | Geth RPC | Localhost only |
| 8551 | TCP | Engine API | Localhost only |
| 5052 | TCP | Beacon API | Localhost only |

**Router Port Forwarding:** Open ports **30303** (TCP/UDP) and **9000** (TCP/UDP) on your router and forward them to your Pi's IP address. This significantly increases the number of peers your node can connect to, improving sync speed and network participation.

**Note:** These ports can be changed via **Eth Network Configuration** in control panel. **If you change them, you must also manually update the firewall rules in `/etc/nftables.conf`.**

## Troubleshooting

### Cannot find Pi on network
- Ensure Ethernet is connected
- Check router DHCP client list
- Try mDNS: `ping rpi4b-w3p.local`

### Validator not starting
- Ensure LUKS is unlocked: **LUKS Encrypted Storage > Check Status**
- Check if keys are imported: **Validator Management > List Validators**
- Verify fee recipient is set: Required for validator operation

### Slow sync
- Use checkpoint sync: **Initial Sync > Run Trusted Node Sync**
- Check peer connections: **Monitoring > Peer Connections**
- Verify network ports are open on your router (30303, 9000)

