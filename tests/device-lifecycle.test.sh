#!/bin/sh
set -eu

# Destructive lifecycle checks; rebooting additionally requires its own opt-in.
# Set NETBIRD_DEVICE_TESTS=1 to run. Set NETBIRD_DEVICE_REBOOT_TEST=1 to reboot.

if [ "${NETBIRD_DEVICE_TESTS:-}" != 1 ]; then
  echo "Set NETBIRD_DEVICE_TESTS=1 to enable disruptive lifecycle tests." >&2
  exit 2
fi
command -v adb >/dev/null 2>&1 || { echo "adb is required" >&2; exit 2; }
adb get-state >/dev/null 2>&1 || { echo "No authorized Android device is connected" >&2; exit 2; }

adb shell su -c 'sh -s' <<'REMOTE'
#!/system/bin/sh
set -eu
. /data/adb/netbird/settings.sh
service="$NB_SCRIPTS_DIR/netbird.service"
watch_pid_file="$NB_RUN_DIR/module-status.pid"
[ -x "$service" ] || { echo "NetBird service script is missing" >&2; exit 1; }
[ "$NB_WATCHDOG" != off ] || { echo "Watchdog is disabled" >&2; exit 1; }
[ -f "$NB_RUN_DIR/netbird.desired" ] || { echo "Daemon is not marked as desired-running" >&2; exit 1; }

get_daemon_pid() {
  busybox pgrep -f "$NB_DAEMON_CMD" 2>/dev/null | head -n 1
}
get_daemon_starttime() {
  awk '{ print $22 }' "/proc/$1/stat" 2>/dev/null
}
watch_pid="$(cat "$watch_pid_file" 2>/dev/null || true)"
[ -n "$watch_pid" ] && kill -0 "$watch_pid" 2>/dev/null || { echo "Watcher is not running" >&2; exit 1; }
daemon_pid="$(get_daemon_pid)"
[ -n "$daemon_pid" ] || { echo "Daemon is not running" >&2; exit 1; }
status_json="$(netbird --daemon-addr "$NB_DAEMON_ADDR" status --json 2>/dev/null || true)"
printf '%s\n' "$status_json" | grep -q '"daemonStatus":"Connected"' || {
  echo "Connect NetBird before running the down lifecycle test" >&2
  exit 1
}

"$service" webui down >/dev/null
sleep 3
[ "$(get_daemon_pid)" = "$daemon_pid" ] || { echo "Daemon PID changed after webui down" >&2; exit 1; }
[ "$(cat "$watch_pid_file" 2>/dev/null || true)" = "$watch_pid" ] && kill -0 "$watch_pid" 2>/dev/null || {
  echo "Watcher stopped after webui down" >&2
  exit 1
}
[ -f "$NB_RUN_DIR/netbird.desired" ] || { echo "webui down cleared desired-running state" >&2; exit 1; }
printf '%s\n' "PASS: webui down preserved daemon PID $daemon_pid and watcher PID $watch_pid"

restart_count="$(cat "$NB_RUN_DIR/watchdog.count" 2>/dev/null || echo 0)"
case "$restart_count" in ''|*[!0-9]*) restart_count=0 ;; esac
[ "$restart_count" -lt "$NB_WATCHDOG_MAX_RESTARTS" ] || {
  echo "Watchdog restart budget is exhausted; refusing to kill the daemon" >&2
  exit 1
}
old_starttime="$(get_daemon_starttime "$daemon_pid")"
kill -9 "$daemon_pid"
waited=0
recovered_pid=""
recovered_starttime=""
while [ "$waited" -lt 240 ]; do
  sleep 5
  waited=$((waited + 5))
  recovered_pid="$(get_daemon_pid || true)"
  if [ -n "$recovered_pid" ]; then
    recovered_starttime="$(get_daemon_starttime "$recovered_pid" || true)"
    if [ -n "$recovered_starttime" ] && [ "$recovered_starttime" != "$old_starttime" ]; then
      break
    fi
  fi
done
[ -n "$recovered_pid" ] && [ "$recovered_starttime" != "$old_starttime" ] || {
  echo "Watchdog did not start a new daemon within 240 seconds" >&2
  exit 1
}
[ -f "$NB_RUN_DIR/netbird.desired" ] || { echo "Recovery cleared desired-running state" >&2; exit 1; }
[ "$(cat "$watch_pid_file" 2>/dev/null || true)" = "$watch_pid" ] && kill -0 "$watch_pid" 2>/dev/null || {
  echo "Watcher PID changed or exited during daemon recovery" >&2
  exit 1
}
printf '%s\n' "PASS: watchdog restored daemon PID $recovered_pid after ${waited}s; watcher PID $watch_pid remained active"
REMOTE

if [ "${NETBIRD_DEVICE_REBOOT_TEST:-}" = 1 ]; then
  adb reboot
  adb wait-for-device
  waited=0
  while [ "$waited" -lt 300 ]; do
    if adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' | grep -q '^1$'; then
      break
    fi
    sleep 5
    waited=$((waited + 5))
  done
  [ "$waited" -lt 300 ] || { echo "Android did not finish booting within 300 seconds" >&2; exit 1; }
  adb shell su -c 'sh -s' <<'REMOTE_BOOT'
#!/system/bin/sh
set -eu
. /data/adb/netbird/settings.sh
watch_pid="$(cat "$NB_RUN_DIR/module-status.pid" 2>/dev/null || true)"
[ -n "$watch_pid" ] && kill -0 "$watch_pid" 2>/dev/null || { echo "Watcher did not start after boot" >&2; exit 1; }
[ -f "$NB_RUN_DIR/netbird.desired" ] || { echo "Daemon desired-running marker is missing after boot" >&2; exit 1; }
busybox pgrep -f "$NB_DAEMON_CMD" >/dev/null 2>&1 || { echo "Daemon did not start after boot" >&2; exit 1; }
echo "PASS: daemon and watcher started after boot"
REMOTE_BOOT
fi

if [ "${NETBIRD_DEVICE_REBOOT_TEST:-}" != 1 ]; then
  echo "Boot autostart, 30s/300s probe cadence, journal concurrency, and CPU wakeups still require device measurement."
fi
