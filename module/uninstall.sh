#!/system/bin/sh

# stop also removes the module's ip rules and iptables ICMP rules.
/data/adb/netbird/scripts/netbird.service stop >/dev/null 2>&1 || true
rm -f /dev/netbird /dev/netbird.service
rm -rf /data/adb/netbird
