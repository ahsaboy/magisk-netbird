# Changelog

## v1.4.11 — NetBird v0.81.4
- Added scheduled connect/disconnect rules with priorities and a persistent execution journal.
- Kept the daemon watcher independent from connection state, with 30-second heartbeats and 30/300-second status probes.
- Updated the official NetBird client to v0.81.4 and improved WebUI feedback and mobile behavior.

## v1.4.9 — NetBird v0.81.3

- Updated the bundled official NetBird client from `0.80.0` to `0.81.3` for `x86_64`, `arm64-v8a`, and `armv7` packages, each archive SHA-256 verified against the official release checksums before packaging.
- Carries the upstream v0.81.x client changes: relayed connections in kernel mode no longer require eBPF (replaced by loopback endpoint addressing), one unreachable relay no longer churns the other relay connections, ICE session IDs survive remote restarts with fewer unnecessary reconnects, and the signal stream registration wait is bounded for faster failure detection.
- Re-created the `/dev/netbird` and `/dev/netbird.service` entry-point symlinks on every boot, so the CLI stays reachable after reboot on KernelSU without a mount metamodule (and in late-load mode), where `/dev` is wiped and the module's `system/bin` overlay is not mounted.
- On KernelSU, the dynamic module status is now also published through the `ksud module config` `override.description` key; Magisk and older managers keep reading the periodically refreshed `module.prop`.

## v1.4.8 — NetBird v0.80.0

- Renamed the per-architecture update manifests from `update/` to `updates/` because KernelSU reserves `update` as the pending-update marker.
- Removed the legacy `update/` directory during upgrades so KernelSU does not leave the module in a pending state.
- **Installation recovery (EN):** If installation fails, uninstall the module, back up `/data/adb/netbird/config.json` if it exists, and then install the module again.
- **安装恢复（中文）：** 如果安装失败，请先卸载模块；如存在，请备份 `/data/adb/netbird/config.json`，然后重新安装模块。

## v1.4.7 — NetBird v0.80.0

- Adapted packaging to the KernelSU Modules repository layout and publish one validated universal ZIP for arm64-v8a, armv7, and x86_64.
- Preserved the root update manifest for legacy installs and extended release version parsing to accept prerelease tags.
- Prevented stale diagnostic responses from replacing newer results; forwarding failures now show an error and retry state.

## v1.4.6 — NetBird v0.80.0

- Moved daemon start/stop selection to the module ACTION button with bilingual Volume Up/Down prompts, keeping the WebUI read-only for daemon lifecycle operations.
- Fixed watchdog BusyBox detection and documented the WebUI cgroup workaround.

## v1.4.5 — NetBird v0.80.0

- Streamlined the mobile WebUI with parsed route domains/resolved IPs, automatic peer traffic units, bilingual controls, quieter visuals, and disabled global overscroll stretch.
- Added five-second refresh cooldowns when switching Peers and Networks, while keeping immediate view changes and silent data refreshes.
- Removed Debug actions and the test-only repository directory from the release tree; Network selection controls are integrated into the main Networks card.

## v1.4.4 — NetBird v0.80.0

- Fixed deselection of Network/Route IDs that begin with a dot, such as `.nb.test`.
- Disabled the WebUI page's global overscroll stretch effect while preserving normal scrolling.
- Added regression coverage for Network ID validation and the structured status/Network parsers.

## v1.4.3 — NetBird v0.80.0

- Reworked the KernelSU WebUI into a mobile-first control panel with structured status, peer, network, forwarding, health, profile, state, version, and configuration views.
- Removed the raw log/output panel and replaced command output with parsed cards, lists, badges, empty states, and actionable error messages.
- Added fixed WebUI service actions for Network/Routes selection, health checks, profiles, and stored-state inspection.
- Corrected nested NetBird status JSON parsing for daemon, management, signal, and peer counts; all start controls now require confirmation.
- Fixed Network/Route IDs that begin with a dot, such as `.nb.test`, being rejected when deselecting a route.

## v1.4.2 — NetBird v0.80.0

- Added a KernelSU WebUI control panel with status, start, stop, restart, peers, bounded logs, version, route refresh, and runtime refresh actions.
- Kept the no-argument ACTION entry compatible while adding fixed, validated action dispatch through `action.sh` and `netbird.service`.
- Added `log --once` for non-blocking manager output and propagated route, firewall, CA, daemon, watcher, and cleanup failures through service exit codes.
- Packaged the WebUI in local and GitHub Actions release archives and documented the KernelSU interaction model.

## v1.4.1 — NetBird v0.80.0

- Completed Android IPv4/IPv6 overlay route precedence handling and re-applied root underlay route rules for both families during network changes.
- Added safer Android route-table detection and stale module-rule cleanup across Wi-Fi, cellular, and multi-network configurations.
- Added an automatic userspace firewall and userspace WireGuard fallback for Android kernels without a usable IPv6 `ip6tables` `nat` table, with `NB_FORCE_USERSPACE_FIREWALL` and `NB_WG_KERNEL_DISABLED` overrides.
- Clarified that `NB_DISABLE_IPV6` disables NetBird overlay IPv6 and is not a firewall compatibility workaround.

## v1.4.0 — NetBird v0.80.0

- Updated the bundled official NetBird client from `0.79.0` to `0.80.0` for `x86_64`, `arm64-v8a`, and `armv7` packages. The armv7 package continues to use NetBird's official `linux/armv6` build, which is compatible with the supported 32-bit ARM devices.
- Kept release integrity checks in place: each architecture archive is downloaded from NetBird's official release and verified against its published SHA-256 checksum before packaging.
- Carries the upstream v0.80.0 client fixes for relay disconnect peer notifications, larger daemon IPC responses (up to 16 MiB), safer HTTPS install-script downloads, and Windows service/IPC hardening. Server-side v0.80.0 changes are intentionally not described as module features because this project only bundles the client binary.
- Refreshed the per-architecture Magisk update manifests and legacy arm64 manifest to advertise `v1.4.0-(0.80.0)`.

## v1.3.0 (2026-09-22) — NetBird v0.79.0

- Added a daemon watchdog with configurable consecutive-failure and restart limits, plus a peers/status view for the Magisk module status page.
- Added persistent `.env` configuration for module settings and a configurable NetBird client log-rotation cap, including safer defaults for Android's read-only filesystem layout.
- Fixed stale watcher cleanup, narrowed daemon process matching, escalated failed watcher stops from `TERM` to `KILL`, and corrected watchdog state markers and service-log timestamps.

## v1.2.0 (2026-09-22) — NetBird v0.79.0

- Rebuilt release pipeline: three official-binary builds (`x86_64` / `arm64-v8a` / `armv7`), packaged by GitHub Actions with sha256-verified downloads from the official NetBird releases.
- NetBird 0.74.2 → 0.79.0.
- In-app update banner: install-time per-architecture `updateJson` manifests (`updates/update-*.json`), refreshed on every release.
- Fixes: upgrades now replace the bundled binary; `stop` removes all iptables/ip rules the module added; route rules compare route-table id vs name correctly (no more delete/re-add churn); dynamic `module.prop` description is kept on both the active and staged module directories; added `action.sh` (Magisk v28+ ACTION button).
- Settings: `NB_DISABLE_SSH_CONFIG`, `NB_SKIP_NFTABLES_CHECK`, `NB_SKIP_DNS_PROBE`, `NB_NETWORK_MONITOR`, `NB_STATE_DIR`; opt-in `NB_DISABLE_IPV6` / `NB_DISABLE_FIREWALL`.
- Legacy v1.0.x installs keep working: the root `update.json` now points at the arm64-v8a zip. Re-login may be required after upgrading from the old line.
