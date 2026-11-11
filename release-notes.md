## v1.4.13 — NetBird v0.82.1
- Updated the official NetBird client to v0.82.1 for x86_64, arm64-v8a, and armv7; release packaging verifies upstream SHA-256 checksums.
- Hardened SSH authentication and lifecycle handling: reject username changes during JWT authentication, close handshakes and unauthorized sessions, run SFTP through `su`, and default SSH off for stored configs without a peer key.
- Fixed userspace firewall handling of unspecified local addresses, prevented forwarded traffic from exiting its ingress interface, and corrected nftables peer-protocol matching behind IPv6 extension headers.
- Removed peers from the interface when they leave the network map and their lazy connection is idle.
- 更新官方 NetBird 客户端至 v0.82.1，覆盖 x86_64、arm64-v8a 和 armv7；发布时校验上游 SHA-256。
- 加固 SSH 认证与会话管理：拒绝 JWT 认证期间变更用户名，关闭握手中及已失去授权的会话，SFTP 通过 `su` 启动；缺少 peer key 的旧配置默认关闭 SSH。
- 修正用户态防火墙对未指定本地地址的识别，阻止转发流量从入站接口原路发出，并修复 IPv6 扩展头后的 nftables peer 协议匹配。
- peer 离开 network map 且 lazy connection 空闲时，从接口移除该 peer。
