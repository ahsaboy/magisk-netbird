#!/system/bin/sh

DIR=$(dirname "$(realpath "$0")")
. "$DIR/../settings.sh"

heartbeat_interval=30
connected_probe_interval=30
idle_probe_interval=300
watch_pid_file="$NB_RUN_DIR/module-status.pid"
default_description="NetBird CLI daemon for Magisk with DNS management disabled by default."
NB_AUTOMATION_LIBRARY_ONLY=1
. "$NB_SCRIPTS_DIR/automation.sh"
unset NB_AUTOMATION_LIBRARY_ONLY

# Print every existing module.prop that should receive the status line: the
# active module dir, the staged upgrade dir, and the module.path hint. After
# an install, module.path points at modules_update while the Magisk app still
# shows the active dir, so updating only one of them leaves a stale view.
module_prop_paths() {
  for path in \
    "${NB_MOD_DIR:-}/module.prop" \
    "$(cat "$NB_DIR/module.path" 2>/dev/null || true)/module.prop" \
    /data/adb/modules/magisk-netbird/module.prop \
    /data/adb/modules_update/magisk-netbird/module.prop; do
    [ -n "$path" ] && [ "$path" != "/module.prop" ] && [ -f "$path" ] && echo "$path"
  done | sort -u
}

daemon_pid() {
  if command -v busybox >/dev/null 2>&1; then
    busybox pgrep -f "$NB_DAEMON_CMD" 2>/dev/null | head -n 1
    return 0
  fi
  ps -A -o PID,ARGS 2>/dev/null |
    awk '/netbird service run/ && $0 !~ /awk/ { print $1; exit }'
}

daemon_running() {
  pid="$(daemon_pid)"
  [ -n "$pid" ] && [ -r "/proc/$pid/status" ]
}

memory_usage() {
  pid="$(daemon_pid)"
  [ -n "$pid" ] || return 1
  rss_kb="$(awk '/^VmRSS:/ { print $2; exit }' "/proc/$pid/status" 2>/dev/null)"
  [ -n "$rss_kb" ] || return 1
  awk -v kb="$rss_kb" 'BEGIN {
    if (kb >= 1048576) {
      printf "%.1fG", kb / 1048576
    } else if (kb >= 1024) {
      printf "%.1fM", kb / 1024
    } else {
      printf "%dK", kb
    }
  }'
}

ca_count() {
  count="$(cat "$NB_CA_COUNT_FILE" 2>/dev/null || true)"
  case "$count" in
    ''|*[!0-9]*)
      echo 0
      ;;
    *)
      echo "$count"
      ;;
  esac
}

# `netbird status --json` with a hard timeout so a wedged socket cannot hang
# the watcher (used by the watchdog probe and the peer details below).
nb_with_timeout() {
  if command -v busybox >/dev/null 2>&1; then
    busybox timeout 10 "$@"
  else
    "$@"
  fi
}

status_json() {
  nb_with_timeout netbird --daemon-addr "$NB_DAEMON_ADDR" status --json 2>/dev/null
}

# --- JSON helpers (no jq on Android) -----------------------------------------
# First "{...}" object value of a key whose object has no nested objects
# (management, signal). Sections containing a details array (peers, relays)
# are cut at "details" instead.
json_section() {
  printf '%s\n' "$1" | grep -o "\"$2\":{[^}]*}" | head -n 1
}

json_bool_field() {
  printf '%s\n' "$1" | grep -o "\"$2\":\(true\|false\)" | head -n 1 | cut -d: -f2
}

json_connected_label() {
  case "$(json_bool_field "$1" connected)" in
    true) echo "Connected" ;;
    false) echo "Disconnected" ;;
    *) echo "" ;;
  esac
}

# Connection state from a status --json blob: "connected", "idle" (client
# intentionally disconnected / needs login), or "other" (connecting, unknown).
watch_connection_state() {
  case "$(json_field "$1" daemonStatus)" in
    Connected) echo "connected" ;;
    Disconnected | Needs*) echo "idle" ;;
    *) echo "other" ;;
  esac
}

# Print "<direct> <relayed>" counts for Connected peers in a status --json blob.
peer_dr_counts() {
  printf '%s\n' "$1" | sed 's/{"fqdn"/\
{"fqdn"/g' | awk '
    /"status":"Connected"/ {
      if (match($0, /"connectionType":"[^"]*"/)) {
        t = substr($0, RSTART + 18, RLENGTH - 19)
        if (t == "P2P") d++
        else if (t == "Relayed") r++
      }
    }
    END { printf "%d %d\n", d + 0, r + 0 }'
}

human_bytes() {
  # Validate in the shell: `awk` precedence for `~` vs `==` differs between
  # implementations, which silently broke the old regex guard.
  case "${1:-}" in
    '' | *[!0-9]*)
      echo "-"
      ;;
    *)
      awk -v b="$1" 'BEGIN {
        if (b >= 1073741824) printf "%.1fG", b / 1073741824
        else if (b >= 1048576) printf "%.1fM", b / 1048576
        else if (b >= 1024) printf "%dK", b / 1024
        else printf "%dB", b
      }'
      ;;
  esac
}

json_field() {
  # $1 = blob, $2 = field name. grep -o + head -1 yields the FIRST occurrence;
  # a greedy sed '.*"field"' would pick the last one and cross-match later
  # sections of the status JSON (routes, dns, ...).
  printf '%s\n' "$1" | grep -o "\"$2\":\"[^\"]*\"" | head -n 1 | cut -d'"' -f4
}

json_num_field() {
  printf '%s\n' "$1" | grep -o "\"$2\":[0-9]*" | head -n 1 | cut -d: -f2
}

# Per-peer table: fqdn, NetBird IP, state, connection type, latency, traffic,
# last WireGuard handshake, parsed from `netbird status --json` without jq.
print_peers() {
  json="$(status_json)"
  if [ -z "$json" ]; then
    echo "netbird status unavailable (daemon not running or not responding)"
    return 1
  fi
  total="$(json_num_field "$json" total)"
  connected="$(json_num_field "$json" connected)"
  set -- $(peer_dr_counts "$json")
  direct="$1"
  relayed="$2"

  printf '%-18s %-15s %-10s %-7s %7s %8s %8s %9s\n' \
    PEER NETBIRD-IP STATE TYPE LATENCY RX TX LAST-HS
  printf '%s\n' "$json" | sed 's/{"fqdn"/\
{"fqdn"/g' | while IFS= read -r obj; do
    case "$obj" in
      *'"fqdn"'*) ;;
      *) continue ;;
    esac
    fqdn="$(json_field "$obj" fqdn)"
    [ -n "$fqdn" ] || continue
    ip="$(json_field "$obj" netbirdIp)"
    state="$(json_field "$obj" status)"
    ctype="$(json_field "$obj" connectionType)"
    lat="$(json_num_field "$obj" latency)"
    case "$lat" in
      '' | *[!0-9]*) lat_txt="-" ;;
      *)
        if [ "$lat" -gt 0 ]; then
          lat_txt="$(awk -v n="$lat" 'BEGIN { printf "%.0fms", n / 1000000 }')"
        else
          lat_txt="-"
        fi
        ;;
    esac
    rx="$(human_bytes "$(json_num_field "$obj" transferReceived)")"
    tx="$(human_bytes "$(json_num_field "$obj" transferSent)")"
    hs="$(json_field "$obj" lastWireguardHandshake)"
    case "$hs" in
      0001-* | '') hs="-" ;;
      *)
        hs="${hs#*T}"
        hs="${hs%%Z*}"
        ;;
    esac
    [ -n "$state" ] || state="-"
    [ -n "$ctype" ] || ctype="-"
    [ -n "$ip" ] || ip="-"
    printf '%-18s %-15s %-10s %-7s %7s %8s %8s %9s\n' \
      "$fqdn" "$ip" "$state" "$ctype" "$lat_txt" "$rx" "$tx" "$hs"
  done
  echo
  printf 'Total: %s  Connected: %s  Direct(P2P): %s  Relayed: %s\n' \
    "${total:-?}" "${connected:-?}" "$direct" "$relayed"
}

# --- Watchdog -----------------------------------------------------------------
# Check daemon process presence on every heartbeat. IPC health is counted only
# when a status probe was actually due; an intentionally disconnected client
# skips those probes between the longer idle intervals.
watchdog_check() {
  wd_blob="${1:-}"
  wd_probe="${2:-0}"
  wd_running="${3:-0}"
  [ "$NB_WATCHDOG" = "off" ] && return 0
  [ -f "$NB_RUN_DIR/netbird.desired" ] || return 0

  if [ "$wd_running" -eq 1 ] && [ "$wd_probe" -eq 0 ]; then
    return 0
  fi

  if [ "$wd_running" -eq 1 ] && [ -n "$wd_blob" ]; then
    wd_fails=0
    wd_healthy=$((wd_healthy + 1))
    if [ "$wd_healthy" -ge 5 ] && [ "$wd_restarts" -gt 0 ]; then
      wd_restarts=0
      wd_gave_up=0
      echo 0 > "$NB_RUN_DIR/watchdog.count"
      log Info "Watchdog: daemon healthy again; restart budget reset."
    fi
    return 0
  fi

  wd_healthy=0
  wd_fails=$((wd_fails + 1))
  [ "$wd_fails" -lt "$NB_WATCHDOG_FAILS" ] && return 0
  wd_fails=0

  if [ "$wd_restarts" -ge "$NB_WATCHDOG_MAX_RESTARTS" ]; then
    if [ "$wd_gave_up" -eq 0 ]; then
      wd_gave_up=1
      log Error "Watchdog: restart budget exhausted ($wd_restarts); not restarting until the daemon stays healthy again."
    fi
    return 0
  fi

  wd_restarts=$((wd_restarts + 1))
  echo "$wd_restarts" > "$NB_RUN_DIR/watchdog.count"
  log Warning "Watchdog: daemon not responding for $NB_WATCHDOG_FAILS cycles; restarting (attempt $wd_restarts/$NB_WATCHDOG_MAX_RESTARTS)."
  watchdog_restart_daemon
}

watchdog_restart_daemon() {
  if command -v busybox >/dev/null 2>&1; then
    wd_pids="$(busybox pgrep -f "$NB_DAEMON_CMD" 2>/dev/null)"
  else
    wd_pids=""
  fi
  for wd_pid in $wd_pids; do
    kill -15 "$wd_pid" 2>/dev/null || true
  done
  [ -n "$wd_pids" ] && sleep 3
  if command -v busybox >/dev/null 2>&1; then
    wd_pids="$(busybox pgrep -f "$NB_DAEMON_CMD" 2>/dev/null)"
  else
    wd_pids=""
  fi
  for wd_pid in $wd_pids; do
    kill -9 "$wd_pid" 2>/dev/null || true
  done
  rm -f "$NB_SOCKET" "$NB_RUN_DIR/netbird.pid"
  if [ -x "$NB_SCRIPTS_DIR/netbird.service" ]; then
    "$NB_SCRIPTS_DIR/netbird.service" start >/dev/null 2>&1 || true
  fi
}

build_description() {
  now="$(date '+%H:%M:%S' 2>/dev/null || echo unknown)"
  mem="$(memory_usage 2>/dev/null || true)"
  cas="$(ca_count)"
  [ -n "$mem" ] || mem="N/A"
  wd="$(cat "$NB_RUN_DIR/watchdog.count" 2>/dev/null || true)"
  case "$wd" in '' | *[!0-9]*) wd=0 ;; esac
  wd_txt=""
  [ "$wd" -gt 0 ] && wd_txt="  WD=$wd"

  if ! daemon_running; then
    echo "NB=stopped$wd_txt | Mem=$mem  CA=$cas | Upd=$now"
    return 0
  fi

  # Reuse the caller's probe when available (the watch loop captures the
  # blob once per cycle and shares it with the watchdog).
  json_blob="${1:-}"
  [ -n "$json_blob" ] || json_blob="$(status_json)"
  if [ -z "$json_blob" ]; then
    echo "NB=running | Status=unavailable  Mem=$mem | CA=$cas  Upd=$now"
    return 0
  fi

  fqdn="$(json_field "$json_blob" fqdn)"
  ip="$(json_field "$json_blob" netbirdIp)"
  ip="${ip%%/*}"
  ipv6="$(json_field "$json_blob" netbirdIpv6)"
  ipv6="${ipv6%%/*}"

  peers_head="$(printf '%s\n' "$json_blob" | sed 's/"details".*//')"
  ptotal="$(json_num_field "$peers_head" total)"
  pconn="$(json_num_field "$peers_head" connected)"
  if [ -n "$ptotal" ] && [ -n "$pconn" ]; then
    peers="$pconn/$ptotal"
  else
    peers=""
  fi

  management="$(json_connected_label "$(json_section "$json_blob" management)")"
  signal="$(json_connected_label "$(json_section "$json_blob" signal)")"

  relays_part="$(printf '%s\n' "$json_blob" | sed 's/.*"relays":{//')"
  relays_part="${relays_part%%\"details\"*}"
  rtotal="$(printf '%s\n' "$relays_part" | grep -o '"total":[0-9]*' | head -n 1 | cut -d: -f2)"
  ravail="$(printf '%s\n' "$relays_part" | grep -o '"available":[0-9]*' | head -n 1 | cut -d: -f2)"
  relays=""
  [ -n "$ravail" ] && [ -n "$rtotal" ] && relays="$ravail/$rtotal"

  iface=""
  case "$(json_bool_field "$json_blob" usesKernelInterface)" in
    true) iface="Kernel" ;;
    false) iface="Userspace" ;;
  esac
  port="$(json_num_field "$json_blob" wireguardPort)"

  # Direct/relay split of connected peers from the same blob (best effort).
  dr_txt=""
  set -- $(peer_dr_counts "$json_blob")
  case "$1$2" in
    '' | *[!0-9]*) ;;
    *)
      if [ "$1" -gt 0 ] || [ "$2" -gt 0 ]; then
        dr_txt=" [P$1 R$2]"
      fi
      ;;
  esac

  summary="NB=running"
  [ -n "$fqdn" ] && summary="$summary | Host=$fqdn"
  if [ -n "$ip" ]; then
    summary="$summary  IP=$ip"
  elif [ -n "$ipv6" ]; then
    summary="$summary  IPv6=$ipv6"
  fi
  [ -n "$peers" ] && summary="$summary | Peers=$peers$dr_txt"
  summary="$summary  Mem=$mem"
  [ -n "$management" ] && summary="$summary | Mgmt=$management"
  [ -n "$signal" ] && summary="$summary | Sig=$signal"
  [ -n "$relays" ] && summary="$summary | Relay=$relays"
  if [ -n "$iface" ] && [ -n "$port" ]; then
    summary="$summary  IF=$iface:$port"
  elif [ -n "$iface" ]; then
    summary="$summary  IF=$iface"
  fi
  summary="$summary$wd_txt | CA=$cas  Upd=$now"

  printf '%s\n' "$summary"
}

ksu_publish_description() {
  # KernelSU's module config system lets the manager display a runtime
  # description via the override.description key (newer ksud builds only).
  # Best-effort and additive: module.prop is still written for Magisk and for
  # managers that do not read the config store.
  command -v ksud >/dev/null 2>&1 || return 0
  [ -d /data/adb/ksu ] || return 0
  KSU_MODULE="${KSU_MODULE:-magisk-netbird}" \
    ksud module config set override.description "$description" >/dev/null 2>&1 || true
}

write_module_prop() {
  description="$(build_description "${1:-}")"
  [ -n "$description" ] || description="$default_description"

  ksu_publish_description

  prop_files="$(module_prop_paths)"
  [ -n "$prop_files" ] || return 0

  for prop_file in $prop_files; do
    tmp_file="$prop_file.tmp.$$"
    awk -v description="$description" '
      BEGIN { updated = 0 }
      /^description=/ {
        print "description=" description
        updated = 1
        next
      }
      { print }
      END {
        if (!updated) {
          print "description=" description
        }
      }
    ' "$prop_file" > "$tmp_file" &&
      mv -f "$tmp_file" "$prop_file" &&
      chmod 0644 "$prop_file" 2>/dev/null || {
        rm -f "$tmp_file"
        return 1
      }
  done
}

watcher_pids() {
  # Suffix-anchored match: only the real `... module-status.sh watch` process
  # ends with that text. An unanchored substring pattern also matches shells
  # that merely *mention* it (su -c wrappers, greps) and would reap the
  # caller's own session.
  if command -v busybox >/dev/null 2>&1; then
    busybox pgrep -f 'module-status\.sh watch$' 2>/dev/null
    return 0
  fi
  ps -A -o PID,ARGS 2>/dev/null |
    awk '/module-status[.]sh watch$/ { print $1 }'
}

reap_extra_watchers() {
  # Kill every live watcher except $1 (optional), escalating TERM -> KILL.
  # A stale pid file must never leave duplicate watchers racing route rules
  # and module.prop writes.
  reap_keep="${1:-}"
  reap_targets=""
  for reap_pid in $(watcher_pids); do
    [ "$reap_pid" = "$$" ] && continue
    if [ -n "$reap_keep" ] && [ "$reap_pid" = "$reap_keep" ]; then
      continue
    fi
    reap_targets="$reap_targets $reap_pid"
    kill "$reap_pid" >/dev/null 2>&1 || true
  done
  [ -n "$reap_targets" ] || return 0
  sleep 1
  for reap_pid in $reap_targets; do
    if kill -0 "$reap_pid" >/dev/null 2>&1; then
      kill -9 "$reap_pid" >/dev/null 2>&1 || true
    fi
  done
}

watcher_running() {
  [ -f "$watch_pid_file" ] || return 1
  pid="$(cat "$watch_pid_file" 2>/dev/null || true)"
  [ -n "$pid" ] && kill -0 "$pid" >/dev/null 2>&1
}

start_watcher() {
  if watcher_running; then
    reap_extra_watchers "$(cat "$watch_pid_file" 2>/dev/null || true)"
    return 0
  fi
  reap_extra_watchers ""
  nohup "$0" watch </dev/null >/dev/null 2>&1 &
  echo "$!" > "$watch_pid_file"
}

stop_watcher() {
  if watcher_running; then
    pid="$(cat "$watch_pid_file" 2>/dev/null || true)"
    kill "$pid" >/dev/null 2>&1 || true
  fi
  reap_extra_watchers ""
  rm -f "$watch_pid_file"
}

case "${1:-update}" in
  update)
    write_module_prop
    ;;
  start)
    start_watcher
    ;;
  watch)
    # Watchdog state (see watchdog_check). wd_restarts is persisted so a
    # restarted watcher does not get a fresh restart budget.
    wd_fails=0
    wd_healthy=0
    wd_gave_up=0
    wd_restarts="$(cat "$NB_RUN_DIR/watchdog.count" 2>/dev/null || true)"
    case "$wd_restarts" in '' | *[!0-9]*) wd_restarts=0 ;; esac
    seconds_to_status=0
    connection_state=other
    cached_status_blob=""
    while true; do
      daemon_present=0
      status_probe=0
      status_blob=""
      if [ -f "$NB_RUN_DIR/status.probe" ]; then
        rm -f "$NB_RUN_DIR/status.probe"
        seconds_to_status=0
      fi

      # Process presence is checked on every 30-second heartbeat. Status IPC
      # is independently scheduled: 30 seconds while connected/unknown and
      # 300 seconds after a confirmed intentional disconnect.
      if daemon_running; then
        daemon_present=1
        if [ "$seconds_to_status" -gt 0 ]; then
          seconds_to_status=$((seconds_to_status - heartbeat_interval))
        fi
        if [ "$seconds_to_status" -le 0 ]; then
          status_blob="$(status_json)"
          cached_status_blob="$status_blob"
          status_probe=1
          connection_state="$(watch_connection_state "$status_blob")"
          if [ "$connection_state" = "idle" ]; then
            seconds_to_status="$idle_probe_interval"
          else
            seconds_to_status="$connected_probe_interval"
          fi
        else
          status_blob="$cached_status_blob"
        fi
      else
        seconds_to_status=0
        connection_state=other
        cached_status_blob=""
      fi

      # Keep underlay routes fresh while a tunnel may be active; a confirmed
      # disconnect has no route work to perform.
      if [ "$daemon_present" -eq 1 ] && [ "$connection_state" != "idle" ] &&
        [ -x "$NB_SCRIPTS_DIR/netbird.service" ]; then
        "$NB_SCRIPTS_DIR/netbird.service" route >/dev/null 2>&1 || true
      fi

      watchdog_check "$status_blob" "$status_probe" "$daemon_present"
      evaluate_rules || true
      write_module_prop "$status_blob" >/dev/null 2>&1 || true
      sleep "$heartbeat_interval"
    done
    ;;
  stop)
    stop_watcher
    write_module_prop
    ;;
  peers)
    print_peers
    ;;
  *)
    echo "usage: module-status.sh {update|start|stop|watch|peers}"
    exit 1
    ;;
esac
