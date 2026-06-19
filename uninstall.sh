#!/system/bin/sh
# @title Magisk NetBird - Uninstall

NB_DIR="/data/adb/netbird"
NB_SCRIPTS_DIR="${NB_DIR}/scripts"
NB_PID_FILE="${NB_DIR}/run/netbird.pid"

# Stop daemon
if [ -x "${NB_SCRIPTS_DIR}/netbird.service" ]; then
  sh "${NB_SCRIPTS_DIR}/netbird.service" stop 2>/dev/null || true
fi

# Kill any remaining processes
for pid in $(ps -A 2>/dev/null | grep netbird | grep -v grep | awk '{print $2}'); do
  kill -9 "${pid}" 2>/dev/null || true
done

# Kill inotifyd watchers
for pid in $(ps -A 2>/dev/null | grep inotifyd | grep -v grep | awk '{print $2}'); do
  cat "/proc/${pid}/cmdline" 2>/dev/null | tr '\0' ' ' | grep -q "netbird.inotify" && \
    kill -9 "${pid}" 2>/dev/null || true
done

# Clean up service.d script
rm -f /data/adb/service.d/magisk_netbird_service.sh 2>/dev/null || true

# /data/adb/netbird/ is preserved (user data)
