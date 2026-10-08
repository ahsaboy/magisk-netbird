#!/system/bin/sh
# Executed by a module manager's ACTION button. With no argument this keeps
# the original behavior: refresh runtime rules and show daemon status.
# Explicit actions are also supported for shell callers:
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

With no action, refreshes runtime rules and prints daemon status.
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

run_action "${1:-status}"
exit "$?"
