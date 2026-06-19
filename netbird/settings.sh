#!/system/bin/sh
# shellcheck disable=SC2034  # Variables are used by scripts that source this file
# @title Magisk NetBird Settings
# @description Shared configuration variables and utility functions.

# ──────────────────────────────────────────────
# Paths
# ──────────────────────────────────────────────
NB_MOD_DIR="${NB_MOD_DIR:-/data/adb/modules/magisk-netbird}"
NB_DIR="/data/adb/netbird"
NB_BIN_DIR="${NB_DIR}/bin"
NB_SCRIPTS_DIR="${NB_DIR}/scripts"
NB_RUN_DIR="${NB_DIR}/run"
NB_DATA_DIR="${NB_DIR}/data"
NB_BACKUP_DIR="${NB_DIR}/backups"

NB_CONFIG_FILE="${NB_DATA_DIR}/config.json"
NB_LOG_FILE="${NB_RUN_DIR}/netbird.log"
NB_RUN_LOG_FILE="${NB_RUN_DIR}/service.log"
NB_PID_FILE="${NB_RUN_DIR}/netbird.pid"

NB_DAEMON_BIN="${NB_BIN_DIR}/netbird"

# ──────────────────────────────────────────────
# PATH
# ──────────────────────────────────────────────
export PATH="${NB_BIN_DIR}:${NB_SCRIPTS_DIR}:/data/adb/magisk:/data/adb/ksu/bin:${PATH}:/system/bin"
export HOME="${NB_DIR}/"

# ──────────────────────────────────────────────
# Colors (actual escape bytes, not \033 strings)
# ──────────────────────────────────────────────
COLOR_RESET=$(printf '\033[0m')
COLOR_RED=$(printf '\033[1;31m')
COLOR_GREEN=$(printf '\033[1;32m')
COLOR_YELLOW=$(printf '\033[1;33m')
COLOR_BLUE=$(printf '\033[1;34m')
# shellcheck disable=SC2034
COLOR_CYAN=$(printf '\033[1;36m')

# ──────────────────────────────────────────────
# Log (timestamp computed fresh each call)
# ──────────────────────────────────────────────
log() {
  local level="$1"; shift
  local ts color
  ts=$(date +"%Y-%m-%d %H:%M:%S")
  case "$level" in
    Info)    color="${COLOR_BLUE}" ;;
    Success) color="${COLOR_GREEN}" ;;
    Error)   color="${COLOR_RED}" ;;
    Warning) color="${COLOR_YELLOW}" ;;
    *)       color="" ;;
  esac
  echo "${ts} [${level}]: $*" >> "${NB_RUN_LOG_FILE}" 2>/dev/null || true
  if [ -t 1 ] || [ -n "${OUTFD:-}" ]; then
    [ -n "${color}" ] && printf '%s[%s]%s %s\n' "${color}" "${level}" "${COLOR_RESET}" "$*" \
                       || printf '[%s] %s\n' "${level}" "$*"
  fi
}

# ──────────────────────────────────────────────
# Module prop helpers
# ──────────────────────────────────────────────
get_module_prop() {
  local key="$1" file="${2:-${NB_MOD_DIR}/module.prop}"
  [ -f "${file}" ] && sed -n "s/^${key}=//p" "${file}" | head -1
}

set_module_prop() {
  local key="$1" value="$2" file="${3:-${NB_MOD_DIR}/module.prop}"
  [ -f "${file}" ] || { echo "${key}=${value}" > "${file}"; return; }
  local tmp="${file}.tmp"
  local line
  while IFS= read -r line; do
    case "${line}" in "${key}="*) echo "${key}=${value}";; *) echo "${line}";; esac
  done < "${file}" > "${tmp}" && mv -f "${tmp}" "${file}"
}

update_module_status() {
  set_module_prop "description" "NetBird $1 | $(date +%H:%M) | WireGuard P2P VPN"
}

# ──────────────────────────────────────────────
# Process helpers (PID-reuse safe)
# ──────────────────────────────────────────────
is_running() {
  [ -f "$1" ] && [ -d "/proc/$(cat "$1" 2>/dev/null)" ]
}

kill_pid() {
  local pid_file="$1" name="$2" timeout="${3:-10}"
  local pid; pid=$(cat "${pid_file}" 2>/dev/null) || true
  [ -z "${pid}" ] && { rm -f "${pid_file}"; return; }
  [ -d "/proc/${pid}" ] || { rm -f "${pid_file}"; return; }
  # Verify it's actually our process
  local cmd; cmd=$(cat "/proc/${pid}/cmdline" 2>/dev/null || true)
  echo "${cmd}" | grep -q "${name}" 2>/dev/null || { rm -f "${pid_file}"; return; }
  log Info "Stopping ${name} (PID: ${pid})..."
  kill -TERM "${pid}" 2>/dev/null || true
  local i=0; while [ -d "/proc/${pid}" ] && [ "$i" -lt "$timeout" ]; do sleep 1; i=$((i+1)); done
  [ -d "/proc/${pid}" ] && kill -9 "${pid}" 2>/dev/null || true
  rm -f "${pid_file}"
  log Success "${name} stopped."
}

# ──────────────────────────────────────────────
# Debug
# ──────────────────────────────────────────────
[ -n "${DEBUG:-}" ] && { PS4="+ \${0##*/}:\${LINENO}: "; set -u; set -x; } || true
