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

# Create /var/run/netbird via bind mount
# Android rootfs is read-only, /var may be 0-size tmpfs.
# Solution: create writable dir in /data, bind mount it over /var/run/netbird.
mkdir -p "${NB_DIR}/var/run" "${NB_DIR}/var/log" "${NB_DIR}/var/lib"
mkdir -p "${NB_DIR}/.config/netbird" /etc/netbird 2>/dev/null || true

mount --bind "${NB_DIR}/var/run" /var/run/netbird 2>/dev/null || {
  # If /var/run/netbird doesn't exist, create it first (remount rw)
  mount -o remount,rw / 2>/dev/null
  mkdir -p /var/run/netbird /var/log/netbird /var/lib/netbird 2>/dev/null
  mount -o remount,ro / 2>/dev/null
  # Now bind mount
  mount --bind "${NB_DIR}/var/run" /var/run/netbird 2>/dev/null || true
}
mount --bind "${NB_DIR}/var/log" /var/log/netbird 2>/dev/null || true
mount --bind "${NB_DIR}/var/lib" /var/lib/netbird 2>/dev/null || true

# Create /etc/resolv.conf via bind mount
if [ ! -f /etc/resolv.conf ]; then
  echo "nameserver 8.8.8.8" > "${NB_DIR}/var/resolv.conf"
  mount --bind "${NB_DIR}/var/resolv.conf" /etc/resolv.conf 2>/dev/null || {
    mount -o remount,rw / 2>/dev/null
    echo "nameserver 8.8.8.8" > /etc/resolv.conf 2>/dev/null || true
    echo "nameserver 1.1.1.1" >> /etc/resolv.conf 2>/dev/null || true
    mount -o remount,ro / 2>/dev/null
  }
fi

# Symlink config
if [ ! -f /etc/netbird/config.json ] && [ -f "${NB_DATA_DIR}/config.json" ]; then
  ln -sf "${NB_DATA_DIR}/config.json" /etc/netbird/config.json 2>/dev/null || true
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
