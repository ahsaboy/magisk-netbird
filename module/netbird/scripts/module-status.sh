#!/system/bin/sh

DIR=$(dirname "$(realpath "$0")")
. "$DIR/../settings.sh"

prop_update_interval="${NB_PROP_UPDATE_INTERVAL:-60}"
watch_pid_file="$NB_RUN_DIR/module-status.pid"
default_description="NetBird CLI daemon for Magisk with DNS management disabled by default."

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

status_field() {
  key="$1"
  awk -F': ' -v key="$key" '$1 == key { print $2; exit }'
}

clean_value() {
  tr '\r\n' '  ' |
    sed 's/[[:cntrl:]]//g; s/  */ /g; s/^ *//; s/ *$//'
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

short_peers() {
  peers="$1"
  echo "$peers" | awk '{
    if ($2 == "Connected" || $3 == "Connected") {
      print $1
    } else {
      print $0
    }
  }'
}

short_available() {
  value="$1"
  echo "$value" | awk '{
    if ($2 == "Available" || $3 == "Available") {
      print $1
    } else {
      print $0
    }
  }'
}

# `netbird status --json` with a hard timeout so a wedged socket cannot hang
# the watcher (used by the watchdog probe and the peer details below).
status_json() {
  if command -v busybox >/dev/null 2>&1; then
    busybox timeout 10 netbird --daemon-addr "$NB_DAEMON_ADDR" status --json 2>/dev/null
  else
    netbird --daemon-addr "$NB_DAEMON_ADDR" status --json 2>/dev/null
  fi
}

daemon_responsive() {
  if command -v busybox >/dev/null 2>&1; then
    busybox timeout 10 netbird --daemon-addr "$NB_DAEMON_ADDR" status >/dev/null 2>&1
  else
    netbird --daemon-addr "$NB_DAEMON_ADDR" status >/dev/null 2>&1
  fi
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
# Probe daemon health once per watch cycle; after NB_WATCHDOG_FAILS consecutive
# failures kill and restart it (bounded by NB_WATCHDOG_MAX_RESTARTS, budget
# reset after NB_WATCHDOG_HEALTHY_CYCLES healthy cycles). Only acts when the
# last start/stop marked the daemon as desired-up and a login state exists.
watchdog_check() {
  [ "$NB_WATCHDOG" = "off" ] && return 0
  [ -f "$NB_RUN_DIR/netbird.desired" ] || return 0
  [ -f "$NB_STATE_DIR/state.json" ] || return 0

  if daemon_running && daemon_responsive; then
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
    kill -15 "$wd_pid"2>/dev/null || true
  done
  [ -n "$wd_pids" ] && sleep 3
  if command -v busybox >/dev/null 2>&1; then
    wd_pids="$(busybox pgrep -f "$NB_DAEMON_CMD" 2>/dev/null)"
  else
    wd_pids=""
  fi
  for wd_pid in $wd_pids; do
    kill -9 "$wd_pid"2>/dev/null || true
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

  status_text="$(netbird --daemon-addr "$NB_DAEMON_ADDR" status 2>/dev/null || true)"
  if [ -z "$status_text" ]; then
    echo "NB=running | Status=unavailable  Mem=$mem | CA=$cas  Upd=$now"
    return 0
  fi

  fqdn="$(printf '%s\n' "$status_text" | status_field "FQDN" | clean_value)"
  ip="$(printf '%s\n' "$status_text" | status_field "NetBird IP" | clean_value)"
  ipv6="$(printf '%s\n' "$status_text" | status_field "NetBird IPv6" | clean_value)"
  peers="$(printf '%s\n' "$status_text" | status_field "Peers count" | clean_value)"
  peers="$(short_peers "$peers" | clean_value)"
  management="$(printf '%s\n' "$status_text" | status_field "Management" | clean_value)"
  signal="$(printf '%s\n' "$status_text" | status_field "Signal" | clean_value)"
  relays="$(printf '%s\n' "$status_text" | status_field "Relays" | clean_value)"
  relays="$(short_available "$relays" | clean_value)"
  iface="$(printf '%s\n' "$status_text" | status_field "Interface type" | clean_value)"
  port="$(printf '%s\n' "$status_text" | status_field "Wireguard port" | clean_value)"

  # Direct/relay split of connected peers from status --json (best effort).
  dr_txt=""
  json_blob="$(status_json)"
  if [ -n "$json_blob" ]; then
    set -- $(peer_dr_counts "$json_blob")
    case "$1$2" in
      '' | *[!0-9]*) ;;
      *)
        if [ "$1" -gt 0 ] || [ "$2" -gt 0 ]; then
          dr_txt=" [P$1 R$2]"
        fi
        ;;
    esac
  fi
  unset json_blob

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
  [ -n "$signal" ] && summary="$summary  Sig=$signal"
  [ -n "$relays" ] && summary="$summary | Relay=$relays"
  if [ -n "$iface" ] && [ -n "$port" ]; then
    summary="$summary  IF=$iface:$port"
  elif [ -n "$iface" ]; then
    summary="$summary  IF=$iface"
  fi
  summary="$summary$wd_txt | CA=$cas  Upd=$now"

  printf '%s\n' "$summary" | clean_value
}

write_module_prop() {
  prop_files="$(module_prop_paths)"
  [ -n "$prop_files" ] || return 0
  description="$(build_description)"
  [ -n "$description" ] || description="$default_description"

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
    while true; do
      # Re-check the Android route rule regularly so a Wi-Fi/cellular switch
      # does not leave the daemon with a stale routing table lookup.
      if [ -x "$NB_SCRIPTS_DIR/netbird.service" ]; then
        "$NB_SCRIPTS_DIR/netbird.service" route >/dev/null 2>&1 || true
      fi
      watchdog_check
      write_module_prop >/dev/null 2>&1 || true
      sleep "$prop_update_interval"
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
