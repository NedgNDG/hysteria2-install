# Hysteria2 Installation and Management Script

A universal bash script to install, configure, and manage a Hysteria 2 VPN server on Linux.

## Features

- **OS Support**: Works automatically on Debian, Ubuntu, CentOS, Fedora, Arch Linux, and openSUSE.
- **Architecture Support**: Auto-detects and installs the correct binary for amd64, arm64, arm, s390x, and 386.
- **Certificates**: Choose between Let's Encrypt (domain required) or an auto-generated self-signed certificate bound to your server's IP.
- **Client Management**: Add, list, and delete clients. Automatically generates configuration files, sharing links, and QR codes for the terminal.
- **Bypass Restrictions**: Built-in configuration for website masquerading and two obfuscation methods — **Salamander** (random-looking bytes) and **Gecko** (random bytes with configurable packet size randomization) — to evade QUIC/HTTP/3 detection.
- **Port Hopping**: Bypass aggressive UDP blocking and QoS by listening on a wide range of ports simultaneously with your main port. Supports **native mode** (Hysteria handles firewall rules automatically — recommended) as well as manual `iptables`/`nftables` backends for maximum compatibility.
- **Smart Firewall Management**: Native, clean integration with both `iptables` and `nftables`. Port forwarding rules are dynamically applied and safely removed alongside the `systemd` service lifecycle.
- **Congestion Control**: Select between Hysteria Brutal, BBR, or Reno for each client.
- **In-place Updates**: Check for and install the latest Hysteria 2 core updates directly from the official repository without losing your configurations.
- **IPv6 Support**: Automatic public IP detection with fallback for IPv6-only servers.
- **Safe Uninstall**: Fully cleans up systemd units, binaries, configs, and any leftover firewall rules (iptables/nftables) that may have been left behind after crashes.

## Quick Install

Run the following command as `root` on your server to download and execute the script directly from GitHub:

```bash
curl -O https://raw.githubusercontent.com/NedgNDG/hysteria2-install/main/hysteria-install.sh
chmod +x hysteria-install.sh
./hysteria-install.sh
```

After installation, use `./hysteria-install.sh` to manage Hysteria2.

## Upgrading from older versions

If you already have Hysteria installed via a previous version of this script, simply re-download and re-run it. Existing `settings.conf` files are backward-compatible — new fields (`HOP_METHOD`, `OBFS_TYPE`, `OBFS_MIN_PKT`, `OBFS_MAX_PKT`) will fall back to safe defaults. Use the **Server Settings** menu to enable Gecko obfuscation or switch to native port hopping on existing installations.
