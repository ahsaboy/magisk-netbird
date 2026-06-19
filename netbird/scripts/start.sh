#!/system/bin/sh
# @title Magisk NetBird - Boot Orchestrator

NB_DIR="/data/adb/netbird"
NB_SCRIPTS_DIR="${NB_DIR}/scripts"
NB_MOD_DIR="${NB_MOD_DIR:-/data/adb/modules/magisk-netbird}"
NB_RUN_DIR="${NB_DIR}/run"
NB_DATA_DIR="${NB_DIR}/data"

# ── Post-install mode ──
case "${1:-boot}" in
  postinstall)
    rm -rf "${NB_RUN_DIR}" && mkdir -p "${NB_RUN_DIR}"
    [ -x "${NB_SCRIPTS_DIR}/netbird.service" ] && \
      sh "${NB_SCRIPTS_DIR}/netbird.service" restart > /dev/null 2>&1 &
    exit 0
    ;;
esac

# ── Boot mode ──
mkdir -p "${NB_RUN_DIR}" 2>/dev/null || true

# Check if module is disabled
[ -f "${NB_MOD_DIR}/disable" ] && exit 0

# ── Android environment setup ──
# Create /etc/resolv.conf (Android doesn't have it, Go DNS resolver needs it)
if [ ! -f /etc/resolv.conf ]; then
  mkdir -p /etc 2>/dev/null || true
  cat > /etc/resolv.conf << 'RESOLV'
nameserver 8.8.8.8
nameserver 1.1.1.1
nameserver 2001:4860:4860::8888
RESOLV
fi

# Create NetBird's default Linux directories (hardcoded in binary)
mkdir -p /etc/netbird 2>/dev/null || true
mkdir -p /var/lib/netbird 2>/dev/null || true
mkdir -p /var/log/netbird 2>/dev/null || true
mkdir -p /var/run/netbird 2>/dev/null || true

# Symlink config if /etc/netbird/config.json doesn't exist
if [ ! -f /etc/netbird/config.json ] && [ -f "${NB_DATA_DIR}/config.json" ]; then
  ln -sf "${NB_DATA_DIR}/config.json" /etc/netbird/config.json
fi

# Ensure /dev/net/tun exists
if [ ! -c /dev/net/tun ]; then
  mkdir -p /dev/net 2>/dev/null || true
  mknod /dev/net/tun c 10 200 2>/dev/null || true
  chmod 0660 /dev/net/tun 2>/dev/null || true
fi

# Set environment for NetBird daemon
# NB_WG_KERNEL_DISABLED=true: use userspace WireGuard if kernel module not available
export NB_WG_KERNEL_DISABLED="${NB_WG_KERNEL_DISABLED:-true}"

# ── Start service ──
[ -x "${NB_SCRIPTS_DIR}/netbird.service" ] && \
  sh "${NB_SCRIPTS_DIR}/netbird.service" start > /dev/null 2>&1 || true

# ── Start inotifyd watcher ──
if [ -x "${NB_SCRIPTS_DIR}/netbird.inotify" ] && command -v inotifyd > /dev/null 2>&1; then
  inotifyd "${NB_SCRIPTS_DIR}/netbird.inotify" "${NB_MOD_DIR}" > /dev/null 2>&1 &
fi
