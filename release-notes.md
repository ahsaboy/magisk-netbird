## v1.4.8 — NetBird v0.80.0

- Renamed the per-architecture update manifests from `update/` to `updates/` because KernelSU reserves `update` as the pending-update marker.
- Removed the legacy `update/` directory during upgrades so KernelSU does not leave the module in a pending state.
- **Installation recovery (EN):** If installation fails, uninstall the module, back up `/data/adb/netbird/config.json` if it exists, and then install the module again.
- **安装恢复（中文）：** 如果安装失败，请先卸载模块；如存在，请备份 `/data/adb/netbird/config.json`，然后重新安装模块。
