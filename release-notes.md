## v1.5.0 — NetBird v0.83.1
- Added opt-in Android DNS interception for the default network, with a WebUI switch and `netbird.service dns on|off|status|check`. The bundled helper sends peer, custom-zone, and match-domain queries to NetBird, and falls back to the original resolver for names NetBird does not own. DNS interception remains off by default. ([PR #4](https://github.com/ahsaboy/magisk-netbird/pull/4))
- Added IPv4/IPv6 DNS handling, VPN-aware routing, health-based fallback, and ownership-tracked firewall cleanup. Encrypted DNS and non-default networks remain outside the interception scope. ([PR #4](https://github.com/ahsaboy/magisk-netbird/pull/4))
- Updated the bundled official NetBird client to v0.83.1 for x86_64, arm64-v8a, and armv7; release packaging verifies upstream SHA-256 checksums.
- 新增默认关闭的 Android DNS 接管功能，可通过 WebUI 开关或 `netbird.service dns on|off|status|check` 控制。随包提供的 helper 会将 Peer、自定义区域和匹配域名查询交给 NetBird；NetBird 不负责的名称则回退到原解析器。([PR #4](https://github.com/ahsaboy/magisk-netbird/pull/4))
- 新增 IPv4/IPv6 DNS 处理、兼顾 VPN 的路由、健康检查回退及按归属清理防火墙规则；加密 DNS 和非默认网络不在接管范围内。([PR #4](https://github.com/ahsaboy/magisk-netbird/pull/4))
- 更新官方 NetBird 客户端至 v0.83.1，覆盖 x86_64、arm64-v8a 和 armv7；发布打包时校验上游 SHA-256。
