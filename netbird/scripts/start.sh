#!/system/bin/sh
# @title Magisk NetBird - Boot Orchestrator

NB_DIR="/data/adb/netbird"
NB_SCRIPTS_DIR="${NB_DIR}/scripts"
NB_MOD_DIR="${NB_MOD_DIR:-/data/adb/modules/magisk-netbird}"
NB_RUN_DIR="${NB_DIR}/run"

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

# Create /etc/resolv.conf (required by NetBird DNS initialization)
# Android rootfs is read-only, use tmpfs mount
if [ ! -f /etc/resolv.conf ]; then
  mkdir -p /tmp/nb-etc 2>/dev/null || true
  echo "nameserver 8.8.8.8" > /tmp/nb-etc/resolv.conf
  mount --bind /tmp/nb-etc/resolv.conf /etc/resolv.conf 2>/dev/null || {
    # Fallback: mount tmpfs on /etc/resolv.conf path
    mount -t tmpfs -o size=4K tmpfs /tmp/nb-resolv 2>/dev/null || true
    echo "nameserver 8.8.8.8" > /tmp/nb-resolv/resolv.conf 2>/dev/null || true
    mount --bind /tmp/nb-resolv/resolv.conf /etc/resolv.conf 2>/dev/null || true
  }
fi

# Create /etc/os-release (non-fatal warning but good to have)
if [ ! -f /etc/os-release ]; then
  echo 'NAME="Android"' > /tmp/nb-etc/os-release 2>/dev/null || true
  mount --bind /tmp/nb-etc/os-release /etc/os-release 2>/dev/null || true
fi

# Trust custom CA certificate if provided
[ -f "${NB_DIR}/ca.crt" ] && export SSL_CERT_FILE="${NB_DIR}/ca.crt"

# Ensure /dev/net/tun exists
if [ ! -c /dev/net/tun ]; then
  mkdir -p /dev/net 2>/dev/null || true
  mknod /dev/net/tun c 10 200 2>/dev/null || true
  chmod 0660 /dev/net/tun 2>/dev/null || true
fi

# Start service
[ -x "${NB_SCRIPTS_DIR}/netbird.service" ] && \
  sh "${NB_SCRIPTS_DIR}/netbird.service" start > /dev/null 2>&1 || true

# Start inotifyd watcher
if [ -x "${NB_SCRIPTS_DIR}/netbird.inotify" ] && command -v inotifyd > /dev/null 2>&1; then
  inotifyd "${NB_SCRIPTS_DIR}/netbird.inotify" "${NB_MOD_DIR}" > /dev/null 2>&1 &
fi
