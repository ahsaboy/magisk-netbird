#!/system/bin/sh
# Quick test - run on Android as root
NB_DIR="/data/adb/netbird"
export HOME="${NB_DIR}/"

echo "=== NetBird Quick Test ==="

# 1. Create backing dirs in writable location
mkdir -p "${NB_DIR}/var/run" "${NB_DIR}/var/log" "${NB_DIR}/var/lib" "${NB_DIR}/.config/netbird"

# 2. Mount fresh tmpfs on /var/run/netbird
#    /var is a 0-size read-only tmpfs, but we can mount ON TOP of a path.
echo "[1] Mounting tmpfs on /var/run/netbird..."
mount -t tmpfs -o size=1M tmpfs /var/run/netbird 2>&1
mount -t tmpfs -o size=1M tmpfs /var/log/netbird 2>&1
mount -t tmpfs -o size=1M tmpfs /var/lib/netbird 2>&1

# Verify
if mount | grep -q "tmpfs on /var/run/netbird"; then
  echo "    /var/run/netbird: tmpfs mounted OK"
  ls -ld /var/run/netbird
else
  echo "    tmpfs mount FAILED"
fi

# 3. resolv.conf - mount tmpfs on /etc if needed, or write to /data
echo "[2] Setting up DNS..."
mount -t tmpfs -o size=64K tmpfs /tmp/nb-etc 2>/dev/null
echo "nameserver 8.8.8.8" > /tmp/nb-etc/resolv.conf 2>/dev/null
mount --bind /tmp/nb-etc/resolv.conf /etc/resolv.conf 2>/dev/null || {
  echo "    /etc/resolv.conf bind mount failed, trying direct write..."
  # Try writing to /data and telling Go to use it
  echo "nameserver 8.8.8.8" > "${NB_DIR}/resolv.conf"
  echo "    Created ${NB_DIR}/resolv.conf as fallback"
}
[ -f /etc/resolv.conf ] && echo "    /etc/resolv.conf: OK" || echo "    /etc/resolv.conf: MISSING"

# 4. TUN
[ -c /dev/net/tun ] && echo "[3] /dev/net/tun OK" || echo "[3] /dev/net/tun MISSING"

# 5. Start daemon
echo "[4] Starting daemon..."
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
