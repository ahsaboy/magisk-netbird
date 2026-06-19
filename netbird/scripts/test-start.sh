#!/system/bin/sh
# Quick test - Magic Mount approach for /var
NB_DIR="/data/adb/netbird"
MODPATH="/data/adb/modules_update/magisk-netbird"
export HOME="${NB_DIR}/"

echo "=== NetBird Test: Magic Mount /var ==="

# 1. Create /var structure in module's system/ directory
#    Magisk Magic Mount will overlay this onto the real filesystem
echo "[1] Creating /var in module system overlay..."
mkdir -p "${MODPATH}/system/var/run/netbird"
mkdir -p "${MODPATH}/system/var/log/netbird"
mkdir -p "${MODPATH}/system/var/lib/netbird"
mkdir -p "${MODPATH}/system/etc/netbird"

echo "    ${MODPATH}/system/var/run/netbird created"
ls -la "${MODPATH}/system/var/run/netbird/"

# 2. Check if /var already exists (might be from previous Magic Mount)
echo ""
echo "[2] Current /var status:"
ls -ld /var 2>&1 || echo "  /var does not exist"
ls -ld /var/run 2>&1 || echo "  /var/run does not exist"
ls -ld /var/run/netbird 2>&1 || echo "  /var/run/netbird does not exist"

# 3. Try to create /var via remount (might work with Magisk)
echo ""
echo "[3] Trying Magisk resetprop to disable dm-verity..."
resetprop ro.debuggable 1 2>/dev/null
mount -o remount,rw / 2>&1
if mkdir -p /var/run/netbird 2>/dev/null; then
  echo "    SUCCESS - /var/run/netbird created via remount"
  mount -o remount,ro / 2>/dev/null
else
  echo "    FAILED - /var still not writable"
  mount -o remount,ro / 2>/dev/null
fi

# 4. Alternative: symlink /var to /data/adb/netbird/var
echo ""
echo "[4] Trying symlink approach..."
mount -o remount,rw / 2>&1
if ln -sf "${NB_DIR}/var" /var 2>/dev/null; then
  echo "    Symlink /var -> ${NB_DIR}/var created"
  mount -o remount,ro / 2>/dev/null
  if [ -d /var/run/netbird ]; then
    echo "    /var/run/netbird accessible via symlink: YES"
  else
    echo "    /var/run/netbird accessible via symlink: NO"
  fi
else
  echo "    Symlink failed (rootfs still read-only)"
  mount -o remount,ro / 2>/dev/null
fi

# 5. Report
echo ""
echo "=== IMPORTANT ==="
echo "If /var still doesn't exist, you MUST REBOOT for Magic Mount to take effect."
echo "After reboot, check: ls -la /var/run/netbird/"
echo ""
echo "If that also fails, the only remaining option is:"
echo "  1. adb disable-verity && adb reboot"
echo "  2. Then remount rw and create /var"
