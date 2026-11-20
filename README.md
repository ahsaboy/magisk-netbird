<p align="center">
  <img src="docs/netbird-logo.png" alt="NetBird logo" width="340">
</p>

<h1 align="center">Magisk NetBird</h1>

<p align="center">
  <img alt="Release" src="https://img.shields.io/github/v/release/ahsaboy/magisk-netbird?logo=git&logoColor=white">
  <img alt="Downloads" src="https://img.shields.io/github/downloads/ahsaboy/magisk-netbird/total?logo=github&logoColor=white">
  <img alt="NetBird" src="https://img.shields.io/github/v/release/netbirdio/netbird?label=NetBird">
  <img alt="Magisk" src="https://img.shields.io/badge/Magisk-%E2%89%A520.4-green?logo=magisk&logoColor=white">
  <img alt="Arch" src="https://img.shields.io/badge/arch-arm64%20%7C%20armv7%20%7C%20x86__64-lightgrey?logo=android&logoColor=3C4043">
</p>

<p align="center"><b><a href="README.md">English</a> · <a href="README.zh-CN.md">中文</a></b></p>

Minimal Magisk module wrapper for the NetBird CLI daemon. Official NetBird
binaries (currently v0.82.1) are bundled for three architectures.

DNS interception is off by default. Enable it with the WebUI's **Use NetBird DNS** switch or `netbird.service dns on`.

## Download

| Zip | Devices |
| --- | --- |
| `magisk-netbird-<version>.zip` | arm64-v8a, armeabi-v7a, and x86_64 |

Latest release: <https://github.com/ahsaboy/magisk-netbird/releases/latest>

The release ZIP contains all three NetBird binaries and installs on arm64-v8a,
32-bit ARM, and x86_64. Magisk-compatible managers can check for updates from
the module's update information. The ACTION button needs Magisk v28+.

## Usage

Connect and check status:

```sh
su -c 'netbird.service up --setup-key <KEY> --management-url <URL>'
su -c 'netbird.service status'
su -c 'netbird.service down'   # disconnect; daemon stays running
su -c 'netbird.service stop'   # stop the daemon
su -c 'netbird.service start'
su -c 'netbird.service peers'
su -c 'netbird.service log --once'
```

On KernelSU without a mount metamodule installed, the module's `system/bin`
overlay is not mounted and `netbird.service` may be missing from `PATH` after
a reboot. The module re-creates `/dev/netbird` and `/dev/netbird.service`
symlinks on every boot; use those as a drop-in replacement:

```sh
su -c '/dev/netbird.service status'
```

To keep the setup key out of shell history and `ps` output, prefer a file:

```sh
su -c 'echo -n <KEY> > /data/adb/netbird/setup.key && chmod 600 /data/adb/netbird/setup.key'
su -c 'netbird.service up --setup-key-file /data/adb/netbird/setup.key --management-url <URL>'
```

Inspect peers with `netbird.service peers` for connection type, latency, traffic,
and last-handshake details.

The module ACTION button is a shortcut for manager users. KernelSU users can open
the WebUI for status, routes, health, profiles, and scheduled automation controls.
`down` disconnects without stopping the daemon or watcher; use `stop` to stop
the daemon.

<p align="center">
  <img src="docs/kernelsu-webui.jpg" alt="Magisk NetBird KernelSU WebUI" width="360">
</p>

## Configuration

Defaults are set in `netbird/settings.sh`; override any of them via environment
variables (environment outranks CLI flags in NetBird):

| Variable | Default | Effect |
| --- | --- | --- |
| `NB_DISABLE_DNS` | `true` | Also enforced on `up` via `--disable-dns`. |
| `NB_DISABLE_IPV6` | `false` | When `true`, `up` appends `--disable-ipv6`; this disables NetBird overlay IPv6 and is not a firewall compatibility workaround. |
| `NB_DISABLE_FIREWALL` | `false` | When `true`, `up` appends `--disable-firewall` (client stops managing firewall rules). |
| `NB_FORCE_USERSPACE_FIREWALL` | `auto` | Automatically forced when Android has no usable `ip6tables` nat table; set explicitly to override detection. |
| `NB_WG_KERNEL_DISABLED` | `auto` | Automatically forced with the userspace-firewall fallback unless explicitly set. |
| `NB_DISABLE_SSH_CONFIG` | `true` | Skips writing `/etc/ssh/ssh_config.d` (read-only on Android). |
| `NB_SKIP_NFTABLES_CHECK` | `true` | Skips the nftables probe, which always fails on Android. |
| `NB_SKIP_DNS_PROBE` | `true` | Skips the local-resolver startup probe. |
| `NB_NETWORK_MONITOR` | `true` | Upstream defaults to `false` on Linux; enabled for faster reconnects after network switches. |
| `NB_STATE_DIR` | `/data/adb/netbird` | Writable location for `state.json` / WireGuard keys (upstream default `/var/lib/netbird` does not exist on Android). |
| `NB_LOG_LEVEL` | `info` | NetBird log level. |
| `NB_LOG_MAX_SIZE_MB` | `5` | NetBird's own log-rotation cap for `client.log` in MiB (upstream default 15). |
| `NB_WATCHDOG` | `on` | Watchdog: auto-restart the daemon when its status stops responding; `off` disables. |
| `NB_WATCHDOG_FAILS` | `3` | Consecutive failed status probes before a restart (30s apart while connected, 300s while disconnected). |
| `NB_WATCHDOG_MAX_RESTARTS` | `10` | Restart budget; reset after 5 healthy probes. |

All of the variables above (and any other variable the official client
supports) can be persisted in `/data/adb/netbird/.env` as `KEY=VALUE` lines
(`#` starts a comment); a real environment variable still wins over the file.
Start from the installed template:

```sh
cp /data/adb/netbird/netbird.env.example /data/adb/netbird/.env
```

Daemon-read variables (e.g. `NB_LOG_LEVEL`) apply after the next
`netbird.service restart`; no reboot is needed. On Android builds without a usable IPv6
`nat` table, the module automatically enables NetBird's userspace firewall and userspace
WireGuard so native `ip6tables` initialization cannot block startup.

Flags added by `up` persist in `config.json` and are applied on (re)connect,
so after changing them run `netbird.service down` followed by
`netbird.service up` (or `netbird.service restart`).

The watcher checks daemon process state every 30 seconds. It probes NetBird status
every 30 seconds while connected and every 300 seconds after an intentional disconnect;
the watchdog restarts an unresponsive daemon after the configured number of failed probes.
`netbird.service down` only disconnects. `netbird.service stop` stops the daemon, while
`start` or `up` starts it again. Uninstall removes the module's network rules.

## Dynamic status

While the daemon is running, `module.prop` is refreshed periodically. Because module descriptions are single-line metadata, status is shown as compact paired fields such as IP/peers, management/signal, relay/interface, memory, CA count, and refresh time. The peers field carries a direct/relay bracket (`[P3 R1]` = 3 direct, 1 relayed); `WD=n` shows accumulated watchdog restarts.

## Custom CA trust

For self-hosted NetBird servers with a private CA, place PEM certificates in `/data/adb/netbird/certs/` as `.crt`, `.pem`, or `.cer` files. `/data/adb/netbird/ca.crt` is also loaded automatically. Restart NetBird after changing certificates:

```sh
su -c 'netbird.service restart'
su -c '/data/adb/netbird/scripts/cert-trust.sh status'
```

The module injects `/system/etc/resolv.conf` for the Linux binary runtime. `netbird.service up` keeps NetBird's Linux host DNS manager disabled; the optional module DNS switch controls Android DNS interception independently.

## NetBird DNS

```sh
su -c 'netbird.service dns on'
su -c 'netbird.service dns status'
su -c 'netbird.service dns check'
su -c 'netbird.service dns off'
```

Only the default network is redirected. Lookups bound to IMS, MMS, or other non-default networks are untouched. Fallback supports link-local IPv6 resolvers.

Plain UDP/TCP DNS on port 53 is redirected to a local helper that asks NetBird's resolver first, so peer names, custom zones and domain-specific nameservers work without listing domains in the module. NetBird answers `REFUSED` only for names no NetBird handler owns; those queries go to the resolver the app originally asked, with the app's original Android routing mark. The same fallback applies while NetBird's resolver is unreachable, except for known NetBird names described below. With a primary (catch-all) nameserver configured in NetBird management, NetBird answers all other names itself. NetBird's own `NXDOMAIN` and `SERVFAIL` are returned unchanged, so while NetBird answers, names in its zones are not sent to other resolvers. While NetBird's resolver is unreachable, names under the peer domain and NetBird match domains get `SERVFAIL`; every other name, including records of NetBird custom zones (they are not listed in the client status), is sent to the original resolver so that the phone keeps resolving.

Queries that enter another VPN's TUN stay with that VPN. When a resolver listens on the phone itself (a local DNS proxy on `127.0.0.1:53` or `[::1]:53`), queries addressed to it reach it unchanged; without one, loopback queries are redirected, because root tools that cannot reach Android's resolver send their lookups to `127.0.0.1:53`. Plain DNS that such a VPN sends from the phone to its own upstreams is redirected like any other query; names NetBird does not own still reach the upstream the VPN chose. DNS over DoH, DoT, DoQ, a remote proxy or a nonstandard port, and DNS from hotspot clients, cannot be redirected transparently; point that tool at NetBird's resolver explicitly if needed. The WebUI warns when Android's Private DNS is strict or has validated encrypted DNS on the current network, because those system queries bypass the redirect. Encrypted DNS chosen inside another VPN or app cannot be detected.

Root processes are redirected too, except queries to NetBird's upstream nameservers and the module's bootstrap `resolv.conf` servers, which NetBird itself uses. Queries using the upstream routing exception are source-NATed to the physical interface's address. Set `NB_DNS_ROOT=bypass` in `/data/adb/netbird/.env` when a root-run transparent proxy already captures root DNS.

The setting survives reconnects and reboot. Disconnecting or stopping NetBird removes the redirect; reconnecting restores it. Network and VPN changes are reconciled within a few seconds. Cleanup only removes module-owned chains, routing rules and translated DNS connections; with the switch off, lifecycle hooks do nothing.

The helper serves UDP/TCP on `127.0.0.1:5354` and `[::1]:5354`. IPv6 uses NAT when available, otherwise local-only TPROXY (table 7121, preference 85). Without either, IPv6 plain DNS is rejected so Android retries over an intercepted IPv4 server; if the network only offers IPv6 DNS, IPv6 queries are left alone and the WebUI says so. Devices with IPv6 disabled only use IPv4 interception. Module marks use bits 21-31 (`0x4e400000` upstream exception at preference 84, `0x4e600000` TPROXY, `0x4ea00000` helper traffic, mask `0xffe00000`), leaving Android's netId and policy bits intact. Conflicting chains, rule priorities or the reserved table prevent activation.

DNS helper development: `cd tools/nb-dns && go test -race ./...`. Run `sh tests/dns.test.sh` for module lifecycle tests. Release packaging builds the helper for all three supported architectures.

Direct NetBird commands should include the module daemon address:

```sh
su -c 'netbird --daemon-addr unix:///data/adb/netbird/run/netbird.sock status'
```
