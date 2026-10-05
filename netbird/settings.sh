#!/system/bin/sh
# NOTE: This file is sourced by other scripts; do NOT set -e here, or a
# failing command in a sourcing script (e.g. a non-zero `netbird up`) would
# abort the whole script before it can capture the return code.

NB_DIR="/data/adb/netbird"
NB_BIN_DIR="$NB_DIR/bin"
NB_SCRIPTS_DIR="$NB_DIR/scripts"
NB_RUN_DIR="$NB_DIR/run"
NB_CERT_DIR="$NB_DIR/certs"
NB_CONFIG_FILE="$NB_DIR/config.json"
NB_SOCKET="$NB_RUN_DIR/netbird.sock"
NB_LOG_FILE_PATH="$NB_RUN_DIR/client.log"
NB_SERVICE_LOG_FILE="$NB_RUN_DIR/service.log"
NB_CA_BUNDLE="$NB_RUN_DIR/ca-bundle.pem"
NB_CA_COUNT_FILE="$NB_RUN_DIR/ca-bundle.count"

# Persistent user overrides: /data/adb/netbird/.env (KEY=VALUE lines, '#'
# comments; see netbird.env.example). A variable already present in the
# environment wins over the file, and the file wins over the defaults below.
# Values exported here are inherited by every child script and the daemon.
NB_ENV_FILE="$NB_DIR/.env"
if [ -f "$NB_ENV_FILE" ]; then
  nb_env_cr="$(printf '\r')"
  while IFS= read -r nb_env_line || [ -n "$nb_env_line" ]; do
    nb_env_line="${nb_env_line%"$nb_env_cr"}"
    case "$nb_env_line" in
      '' | '#'*) continue ;;
      export\ *) nb_env_line="${nb_env_line#export }" ;;
    esac
    case "$nb_env_line" in
      *=*) ;;
      *) continue ;;
    esac
    nb_env_key="${nb_env_line%%=*}"
    # Only plain identifiers may be eval'd as a variable name.
    case "$nb_env_key" in
      '' | [0-9]* | *[!A-Za-z0-9_]*) continue ;;
    esac
    eval "nb_env_set=\${$nb_env_key+set}"
    [ "$nb_env_set" = "set" ] && continue
    nb_env_value="${nb_env_line#*=}"
    eval "export $nb_env_key=\$nb_env_value"
  done < "$NB_ENV_FILE"
  unset nb_env_line nb_env_key nb_env_value nb_env_set nb_env_cr
fi

# Persistent state (state.json, WireGuard keys) must live on a writable path;
# the upstream default (/var/lib/netbird) does not exist on Android.
NB_STATE_DIR="${NB_STATE_DIR:-$NB_DIR}"

if [ -z "${NB_MOD_DIR:-}" ] && [ -f "$NB_DIR/module.path" ]; then
  NB_MOD_DIR="$(cat "$NB_DIR/module.path" 2>/dev/null || true)"
fi

export PATH="$NB_BIN_DIR:$NB_SCRIPTS_DIR:/data/adb/magisk:/data/adb/ksu/bin:$PATH:/system/bin"
export HOME="$NB_DIR"
export USER="${USER:-root}"
export LOGNAME="${LOGNAME:-root}"
export SHELL="${SHELL:-/system/bin/sh}"
export NB_CONFIG="$NB_CONFIG_FILE"
export NB_DAEMON_ADDR="unix://$NB_SOCKET"
export NB_LOG_FILE="$NB_LOG_FILE_PATH"
export NB_LOG_LEVEL="${NB_LOG_LEVEL:-info}"
# NetBird's own log rotation cap for client.log, in MiB. Upstream default15MB
# is large for a phone; this module defaults to5MB (override in .env).
export NB_LOG_MAX_SIZE_MB="${NB_LOG_MAX_SIZE_MB:-5}"
export NB_DISABLE_DNS="${NB_DISABLE_DNS:-true}"
# Official client environment variables (see docs.netbird.io/client/environment-variables):
# - NB_DISABLE_SSH_CONFIG: don't write /etc/ssh/ssh_config.d (read-only on Android).
# - NB_SKIP_NFTABLES_CHECK: skip the nftables probe that always fails on Android.
# - NB_SKIP_DNS_PROBE: skip the local-resolver startup probe (DNS mgmt is disabled).
# - NB_NETWORK_MONITOR: upstream defaults to false on Linux; we want network-switch handling.
export NB_DISABLE_SSH_CONFIG="${NB_DISABLE_SSH_CONFIG:-true}"
export NB_SKIP_NFTABLES_CHECK="${NB_SKIP_NFTABLES_CHECK:-true}"
export NB_SKIP_DNS_PROBE="${NB_SKIP_DNS_PROBE:-true}"
export NB_NETWORK_MONITOR="${NB_NETWORK_MONITOR:-true}"
export NB_STATE_DIR
export SSL_CERT_FILE="$NB_CA_BUNDLE"
export SSL_CERT_DIR="${SSL_CERT_DIR:-/system/etc/security/cacerts:/apex/com.android.conscrypt/cacerts:/system/etc/security/cacerts_google}"

NB_DAEMON_CMD="netbird service run --config $NB_CONFIG_FILE --daemon-addr $NB_DAEMON_ADDR --log-file $NB_LOG_FILE_PATH"
export NB_DAEMON_CMD

# "up" flags handled by netbird.service. Deliberately NOT exported by default:
# environment variables outrank CLI flags in NetBird, so exporting a default
# "false" would break an explicit `--disable-ipv6` passed on the command line.
# Set them to "true" in the environment to opt in.
NB_DISABLE_IPV6="${NB_DISABLE_IPV6:-false}"
NB_DISABLE_FIREWALL="${NB_DISABLE_FIREWALL:-false}"

# NetBird's native Linux firewall initializes both IPv4 and IPv6 backends.
# Some Android kernels expose ip6tables but have no IPv6 nat table; in that
# case native firewall setup fails before the client can connect. Unless the
# user explicitly overrides it, fall back to userspace WireGuard + USPFilter.
if [ "$NB_DISABLE_FIREWALL" != "true" ] && [ -z "${NB_FORCE_USERSPACE_FIREWALL+x}" ]; then
  if ! command -v ip6tables >/dev/null 2>&1 ||
    ! ip6tables -t nat -L -n >/dev/null 2>&1; then
    NB_FORCE_USERSPACE_FIREWALL=true
  fi
fi
if [ "${NB_FORCE_USERSPACE_FIREWALL:-false}" = "true" ] &&
  [ -z "${NB_WG_KERNEL_DISABLED+x}" ]; then
  NB_WG_KERNEL_DISABLED=true
fi
[ -n "${NB_FORCE_USERSPACE_FIREWALL+x}" ] && export NB_FORCE_USERSPACE_FIREWALL
[ -n "${NB_WG_KERNEL_DISABLED+x}" ] && export NB_WG_KERNEL_DISABLED

# Watchdog (module-status.sh watch loop): probe daemon health once per cycle
# and restart it after NB_WATCHDOG_FAILS consecutive failures. The restart
# budget (NB_WATCHDOG_MAX_RESTARTS) resets after5 healthy cycles. Set
# NB_WATCHDOG=off in .env to disable. Not exported: only module scripts use
# these, and every script re-reads .env via this file.
NB_WATCHDOG="${NB_WATCHDOG:-on}"
NB_WATCHDOG_FAILS="${NB_WATCHDOG_FAILS:-3}"
NB_WATCHDOG_MAX_RESTARTS="${NB_WATCHDOG_MAX_RESTARTS:-10}"
for nb_num_var in NB_WATCHDOG_FAILS NB_WATCHDOG_MAX_RESTARTS; do
  eval "nb_num_val=\$$nb_num_var"
  case "$nb_num_val" in
    '' | *[!0-9]* | 0*)
      case "$nb_num_var" in
        NB_WATCHDOG_FAILS) NB_WATCHDOG_FAILS=3 ;;
        NB_WATCHDOG_MAX_RESTARTS) NB_WATCHDOG_MAX_RESTARTS=10 ;;
      esac
      ;;
  esac
done
unset nb_num_var nb_num_val

mkdir -p "$NB_RUN_DIR" "$NB_CERT_DIR"

log() {
  level="$1"
  shift
  log_time="$(date '+%H:%M:%S' 2>/dev/null || echo unknown)"
  # Rotate service.log at 1 MiB (client.log is rotated by NetBird itself).
  if [ -f "$NB_SERVICE_LOG_FILE" ]; then
    log_size="$(wc -c < "$NB_SERVICE_LOG_FILE" 2>/dev/null | tr -d ' ' || true)"
    case "$log_size" in
      ''|*[!0-9]*) log_size=0 ;;
    esac
    if [ "$log_size" -gt 1048576 ]; then
      mv -f "$NB_SERVICE_LOG_FILE" "$NB_SERVICE_LOG_FILE.bak" 2>/dev/null || true
    fi
  fi
  echo "$log_time [$level]: $*" >> "$NB_SERVICE_LOG_FILE"
  if [ -t 1 ]; then
    echo "$log_time [$level]: $*"
  fi
}
