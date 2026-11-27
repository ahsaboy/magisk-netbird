## v1.5.1 — NetBird v0.83.2
- Fixed an Android DNS lifecycle race where Toybox `tr` could spin at 100% CPU if the helper exited while its `/proc/<pid>/cmdline` was being checked; stream the read through `cat` so errors become EOF and cleanup can proceed. ([PR #5](https://github.com/ahsaboy/magisk-netbird/pull/5))
- Made settings PATH setup idempotent, preventing repeated sourcing from duplicating the module and `/system/bin` entries. ([PR #5](https://github.com/ahsaboy/magisk-netbird/pull/5))
- Updated the official NetBird client to v0.83.2 for x86_64, arm64-v8a, and armv7; release packaging verifies upstream SHA-256 checksums. The client now falls back to the system hostname when the device name is empty.
- 修复 Android DNS 生命周期竞态：helper 退出时检查 `/proc/<pid>/cmdline` 可能导致 Toybox `tr` 占满单核；改为通过 `cat` 读取，使读取错误转为 EOF，避免阻塞清理。([PR #5](https://github.com/ahsaboy/magisk-netbird/pull/5))
- 将 settings.sh 中的 PATH 初始化改为幂等，避免重复 source 时反复追加模块路径和 `/system/bin`。([PR #5](https://github.com/ahsaboy/magisk-netbird/pull/5))
- 更新官方 NetBird 客户端至 v0.83.2，覆盖 x86_64、arm64-v8a 和 armv7；发布打包时校验上游 SHA-256。该版本在设备名为空时回退使用系统主机名。
