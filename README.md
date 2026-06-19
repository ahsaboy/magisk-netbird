# Magisk NetBird Module

A [Magisk](https://github.com/topjohnwu/Magisk) / [KernelSU](https://github.com/tiann/KernelSU) module for running [NetBird](https://netbird.io) on rooted Android devices.

## Why a Magisk Module?

The official NetBird app uses the Android VPN API — **only one VPN can be active at a time**. This module runs NetBird as a **root daemon** using the kernel WireGuard interface directly, so:

- **NetBird runs alongside other VPNs** (WireGuard, OpenVPN, etc.)
- **Persistent connection** survives app kills and screen off
- **Boot-to-boot** connectivity with automatic service start
- **Lower resource usage** — no Java/Kotlin layer

## Architecture

```
NetBird daemon (Linux binary, GOOS=linux)
    → kernel WireGuard interface (wg0)
    → kernel TUN device (/dev/net/tun)
    → direct peer-to-peer WireGuard tunnel
```

The NetBird CLI is compiled as a standard Linux binary (`CGO_ENABLED=0 GOOS=linux`). Since Android runs the Linux kernel, this binary works natively on rooted devices — **no cross-compilation toolchain, no NDK, no hev-socks5-tunnel bridge**.

## Features

- **WireGuard P2P mesh VPN** via kernel WireGuard
- **DNS management** built-in
- **SSH server** (connect to your phone via NetBird IP)
- **Subnet routing**
- **Auto-start on boot**
- **Magisk Manager integration** (enable/disable toggle, live status)
- **Multi-architecture**: arm64, arm, x86, x86_64
- **KernelSU** compatible

## Requirements

- Android 10+ (API 29+)
- Magisk v20.4+ or KernelSU
- Root access
- NetBird account ([netbird.io](https://netbird.io) or self-hosted)
- **WireGuard kernel module** (included in most modern Android kernels)

## Installation

### Download

Get the latest ZIP from [Releases](../../releases):
- **`Magisk-NetBird-vX.X.X.zip`** — full (binaries included)
- **`Magisk-NetBird-vX.X.X-lite.zip`** — downloads binaries at install

### Install

1. Open Magisk Manager → Modules → Install from storage
2. Select the ZIP
3. Reboot

### Quick Connect

```bash
# Cloud (netbird.io)
su -c 'netbird up --setup-key YOUR_SETUP_KEY'

# Self-hosted
su -c 'netbird up --setup-key KEY --management-url https://your-server.com'
```

## Usage

### Service Manager

```bash
su -c 'netbird.service start'       # Start daemon
su -c 'netbird.service stop'        # Stop daemon
su -c 'netbird.service restart'     # Restart
su -c 'netbird.service status'      # Status + WireGuard info
su -c 'netbird.service status peer' # Detailed peer list
su -c 'netbird.service log'         # View logs
su -c 'netbird.service log 100'     # Last 100 lines
su -c 'netbird.service troubleshoot' # Diagnostics
```

### NetBird CLI

```bash
su -c 'netbird status'              # Connection status
su -c 'netbird up --setup-key KEY'  # Connect
su -c 'netbird down'                # Disconnect
su -c 'netbird ssh user@peer-ip'    # SSH to peer
```

### Configuration

Edit `/data/adb/netbird/data/config.json`:

```json
{
  "ManagementUrl": "https://api.netbird.io",
  "SetupKey": "",
  "EnableSSHServer": true,
  "DisableDNS": false,
  "DisableFirewall": false
}
```

### SSH Server

With `EnableSSHServer: true`, connect from any NetBird peer:
```bash
ssh shell@<android-netbird-ip>
```

## Directory Structure

```
/data/adb/netbird/
├── bin/netbird              # Daemon binary
├── scripts/
│   ├── start.sh             # Boot orchestrator
│   ├── netbird.service      # Service manager CLI
│   └── netbird.inotify      # Enable/disable watcher
├── data/config.json         # Configuration
├── run/
│   ├── netbird.log          # Daemon log
│   └── service.log          # Service log
└── backups/                 # Version backups
```

## Building from Source

The build is just Go cross-compilation — no NDK needed:

```bash
git clone https://github.com/Magisk-NetBird/Magisk-netbird.git
cd Magisk-netbird

# Clone NetBird
git clone --depth 1 https://github.com/netbirdio/netbird.git src

# Build for arm64 (repeat for arm, x86, x86_64)
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 \
  go build -ldflags="-s -w" -o netbird/bin/netbird-arm64 src/client

# Package
zip -r9 Magisk-NetBird.zip META-INF/ module.prop customize.sh \
  service.sh uninstall.sh update.json netbird/
```

Or push a tag to GitHub to trigger automatic builds:
```bash
git tag v1.0.0 && git push --tags
```

## Troubleshooting

```bash
# Full diagnostics
su -c 'netbird.service troubleshoot'

# Check daemon
su -c 'netbird.service log'

# Check WireGuard
su -c 'ip link show wg0'
su -c 'wg show'

# Check kernel WireGuard support
su -c 'cat /proc/modules | grep wireguard'
su -c 'ls /sys/module/wireguard'
```

## FAQ

**Q: Does this work alongside Tailscale/WireGuard?**
A: Yes! That's the whole point of the Magisk module approach.

**Q: What if my kernel doesn't have WireGuard?**
A: Most Android 10+ kernels include WireGuard. Check with `cat /proc/modules | grep wireguard`. If missing, you'll need a custom kernel with WireGuard support.

**Q: How do I update?**
A: Install the new ZIP in Magisk Manager. Configuration and connection state are preserved.

**Q: How do I uninstall?**
A: Remove the module in Magisk Manager and reboot. Optionally: `rm -rf /data/adb/netbird`

## Credits

- [NetBird](https://netbird.io) — WireGuard-based P2P VPN
- [magisk-tailscaled](https://github.com/anasfanani/magisk-tailscaled) — Reference architecture

## License

MIT
