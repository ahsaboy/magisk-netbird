#!/system/bin/sh
# Executed by a module manager's ACTION button. With no argument, Volume Up
# starts NetBird and Volume Down stops it. Explicit actions are also supported
# for shell callers:
# action.sh {status|refresh|start|stop|restart|route|peers|log|version|help}

MODDIR=${0%/*}
export NB_MOD_DIR="$MODDIR"

SVC="/data/adb/netbird/scripts/netbird.service"
[ -x "$SVC" ] || SVC="$MODDIR/system/bin/netbird.service"

if [ ! -x "$SVC" ]; then
  echo "NetBird service script not found."
  exit 1
fi

show_status() {
  "$SVC" status
  return "$?"
}

choose_action() {
  echo "NetBird ACTION"
  echo "Volume Up (音量上键)   - Start (启动) NetBird"
  echo "Volume Down (音量下键) - Stop (停止) NetBird"
  echo "Press a volume key to continue... (请按音量键继续...)"

  # getevent observes input events without consuming them. Match only the
  # key-down event so the corresponding key-up event cannot trigger twice.
  selected_action="$(
    getevent -ql 2>/dev/null |
      awk '
        /EV_KEY[[:space:]]+KEY_VOLUMEUP[[:space:]]+(DOWN|1)/ { print "start"; exit }
        /EV_KEY[[:space:]]+KEY_VOLUMEDOWN[[:space:]]+(DOWN|1)/ { print "stop"; exit }
      '
  )"
  case "$selected_action" in
    start|stop)
      run_action "$selected_action"
      return "$?"
      ;;
    *)
      echo "No volume key was detected."
      return 1
      ;;
  esac
}

run_action() {
  action="$1"
  case "$action" in
    status)
      "$SVC" refresh
      refresh_rc="$?"
      show_status
      status_rc="$?"
      [ "$refresh_rc" -ne 0 ] && return "$refresh_rc"
      return "$status_rc"
      ;;
    refresh)
      echo "Refreshing NetBird runtime rules..."
      "$SVC" refresh
      rc="$?"
      show_status || true
      return "$rc"
      ;;
    start|stop|restart|route)
      echo "Running NetBird action: $action"
      "$SVC" "$action"
      rc="$?"
      show_status || true
      return "$rc"
      ;;
    peers)
      exec "$SVC" peers
      ;;
    log)
      exec "$SVC" log --once
      ;;
    version)
      exec "$SVC" version
      ;;
    help)
      cat <<'EOF'
Usage: action.sh [status|refresh|start|stop|restart|route|peers|log|version|help]

With no action, Volume Up starts NetBird and Volume Down stops it.
Use `action.sh status` to refresh runtime rules and print daemon status.
The log action prints the latest entries and exits; service log keeps following.
EOF
      ;;
    *)
      echo "Unknown NetBird action: $action"
      echo "Usage: action.sh [status|refresh|start|stop|restart|route|peers|log|version|help]"
      return 2
      ;;
  esac
}

if [ "$#" -eq 0 ]; then
  choose_action
else
  run_action "$1"
fi
exit "$?"
