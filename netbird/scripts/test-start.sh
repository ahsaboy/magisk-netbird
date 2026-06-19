#!/system/bin/sh
# Quick test - fix: create dirs at symlink target
NB_DIR="/data/adb/netbird"
export HOME="${NB_DIR}/"

echo "=== NetBird Test: Symlink Fix ==="

# 1. The symlink /var -> /data/adb/netbird/var already exists from previous run.
#    Just need to create the subdirectories at the TARGET of the symlink.
echo "[1] Creating dirs at symlink target..."
mkdir -p "${NB_DIR}/var/run/netbird"
mkdir -p "${NB_DIR}/var/log/netbird"
mkdir -p "${NB_DIR}/var/lib/netbird"
mkdir -p "${NB_DIR}/.config/netbird"

# 2. Verify /var/run/netbird is accessible
echo "[2] Checking /var/run/netbird..."
if [ -d /var/run/netbird ] && [ -w /var/run/netbird ]; then
  echo "    /var/run/netbird: EXISTS and WRITABLE"
else
  echo "    /var/run/netbird: NOT accessible"
  echo "    Symlink status:"
  ls -la /var 2>&1
  echo "    Creating symlink if missing..."
  mount -o remount,rw / 2>&1
  ln -sf "${NB_DIR}/var" /var 2>/dev/null
  mount -o remount,ro / 2>&1
fi

# 3. resolv.conf
echo "[3] DNS..."
echo "nameserver 8.8.8.8" > "${NB_DIR}/var/resolv.conf"
echo "nameserver 1.1.1.1" >> "${NB_DIR}/var/resolv.conf"
# Try mounting it
mount --bind "${NB_DIR}/var/resolv.conf" /etc/resolv.conf 2>/dev/null || {
  # /etc might also be read-only, use symlink
  mount -o remount,rw / 2>&1
  ln -sf "${NB_DIR}/var/resolv.conf" /etc/resolv.conf 2>/dev/null || true
  mount -o remount,ro / 2>&1
}
[ -f /etc/resolv.conf ] && echo "    /etc/resolv.conf: OK" || echo "    /etc/resolv.conf: MISSING"

# 4. TUN
[ -c /dev/net/tun ] && echo "[4] /dev/net/tun OK" || echo "[4] /dev/net/tun MISSING"

# 5. Start daemon
echo "[5] Starting daemon..."
export NB_WG_KERNEL_DISABLED=true
netbird service run --log-level debug --log-file "${NB_DIR}/run/netbird.log" &
PID=$!
sleep 3

if kill -0 $PID 2>/dev/null; then
  echo "    Daemon running PID=$PID"
  echo ""
  echo "=== SUCCESS ==="
  echo "Run in another terminal:"
  echo "  export HOME=/data/adb/netbird/"
  echo "  netbird up --management-url https://82.156.12.252:4430 --setup-key 38B5E78D-E7EA-4D89-83D9-3F5588C132F8"
else
  echo "    Daemon FAILED. Log:"
  tail -20 "${NB_DIR}/run/netbird.log" 2>/dev/null
fi
