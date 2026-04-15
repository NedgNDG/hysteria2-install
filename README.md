# Hysteria2 Installation and Management Script

A universal bash script to install, configure, and manage a Hysteria 2 VPN server on Linux.

## Features

* OS Support: Works automatically on Debian, Ubuntu, CentOS, Fedora, Arch Linux, and openSUSE.
* Architecture Support: Auto-detects and installs the correct binary for amd64, arm64, arm, s390x, and 386.
* Certificates: Choose between Let's Encrypt (domain required) or an auto-generated self-signed certificate bound to your server's IP.
* Client Management: Add, list, and delete clients. Automatically generates configuration files, sharing links, and QR codes for the terminal.
* Bypass Restrictions: Built-in configuration for Salamander obfuscation and website masquerading.
* Port Hopping: Bypass aggressive UDP blocking and QoS by listening on a wide range of ports simultaneously with your main port.
* Smart Firewall Management: Native, clean integration with both `iptables` and `nftables`. Port forwarding rules are dynamically applied and safely removed alongside the `systemd` service lifecycle.
* Congestion Control: Select between Hysteria Brutal, BBR, or Reno for each client.
* In-place Updates: Check for and install the latest Hysteria 2 core updates directly from the official repository without losing your configurations.

## Quick Install

Run the following command as `root` on your server to download and execute the script directly from GitHub:

```bash
curl -O https://raw.githubusercontent.com/NedgNDG/hysteria2-install/main/hysteria-install.sh
chmod +x hysteria-install.sh
./hysteria-install.sh
```

After installation, use `./hysteria-install.sh` to manage Hysteria2.
