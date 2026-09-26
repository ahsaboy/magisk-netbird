<p align="center">
  <img src="docs/netbird-logo.png" alt="NetBird logo" width="340">
</p>

<h1 align="center">Magisk NetBird</h1>

<p align="center">
  <img alt="Release" src="https://img.shields.io/github/v/release/ahsaboy/magisk-netbird?logo=git&logoColor=white">
  <img alt="CI" src="https://img.shields.io/github/actions/workflow/status/ahsaboy/magisk-netbird/release.yml?branch=main&label=CI&logo=githubactions&logoColor=white">
  <img alt="Downloads" src="https://img.shields.io/github/downloads/ahsaboy/magisk-netbird/total?logo=github&logoColor=white">
  <img alt="NetBird" src="https://img.shields.io/github/v/release/netbirdio/netbird?label=NetBird">
  <img alt="Magisk" src="https://img.shields.io/badge/Magisk-%E2%89%A520.4-green?logo=magisk&logoColor=white">
  <img alt="Arch" src="https://img.shields.io/badge/arch-arm64%20%7C%20armv7%20%7C%20x86__64-lightgrey?logo=android&logoColor=3C4043">
</p>

<p align="center"><b><a href="README.md">English</a> · <a href="README.zh-CN.md">中文</a></b></p>

Minimal Magisk module wrapper for the NetBird CLI daemon. Official NetBird
binaries (currently v0.79.0) are bundled for three architectures and packaged
by GitHub Actions.

DNS management is disabled by default when joining with `netbird.service up`.

## Download

| Zip | Devices |
| --- | --- |
| `magisk-netbird-arm64-v8a.zip` | arm64-v8a (most modern phones) |
| `magisk-netbird-armv7.zip` | 32-bit ARM (armeabi-v7a) |
| `magisk-netbird-x86_64.zip` | x86_64 (emulators, some Chromebooks) |

Latest release: <https://github.com/ahsaboy/magisk-netbird/releases/latest>

Every install stamps a per-architecture `updateJson` into `module.prop`
(`update/update-<arch>.json`), so the Magisk app shows an
**update available** banner after a new release. The banner works in
Kitsune and older managers too; the ACTION button needs Magisk v28+.

## Cutting a release

```sh
# bump version + versionCode in module.prop (v1.3.0 -> 10300), commit, then:
git tag v1.3.0
git push origin main v1.3.0
```

The `Release` workflow downloads the matching official NetBird release for
each architecture, verifies sha256 against `checksums.txt`, packages the three
zips, attaches them to the GitHub Release, and refreshes `update/*.json`,
`update.json` and `CHANGELOG.md` on `main`. The stamped display version is
`<tag>-(<NetBird version>)`, e.g. `v1.3.0-(0.79.0)`; the update check itself
uses `versionCode`.

Local packaging without CI (needs `netbird/bin/netbird-<arch>` in place,
otherwise the installer falls back to downloading at install time):

```sh
zip -r9 magisk-netbird-local.zip META-INF customize.sh module.prop service.sh \
  uninstall.sh action.sh README.md netbird system
```

## Usage

Before reboot:

```sh
su -c '/dev/netbird.service up --setup-key <KEY> --management-url <URL>'
su -c '/dev/netbird.service status'
```

After reboot:

```sh
su -c 'netbird.service up --setup-key <KEY> --management-url <URL>'
su -c 'netbird.service status'
su -c 'netbird.service log'
```

To keep the setup key out of shell history and `ps` output, prefer a file:

```sh
su -c 'echo -n <KEY> > /data/adb/netbird/setup.key && chmod 600 /data/adb/netbird/setup.key'
su -c 'netbird.service up --setup-key-file /data/adb/netbird/setup.key --management-url <URL>'
```

Inspect every peer with connection details (P2P direct vs relayed, latency,
traffic, last handshake):

```sh
su -c 'netbird.service peers'
```

In the Magisk app (v28+), the module's **ACTION** button runs `action.sh`: it
refreshes CA bundle, route rules and firewall rules, then prints status.

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
| `NB_WATCHDOG_FAILS` | `3` | Failed status probes (one per refresh cycle) before a restart. |
| `NB_WATCHDOG_MAX_RESTARTS` | `10` | Restart budget; reset after 5 healthy cycles. |

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

The status watcher re-applies both IPv4 and IPv6 Android root underlay rules every refresh cycle
(default 60s), so Wi-Fi/cellular/SIM switches no longer require a manual restart.
The same watcher probes daemon health each cycle and restarts it after 3
consecutive failed probes (watchdog: budget10 restarts, reset after5 healthy
cycles - tunable via `NB_WATCHDOG*`, disable with `NB_WATCHDOG=off`).
`netbird.service stop` (and uninstall) removes all ip rules and iptables rules
the module added.

## Dynamic status

While the daemon is running, `module.prop` is refreshed periodically. Because module descriptions are single-line metadata, status is shown as compact paired fields such as IP/peers, management/signal, relay/interface, memory, CA count, and refresh time. The peers field carries a direct/relay bracket (`[P3 R1]` = 3 direct, 1 relayed); `WD=n` shows accumulated watchdog restarts.

## Custom CA trust

For self-hosted NetBird servers with a private CA, place PEM certificates in `/data/adb/netbird/certs/` as `.crt`, `.pem`, or `.cer` files. `/data/adb/netbird/ca.crt` is also loaded automatically. Restart NetBird after changing certificates:

```sh
su -c 'netbird.service restart'
su -c '/data/adb/netbird/scripts/cert-trust.sh status'
```

The module injects `/system/etc/resolv.conf` for the Linux binary runtime. Android's normal app DNS is not changed by this; `netbird.service up` still disables NetBird DNS management with `--disable-dns`.

Direct NetBird commands should include the module daemon address:

```sh
su -c 'netbird --daemon-addr unix:///data/adb/netbird/run/netbird.sock status'
```
