#!/system/bin/sh
# @title Magisk NetBird - Boot Orchestrator

NB_DIR="/data/adb/netbird"
NB_SCRIPTS_DIR="${NB_DIR}/scripts"
NB_MOD_DIR="${NB_MOD_DIR:-/data/adb/modules/magisk-netbird}"
NB_RUN_DIR="${NB_DIR}/run"
NB_DATA_DIR="${NB_DIR}/data"

# Post-install mode
case "${1:-boot}" in
  postinstall)
    rm -rf "${NB_RUN_DIR}" && mkdir -p "${NB_RUN_DIR}"
    [ -x "${NB_SCRIPTS_DIR}/netbird.service" ] && \
      sh "${NB_SCRIPTS_DIR}/netbird.service" restart > /dev/null 2>&1 &
    exit 0
    ;;
esac

# Boot mode
mkdir -p "${NB_RUN_DIR}" 2>/dev/null || true
[ -f "${NB_MOD_DIR}/disable" ] && exit 0

# Critical: Set HOME for Go binary
export HOME="${NB_DIR}/"

# Create backing dirs in writable /data
mkdir -p "${NB_DIR}/var/run" "${NB_DIR}/var/log" "${NB_DIR}/var/lib" "${NB_DIR}/.config/netbird"

# Mount tmpfs on /var/run/netbird (Android /var is 0-size read-only tmpfs)
# This gives NetBird a writable socket directory without modifying rootfs
mount -t tmpfs -o size=1M tmpfs /var/run/netbird 2>/dev/null || true
mount -t tmpfs -o size=1M tmpfs /var/log/netbird 2>/dev/null || true
mount -t tmpfs -o size=1M tmpfs /var/lib/netbird 2>/dev/null || true

# Create /etc/netbird (may also be read-only)
mkdir -p /etc/netbird 2>/dev/null || true

# Symlink config
if [ ! -f /etc/netbird/config.json ] && [ -f "${NB_DATA_DIR}/config.json" ]; then
  ln -sf "${NB_DATA_DIR}/config.json" /etc/netbird/config.json 2>/dev/null || true
fi

# Create /etc/resolv.conf via tmpfs + bind mount
if [ ! -f /etc/resolv.conf ]; then
  mkdir -p /tmp/nb-etc 2>/dev/null || true
  echo "nameserver 8.8.8.8" > /tmp/nb-etc/resolv.conf
  mount --bind /tmp/nb-etc/resolv.conf /etc/resolv.conf 2>/dev/null || true
fi

# Ensure /dev/net/tun exists
if [ ! -c /dev/net/tun ]; then
  mkdir -p /dev/net 2>/dev/null || true
  mknod /dev/net/tun c 10 200 2>/dev/null || true
  chmod 0660 /dev/net/tun 2>/dev/null || true
fi

# NetBird environment
export NB_WG_KERNEL_DISABLED="${NB_WG_KERNEL_DISABLED:-true}"

# Start service
[ -x "${NB_SCRIPTS_DIR}/netbird.service" ] && \
  sh "${NB_SCRIPTS_DIR}/netbird.service" start > /dev/null 2>&1 || true

# Start inotifyd watcher
if [ -x "${NB_SCRIPTS_DIR}/netbird.inotify" ] && command -v inotifyd > /dev/null 2>&1; then
  inotifyd "${NB_SCRIPTS_DIR}/netbird.inotify" "${NB_MOD_DIR}" > /dev/null 2>&1 &
fi
