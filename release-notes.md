## v1.4.12 — NetBird v0.82.0
- Updated the official NetBird client to v0.82.0 for x86_64, arm64-v8a, and armv7; release packaging verifies upstream SHA-256 checksums.
- Fixed Android underlay routing to match NetBird's fwmark, preserving tethered traffic instead of matching every UID 0 packet.
- Compact peer rows and paginated automation history; redesigned automation rules with stable ordering, search/filters, editing, and execution details.
- NetBird updates since v0.81.4 include safer SSH session handling (v0.81.5), more stable HA route selection, `status --table`, and Rosenpass deprecation (v0.82.0).
- 更新 NetBird 官方客户端至 v0.82.0，覆盖 x86_64、arm64-v8a 和 armv7；发布打包时校验上游 SHA-256。
- 修正 Android 下层路由规则，改为匹配 NetBird fwmark，避免 UID 0 规则错误影响热点转发流量。
- 精简 Peer 列表并为自动化历史分页；重做规则界面，支持稳定顺序、搜索筛选、编辑和执行详情。
- NetBird 自 v0.81.4 后的更新包括加固 SSH 会话（v0.81.5）、提升 HA 路由稳定性、新增 `status --table` 及弃用 Rosenpass（v0.82.0）。
