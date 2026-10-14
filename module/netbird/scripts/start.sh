#!/system/bin/sh

DIR=$(dirname "$(realpath "$0")")
. "$DIR/../settings.sh"

case "${1:-}" in
  postinstall)
    rm -rf "$NB_RUN_DIR"
    mkdir -p "$NB_RUN_DIR"
    netbird.service restart >/dev/null 2>&1 &
    exit 0
    ;;
esac

if [ -n "${NB_MOD_DIR:-}" ] && [ -f "$NB_MOD_DIR/disable" ]; then
  log Info "Module is disabled; NetBird service will not start."
  exit 0
fi

netbird.service start >/dev/null 2>&1
