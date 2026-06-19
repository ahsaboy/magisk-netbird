#!/system/bin/sh
# Quick test - run on Android as root
NB_DIR="/data/adb/netbird"
export HOME="${NB_DIR}/"

echo "=== NetBird Quick Test ==="

# 1. Create writable backing dirs
echo "[1] Creating backing dirs..."
mkdir -p "${NB_DIR}/var/run" "${NB_DIR}/var/log" "${NB_DIR}/var/lib" "${NB_DIR}/.config/netbird"

# 2. Bind mount over /var/run/netbird (bypass read-only rootfs)
echo "[2] Bind mounting /var/run/netbird..."
mount --bind "${NB_DIR}/var/run" /var/run/netbird 2>/dev/null || {
  echo "    Bind mount failed, trying remount rw first..."
  mount -o remount,rw / 2>/dev/null
  mkdir -p /var/run/netbird /var/log/netbird /var/lib/netbird 2>/dev/null
  mount -o remount,ro / 2>/dev/null
  mount --bind "${NB_DIR}/var/run" /var/run/netbird 2>/dev/null
}
mount --bind "${NB_DIR}/var/log" /var/log/netbird 2>/dev/null || true
mount --bind "${NB_DIR}/var/lib" /var/lib/netbird 2>/dev/null || true

# Verify
if [ -d /var/run/netbird ] && [ -w /var/run/netbird ]; then
  echo "    /var/run/netbird: writable OK"
else
  echo "    /var/run/netbird: STILL NOT WRITABLE"
  echo "    Trying direct remount approach..."
  mount -o remount,rw / 2>/dev/null
  mkdir -p /var/run/netbird 2>&1
  mount -o remount,ro / 2>/dev/null
fi

# 3. resolv.conf
echo "[3] Creating /etc/resolv.conf..."
echo "nameserver 8.8.8.8" > "${NB_DIR}/var/resolv.conf"
mount --bind "${NB_DIR}/var/resolv.conf" /etc/resolv.conf 2>/dev/null || {
  mount -o remount,rw / 2>/dev/null
  echo "nameserver 8.8.8.8" > /etc/resolv.conf 2>/dev/null
  mount -o remount,ro / 2>/dev/null
}
[ -f /etc/resolv.conf ] && echo "    OK" || echo "    FAILED"

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
  echo "    Daemon FAILED. Last 20 lines of log:"
  tail -20 "${NB_DIR}/run/netbird.log" 2>/dev/null
fi
