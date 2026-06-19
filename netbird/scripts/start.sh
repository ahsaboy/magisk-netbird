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

# ── Critical: Set HOME ──
export HOME="${NB_DIR}/"

# ── Make /var writable ──
# Android rootfs is read-only. NetBird hardcodes /var/run/netbird.sock
# and /var/log/netbird/. We must remount rootfs rw to create these.
mount -o remount,rw / 2>/dev/null || true

# Create /var/run/netbird (for gRPC socket)
# Create /var/log/netbird (for daemon logs)
for d in /var/run/netbird /var/log/netbird /var/lib/netbird; do
  if [ ! -d "$d" ]; then
    mkdir -p "$d" 2>/dev/null || true
  fi
done

# Remount rootfs back to read-only (security)
mount -o remount,ro / 2>/dev/null || true

# ── Create other required directories ──
mkdir -p "${NB_DIR}/.config/netbird" 2>/dev/null || true
mkdir -p /etc/netbird 2>/dev/null || true

# Create /etc/resolv.conf (Go DNS resolver needs it)
if [ ! -f /etc/resolv.conf ]; then
  mount -o remount,rw / 2>/dev/null || true
  cat > /etc/resolv.conf << 'RESOLV'
nameserver 8.8.8.8
nameserver 1.1.1.1
RESOLV
  mount -o remount,ro / 2>/dev/null || true
fi

# Symlink config
if [ ! -f /etc/netbird/config.json ] && [ -f "${NB_DATA_DIR}/config.json" ]; then
  mount -o remount,rw / 2>/dev/null || true
  ln -sf "${NB_DATA_DIR}/config.json" /etc/netbird/config.json 2>/dev/null || true
  mount -o remount,ro / 2>/dev/null || true
fi

# Ensure /dev/net/tun exists
if [ ! -c /dev/net/tun ]; then
  mkdir -p /dev/net 2>/dev/null || true
  mknod /dev/net/tun c 10 200 2>/dev/null || true
  chmod 0660 /dev/net/tun 2>/dev/null || true
fi

# NetBird environment
export NB_WG_KERNEL_DISABLED="${NB_WG_KERNEL_DISABLED:-true}"

# ── Start service ──
[ -x "${NB_SCRIPTS_DIR}/netbird.service" ] && \
  sh "${NB_SCRIPTS_DIR}/netbird.service" start > /dev/null 2>&1 || true

# ── Start inotifyd watcher ──
if [ -x "${NB_SCRIPTS_DIR}/netbird.inotify" ] && command -v inotifyd > /dev/null 2>&1; then
  inotifyd "${NB_SCRIPTS_DIR}/netbird.inotify" "${NB_MOD_DIR}" > /dev/null 2>&1 &
fi
