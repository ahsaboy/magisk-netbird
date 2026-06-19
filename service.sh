#!/system/bin/sh
# @title Magisk NetBird - Service Entry Point
# @description Boot-time service entry point. Waits for boot completion,
#              then delegates to start.sh for actual service startup.

# Wait for system boot to complete (with 120s timeout)
count=0
while [ "$(getprop sys.boot_completed)" != 1 ] && [ "${count}" -lt 120 ]; do
  sleep 1
  count=$((count + 1))
done

if [ "${count}" -ge 120 ]; then
  echo "NetBird: boot wait timed out after 120s" >&2
fi

# Wait for network to stabilize
sleep 5

# Delegate to start.sh
NB_SCRIPTS_DIR="/data/adb/netbird/scripts"
if [ -x "${NB_SCRIPTS_DIR}/start.sh" ]; then
  exec sh "${NB_SCRIPTS_DIR}/start.sh" boot
else
  echo "NetBird: start.sh not found at ${NB_SCRIPTS_DIR}/start.sh" >&2
fi
