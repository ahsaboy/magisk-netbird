#!/bin/sh
set -eu

[ "${NETBIRD_DEVICE_TESTS:-}" = 1 ] || {
  echo 'Set NETBIRD_DEVICE_TESTS=1 to enable disruptive DNS lifecycle tests.' >&2
  exit 2
}
command -v adb >/dev/null 2>&1 || exit 2
dns_local_script="$(mktemp)"
trap 'rm -f "$dns_local_script"' EXIT INT TERM
cat > "$dns_local_script" <<'REMOTE'
set -eu
dns_service=/data/adb/netbird/scripts/netbird.service
dns_control=/data/adb/netbird/scripts/dns.sh
dns_helper=/data/adb/netbird/bin/nb-dns
dns_original="$(cat /data/adb/netbird/dns.enabled 2>/dev/null || echo 0)"
dns_restore() {
  dns_result="$?"
  "$dns_service" up >/dev/null 2>&1 || true
  if [ "$dns_original" = 1 ]; then "$dns_service" dns on; else "$dns_service" dns off; fi
  printf 'DNS_DEVICE_TEST_EXIT:%s\n' "$dns_result"
}
trap dns_restore EXIT
"$dns_service" dns off
"$dns_service" dns on
"$dns_service" dns check
"$dns_helper" probe '127.0.0.1:5354'
"$dns_helper" probe '[::1]:5354'
dns_original_pid="$(cat /data/adb/netbird/dns-state/helper.pid)"
"$dns_control" sync
[ "$(cat /data/adb/netbird/dns-state/helper.pid)" = "$dns_original_pid" ]
echo 'PASS: both loopback transports and idempotent sync'
"$dns_service" webui down >/dev/null
[ ! -f /data/adb/netbird/dns-state/helper.pid ]
"$dns_service" webui up >/dev/null
dns_ready=0
for dns_attempt in 1 2 3 4 5 6 7 8 9 10; do
  "$dns_control" sync >/dev/null 2>&1 || true
  if "$dns_service" dns check >/dev/null 2>&1; then dns_ready=1; break; fi
  sleep 2
done
[ "$dns_ready" = 1 ]
echo 'PASS: disconnect/reconnect restores DNS'
read -r dns_pid dns_start < /data/adb/netbird/dns-state/helper.pid
kill -9 "$dns_pid"
dns_recovered=0
for dns_attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  sleep 2
  if "$dns_service" dns check >/dev/null 2>&1; then dns_recovered=1; break; fi
done
[ "$dns_recovered" = 1 ]
echo 'PASS: watcher recovers a killed DNS forwarder'
"$dns_service" dns off
"$dns_service" dns off
if iptables -w -t nat -S OUTPUT | grep -q NBMOD_DNS; then exit 1; fi
if iptables -w -t nat -S POSTROUTING | grep -q NBMOD_DNS; then exit 1; fi
if ip -4 rule show | grep -q 'fwmark 0x4e400000/0xffe00000'; then exit 1; fi
if ip -6 rule show | grep -q 'fwmark 0x4e600000/0xffe00000'; then exit 1; fi
if ip6tables -w -t filter -S OUTPUT | grep -q NBMOD_DNS6R; then exit 1; fi
if [ -n "$(ip -6 route show table 7121 2>/dev/null)" ]; then exit 1; fi
echo 'PASS: off clears module-owned DNS interception and routing'
REMOTE
adb push "$dns_local_script" /data/local/tmp/netbird-dns-device-test.sh >/dev/null
adb shell "su -c 'nohup sh /data/local/tmp/netbird-dns-device-test.sh > /data/local/tmp/netbird-dns-device-test.log 2>&1 </dev/null &'"
dns_elapsed=0
while [ "$dns_elapsed" -lt 180 ]; do
  dns_output="$(adb shell "su -c 'cat /data/local/tmp/netbird-dns-device-test.log'" 2>/dev/null | tr -d '\r' || true)"
  case "$dns_output" in
    *DNS_DEVICE_TEST_EXIT:*)
      printf '%s\n' "$dns_output"
      dns_result="$(printf '%s\n' "$dns_output" | sed -n 's/^DNS_DEVICE_TEST_EXIT://p' | tail -1)"
      exit "$dns_result"
      ;;
  esac
  sleep 2
  dns_elapsed=$((dns_elapsed+2))
done
echo 'Timed out; inspect /data/local/tmp/netbird-dns-device-test.log on the device' >&2
exit 1
