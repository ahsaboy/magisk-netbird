#!/system/bin/sh
# @title Magisk NetBird - Install Script

# shellcheck disable=SC2034
SKIPUNZIP=1

NB_DIR="/data/adb/netbird"
NB_BIN_DIR="${NB_DIR}/bin"
NB_SCRIPTS_DIR="${NB_DIR}/scripts"
NB_RUN_DIR="${NB_DIR}/run"
NB_DATA_DIR="${NB_DIR}/data"
NB_BACKUP_DIR="${NB_DIR}/backups"

# ── Version (update this when NetBird releases a new version) ──
NB_VERSION="0.73.0"

# ── Guard: require Manager install ──
if [ "${BOOTMODE:-}" != true ]; then
  abort "! Please install from Magisk Manager or KernelSU Manager"
fi

ui_print "- Magisk NetBird (NetBird v${NB_VERSION})"
ui_print "- Architecture: ${ARCH}"

# ── Arch mapping (matches NetBird release naming) ──
case "${ARCH}" in
  arm)   F_ARCH="armv6"  ;;
  arm64) F_ARCH="arm64"  ;;
  x86)   F_ARCH="386"    ;;
  x64)   F_ARCH="amd64"  ;;
  *)     abort "! Unsupported architecture: ${ARCH}" ;;
esac

# ── Backup existing data ──
if [ -d "${NB_DIR}" ]; then
  ui_print "- Backing up existing data..."
  mkdir -p "${NB_BACKUP_DIR}"
  cp -rp "${NB_DATA_DIR}" "${NB_BACKUP_DIR}/$(date +%Y%m%d%H%M%S)/" 2>/dev/null || \
    ui_print "  Warning: backup failed"
fi

# ── Create directories ──
ui_print "- Creating directories..."
for d in "${NB_DIR}" "${NB_BIN_DIR}" "${NB_SCRIPTS_DIR}" "${NB_RUN_DIR}" \
         "${NB_DATA_DIR}" "${NB_BACKUP_DIR}" "${MODPATH}/system/bin" /data/adb/service.d; do
  mkdir -p "$d"
done

# Create /var dirs (Android rootfs may be read-only, try remount)
mount -o remount,rw / 2>/dev/null || true
for d in /var/run/netbird /var/log/netbird /var/lib/netbird /etc/netbird; do
  mkdir -p "$d" 2>/dev/null || true
done
mount -o remount,ro / 2>/dev/null || true

# ── Install netbird binary ──
# Try bundled binary first, fall back to download
ui_print "- Installing netbird binary..."
if unzip -qqjo "$ZIPFILE" "netbird/bin/netbird-${F_ARCH}" -d "${TMPDIR}" 2>/dev/null; then
  mv -f "${TMPDIR}/netbird-${F_ARCH}" "${NB_BIN_DIR}/netbird"
  chmod 0755 "${NB_BIN_DIR}/netbird"
  ui_print "  - netbird binary: bundled"
else
  ui_print "  - netbird binary: not bundled, downloading..."
  TARBALL="netbird_${NB_VERSION}_linux_${F_ARCH}.tar.gz"
  DOWNLOAD_URL="https://github.com/netbirdio/netbird/releases/download/v${NB_VERSION}/${TARBALL}"

  wget --no-check-certificate --timeout=120 -qO "${TMPDIR}/${TARBALL}" "${DOWNLOAD_URL}" 2>&1 || {
    ui_print "  wget failed, trying curl..."
    curl -fSL --connect-timeout 30 -o "${TMPDIR}/${TARBALL}" "${DOWNLOAD_URL}" 2>&1 || {
      abort "! Failed to download: ${DOWNLOAD_URL}"
    }
  }

  ui_print "  Extracting..."
  tar -xzf "${TMPDIR}/${TARBALL}" -C "${TMPDIR}" || abort "! Failed to extract tarball"

  NB_BIN=$(find "${TMPDIR}" -maxdepth 2 -name "netbird" -type f 2>/dev/null | head -1)
  [ -z "${NB_BIN}" ] && abort "! netbird binary not found in tarball"
  mv -f "${NB_BIN}" "${NB_BIN_DIR}/netbird"
  chmod 0755 "${NB_BIN_DIR}/netbird"
  ui_print "  - netbird binary: downloaded"
fi

# ── Install scripts (essential - abort on failure) ──
ui_print "- Installing scripts..."
unzip -qqjo "$ZIPFILE" 'netbird/scripts/*' -d "${NB_SCRIPTS_DIR}" || \
  abort "! Failed to extract scripts"
unzip -qqjo "$ZIPFILE" 'netbird/settings.sh' -d "${NB_DIR}" || \
  abort "! Failed to extract settings.sh"

# ── Default config ──
if [ ! -f "${NB_DATA_DIR}/config.json" ]; then
  cat > "${NB_DATA_DIR}/config.json" << 'EOF'
{
  "ManagementUrl": "https://api.netbird.io",
  "AdminURL": "https://app.netbird.io",
  "SetupKey": "",
  "PreSharedKey": "",
  "DisableAutoConnect": false,
  "DisableDNS": false,
  "DisableFirewall": false,
  "ServerSSHAllowed": true,
  "EnableSSHServer": true
}
EOF
fi

# ── Symlinks ──
ui_print "- Creating symlinks..."
ln -sf "${NB_BIN_DIR}/netbird" "${MODPATH}/system/bin/netbird"
ln -sf "${NB_SCRIPTS_DIR}/netbird.service" "${MODPATH}/system/bin/netbird.service"

# ── Permissions ──
ui_print "- Setting permissions..."
set_perm_recursive "${NB_BIN_DIR}"         0 0 0755 0755 "u:object_r:system_file:s0"
set_perm_recursive "${NB_SCRIPTS_DIR}"     0 0 0755 0755 "u:object_r:system_file:s0"
set_perm_recursive "${MODPATH}/system/bin" 0 0 0755 0755 "u:object_r:system_file:s0"
set_perm "${NB_DIR}/settings.sh"           0 0 0755 "u:object_r:system_file:s0"
set_perm "${MODPATH}/service.sh"           0 0 0755 "u:object_r:system_file:s0"

# ── Move service.sh to general scripts ──
ui_print "- Move service.sh to General Scripts? (default: Yes in 10s)"
ui_print "  [ Vol UP: Yes ] [ Vol DOWN: No ]"
start_time=$(date +%s)
while true; do
  [ $(($(date +%s) - start_time)) -ge 10 ] && {
    ui_print "  -> Yes (timeout)"
    mv -f "${MODPATH}/service.sh" /data/adb/service.d/magisk_netbird_service.sh
    break
  }
  getevent -lc 1 2>&1 | grep KEY_VOLUME > "${TMPDIR}/events" 2>/dev/null || true
  grep -q KEY_VOLUMEUP "${TMPDIR}/events" 2>/dev/null && {
    ui_print "  -> Yes"
    mv -f "${MODPATH}/service.sh" /data/adb/service.d/magisk_netbird_service.sh
    break
  }
  grep -q KEY_VOLUMEDOWN "${TMPDIR}/events" 2>/dev/null && {
    ui_print "  -> No"
    break
  }
  sleep 1
done

# ── Done ──
ui_print ""
ui_print "-----------------------------------------------------------"
ui_print " Magisk NetBird (NetBird v${NB_VERSION}) Installed!"
ui_print "-----------------------------------------------------------"
ui_print ""
ui_print " 1. Reboot your device"
ui_print " 2. Connect:"
ui_print "    su -c 'netbird up --setup-key <KEY>'"
ui_print " 3. Status:"
ui_print "    su -c 'netbird.service status'"
ui_print ""
ui_print " Data: /data/adb/netbird/"
ui_print "-----------------------------------------------------------"
