## v1.4.9 — NetBird v0.81.3

- Updated the bundled official NetBird client from `0.80.0` to `0.81.3` for `x86_64`, `arm64-v8a`, and `armv7` packages, each archive SHA-256 verified against the official release checksums before packaging.
- Carries the upstream v0.81.x client changes: relayed connections in kernel mode no longer require eBPF (replaced by loopback endpoint addressing), one unreachable relay no longer churns the other relay connections, ICE session IDs survive remote restarts with fewer unnecessary reconnects, and the signal stream registration wait is bounded for faster failure detection.
- Re-created the `/dev/netbird` and `/dev/netbird.service` entry-point symlinks on every boot, so the CLI stays reachable after reboot on KernelSU without a mount metamodule (and in late-load mode), where `/dev` is wiped and the module's `system/bin` overlay is not mounted.
- On KernelSU, the dynamic module status is now also published through the `ksud module config` `override.description` key; Magisk and older managers keep reading the periodically refreshed `module.prop`.
