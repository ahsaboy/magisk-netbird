#!/system/bin/sh
# Quick test script - run on Android device as root
# Usage: sh /data/adb/netbird/scripts/test-start.sh

NB_DIR="/data/adb/netbird"

echo "=== NetBird Quick Test ==="

# 1. Set HOME
export HOME="${NB_DIR}/"
echo "[1] HOME=$HOME"

# 2. Create /var dirs (remount rootfs rw)
echo "[2] Creating /var/run/netbird, /var/log/netbird..."
mount -o remount,rw / 2>/dev/null
mkdir -p /var/run/netbird /var/log/netbird /var/lib/netbird /etc/netbird
mount -o remount,ro / 2>/dev/null
ls -ld /var/run/netbird /var/log/netbird 2>&1

# 3. Create other dirs
mkdir -p "${NB_DIR}/.config/netbird" /etc/netbird
echo "nameserver 8.8.8.8" > /etc/resolv.conf 2>/dev/null
[ -f /etc/resolv.conf ] && echo "[3] /etc/resolv.conf OK" || echo "[3] /etc/resolv.conf FAILED"

# 4. Check /dev/net/tun
[ -c /dev/net/tun ] && echo "[4] /dev/net/tun OK" || echo "[4] /dev/net/tun MISSING"

# 5. Test daemon start
echo "[5] Starting daemon..."
export NB_WG_KERNEL_DISABLED=true
netbird service run --log-level debug --log-file "${NB_DIR}/run/netbird.log" &
DAEMON_PID=$!
sleep 3

if kill -0 $DAEMON_PID 2>/dev/null; then
  echo "[5] Daemon running! PID=$DAEMON_PID"
  echo ""
  echo "=== SUCCESS ==="
  echo "Now run in another terminal:"
  echo "  export HOME=/data/adb/netbird/"
  echo "  netbird up --management-url https://82.156.12.252:4430 --setup-key 38B5E78D-E7EA-4D89-83D9-3F5588C132F8"
  echo ""
  echo "Or kill daemon: kill $DAEMON_PID"
else
  echo "[5] Daemon FAILED. Log:"
  cat "${NB_DIR}/run/netbird.log" 2>/dev/null | tail -20
fi
