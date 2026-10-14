#!/system/bin/sh

MODDIR=${0%/*}

while [ "$(getprop sys.boot_completed)" != 1 ]; do
  sleep 1
done

sleep 5
export NB_MOD_DIR="$MODDIR"
/data/adb/netbird/scripts/start.sh
