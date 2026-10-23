#!/system/bin/sh

MODDIR=${0%/*}

while [ "$(getprop sys.boot_completed)" != 1 ]; do
  sleep 1
done

sleep 5
# /dev is tmpfs and is wiped on every boot. Re-create the entry-point symlinks
# so `netbird.service` stays reachable even when the module's system/bin
# overlay is not mounted (KernelSU without a mount metamodule, or late-load).
NB_BIN="/data/adb/netbird/bin/netbird"
NB_SVC="/data/adb/netbird/scripts/netbird.service"
[ -x "$NB_BIN" ] && ln -sf "$NB_BIN" /dev/netbird
[ -x "$NB_SVC" ] && ln -sf "$NB_SVC" /dev/netbird.service
export NB_MOD_DIR="$MODDIR"
/data/adb/netbird/scripts/start.sh
