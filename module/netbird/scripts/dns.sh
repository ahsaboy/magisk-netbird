#!/system/bin/sh

dns_script_dir="$(dirname "$(realpath "$0")")"
. "$dns_script_dir/../settings.sh"
dns_self="$dns_script_dir/dns.sh"
dns_helper="$NB_BIN_DIR/nb-dns"
dns_wanted="$NB_DIR/dns.enabled"
dns_state="$NB_DIR/dns-state"
dns_pid_file="$dns_state/helper.pid"
dns_config="$dns_state/helper.json"
dns_health="$dns_state/health"
dns_lock="$dns_state/lock"
dns_suspended="$NB_RUN_DIR/dns.suspended"
dns_connectivity_file="$NB_RUN_DIR/dns-connectivity.$$"
dns_listen=5354
# Module marks only use bits 21-31. Android owns bits 0-20 (netId, explicit,
# protected-from-VPN, permission and billing bits) and they must survive.
dns_mark_mask=0xffe00000
dns_mark_upstream=0x4e400000
dns_mark_tproxy=0x4e600000
dns_mark_helper=0x4ea00000
dns_android_mask=0x1fffff
dns_pref_upstream=84
dns_pref_tproxy=85
dns_tproxy_table=7121
case "${NB_DNS_ROOT:-intercept}" in
  bypass) dns_root_mode=bypass ;;
  *) dns_root_mode=intercept ;;
esac
dns_ipv6=off
dns_target=""
dns_fallback=false
dns_private=""
dns_dot=false
dns_default_netid=""
dns_vpn_ifaces=""
dns_boot="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)"
umask 077

# netd and other tools hold the xtables lock briefly; wait instead of failing.
iptables() { command iptables -w 5 "$@"; }
ip6tables() { command ip6tables -w 5 "$@"; }

dns_enabled() {
  [ "$(cat "$dns_wanted" 2>/dev/null)" = 1 ]
}

# Any trace of module-owned kernel state or a helper process.
dns_has_state() {
  [ -f "$dns_state/owned" ] || [ -f "$dns_state/redirected" ] || [ -f "$dns_state/tproxy" ] ||
    [ -f "$dns_state/routes" ] || [ -f "$dns_pid_file" ]
}

# Ownership is recorded per resource, only after the module created it, so a
# failed start never removes a chain or table that belongs to another tool.
dns_owner_file() {
  printf '%s/own.%s.%s.%s' "$dns_state" "$1" "$2" "$3"
}

# "owned" carries a format tag and the boot it belongs to: records from
# another boot describe kernel state that no longer exists.
dns_mark_owned() {
  printf 'per-resource %s\n' "$dns_boot" > "$dns_state/owned"
}

# Records are written before a resource is created, so a process killed in
# between never leaves an unrecorded rule behind; a failed create (another
# tool owns the name) withdraws the record at once.
dns_chain_new() {
  dns_new_owner="$(dns_owner_file "$1" "$2" "$3")"
  : > "$dns_new_owner"
  dns_mark_owned
  "$1" -t "$2" -N "$3" || {
    rm -f "$dns_new_owner"
    return 1
  }
}

dns_field() {
  case "$1" in '' | *[!A-Za-z0-9_.:,\[\]-]*) printf '%s' "${2:--}" ;; *) printf '%s' "$1" ;; esac
}

dns_status() {
  dns_requested=false
  dns_enabled && dns_requested=true
  dns_phase=off
  dns_reason=none
  dns_v6=off
  dns_resolver=-
  dns_fb=false
  dns_pd=-
  dns_vpn=-
  dns_dt=false
  if [ -f "$dns_state/status" ]; then
    read -r dns_phase dns_reason dns_v6 dns_resolver dns_fb dns_pd dns_vpn dns_dt < "$dns_state/status"
  elif dns_enabled; then
    dns_phase=waiting
  fi
  case "$dns_phase" in off | waiting | active | error | cleanup-pending) ;; *) dns_phase=error ;; esac
  if [ "$dns_phase" = active ] && ! dns_running; then
    dns_phase=error
    dns_reason=forwarder-stopped
  fi
  case "$dns_reason" in '' | *[!a-z0-9-]*) dns_reason=unknown ;; esac
  case "$dns_v6" in nat | tproxy | reject | none | off) ;; *) dns_v6=off ;; esac
  case "$dns_resolver" in - | *[!0-9a-fA-F:.\[\]]*) dns_resolver="" ;; esac
  case "$dns_pd" in off | opportunistic | hostname) ;; *) dns_pd="" ;; esac
  case "$dns_vpn" in - | *[!A-Za-z0-9_.,-]*) dns_vpn="" ;; esac
  [ "$dns_fb" = true ] || dns_fb=false
  [ "$dns_dt" = true ] || dns_dt=false
  dns_hl=""
  if [ "$dns_phase" = active ]; then
    dns_hl="$(cat "$dns_health" 2>/dev/null)"
    case "$dns_hl" in ok | degraded) ;; *) dns_hl=ok ;; esac
  fi
  printf '{"enabled":%s,"state":"%s","reason":"%s","ipv6":"%s","resolver":"%s","fallback":%s,"privateDns":"%s","privateDnsActive":%s,"vpn":"%s","health":"%s","root":"%s"}\n' \
    "$dns_requested" "$dns_phase" "$dns_reason" "$dns_v6" "$dns_resolver" "$dns_fb" "$dns_pd" "$dns_dt" "$dns_vpn" "$dns_hl" "$dns_root_mode"
}

dns_write_status() {
  mkdir -p "$dns_state"
  printf '%s %s %s %s %s %s %s %s\n' "$1" "$2" "$3" "$(dns_field "$4")" "$5" "$(dns_field "$6")" "$(dns_field "$7")" "$8" > "$dns_state/status.tmp.$$" || return 1
  # Skip identical rewrites: the watcher reconciles on every heartbeat.
  if cmp -s "$dns_state/status.tmp.$$" "$dns_state/status" 2>/dev/null; then
    rm -f "$dns_state/status.tmp.$$"
  else
    mv -f "$dns_state/status.tmp.$$" "$dns_state/status"
  fi
}

dns_publish() {
  dns_vpn_list="$(printf '%s' "$dns_vpn_ifaces" | tr '\n' ',' | sed 's/,$//')"
  dns_write_status "$1" "$2" "$dns_ipv6" "$dns_target" "$dns_fallback" "$dns_private" "$dns_vpn_list" "$dns_dot"
}

# A kernel file lock: released when its holder exits, however it exits. It
# lives in dns-state because upgrades reset the run directory.
dns_lock_acquire() {
  mkdir -p "$dns_state"
  exec 9> "$dns_lock" || return 1
  # Android's toybox flock has no -w, so poll the non-blocking form. mksh
  # opens exec'd descriptors close-on-exec: hand fd 9 to flock explicitly.
  dns_lock_tries=$(($1 * 10))
  until flock -n 9 9>&9; do
    dns_lock_tries=$((dns_lock_tries - 1))
    [ "$dns_lock_tries" -gt 0 ] || return 1
    sleep 0.1
  done
}

dns_ip() {
  dns_family="$1"
  shift
  if [ "$dns_family" = 6 ]; then ip -6 "$@"; else ip -4 "$@"; fi
}

dns_table() {
  dns_table_name="$(dns_ip "$1" rule show | awk '/fwmark 0x0\/0xffff/ && /iif lo/ && /lookup/ {
    for (field=1; field<=NF; field++) if ($field == "lookup") { print $(field+1); exit }
  }')"
  case "$dns_table_name" in
    '') return 1 ;;
    main) dns_table_id=254 ;;
    *[!0-9]*)
      case "$dns_table_name" in *[!A-Za-z0-9_.-]*) return 1 ;; esac
      dns_ifindex="$(cat "/sys/class/net/$dns_table_name/ifindex" 2>/dev/null)"
      case "$dns_ifindex" in '' | *[!0-9]*) return 1 ;; esac
      dns_table_id=$((dns_ifindex + 1000))
      ;;
    *) dns_table_id="$dns_table_name" ;;
  esac
  dns_ip "$1" route show table "$dns_table_id" | grep -q '^default ' || return 1
  printf '%s\n' "$dns_table_id"
}

dns_running() {
  [ -f "$dns_pid_file" ] || return 1
  read -r dns_process dns_start < "$dns_pid_file"
  case "$dns_process" in '' | *[!0-9]*) return 1 ;; esac
  [ -n "$dns_start" ] || return 1
  [ "$(awk '{print $22}' "/proc/$dns_process/stat" 2>/dev/null)" = "$dns_start" ] || return 1
  tr '\000' ' ' < "/proc/$dns_process/cmdline" 2>/dev/null | grep -Fq "$dns_helper serve $dns_config"
}

# The helper answers on every listener it owns; any valid reply counts.
dns_alive() {
  "$dns_helper" probe "127.0.0.1:$dns_listen" >/dev/null 2>&1 || return 1
  case "$dns_ipv6:$(cat "$dns_state/listeners" 2>/dev/null)" in
    nat:none | tproxy:none) ;;
    nat:* | tproxy:*) "$dns_helper" probe "[::1]:$dns_listen" >/dev/null 2>&1 ;;
  esac
}

dns_helper_start() {
  rm -f "$dns_health" "$dns_state/listeners"
  nohup "$dns_helper" serve "$dns_config" </dev/null > "$NB_RUN_DIR/dns.log" 2>&1 9>&- &
  dns_process=$!
  dns_start="$(awk '{print $22}' "/proc/$dns_process/stat" 2>/dev/null)"
  if [ -n "$dns_start" ] && printf '%s %s\n' "$dns_process" "$dns_start" > "$dns_pid_file"; then
    for dns_try in 1 2 3 4 5 6; do
      kill -0 "$dns_process" 2>/dev/null || break
      if [ -f "$dns_state/listeners" ] && dns_alive && kill -0 "$dns_process" 2>/dev/null; then
        return 0
      fi
      sleep 0.5
    done
  fi
  if kill -TERM "$dns_process" 2>/dev/null; then
    sleep 0.5
    kill -KILL "$dns_process" 2>/dev/null || true
  fi
  rm -f "$dns_pid_file"
  dns_fail helper-unavailable
}

# 0: the chain exists; 1: it does not (exit 1: no such chain, 3: no such
# table); 2: unknown, such as an xtables lock timeout (exit 4).
dns_chain_state() {
  "$1" -t "$2" -S "$3" >/dev/null 2>&1
  case "$?" in
    0) return 0 ;;
    1 | 3) return 1 ;;
    *) return 2 ;;
  esac
}

# Removes every jump from the parent to a chain the module created, then the chain.
dns_chain_remove() {
  dns_rm_firewall="$1"
  dns_rm_table="$2"
  dns_rm_chain="$3"
  dns_rm_parent="${4:-OUTPUT}"
  dns_rm_owner="$(dns_owner_file "$1" "$2" "$3")"
  [ -f "$dns_rm_owner" ] || return 0
  dns_chain_state "$dns_rm_firewall" "$dns_rm_table" "$dns_rm_chain"
  case "$?" in
    1)
      rm -f "$dns_rm_owner"
      return 0
      ;;
    2) return 1 ;;
  esac
  "$dns_rm_firewall" -t "$dns_rm_table" -S "$dns_rm_parent" 2>/dev/null | grep -- "-j $dns_rm_chain\$" |
    while read -r dns_rm_rule; do
      # shellcheck disable=SC2086 # the saved rule is re-split into arguments.
      "$dns_rm_firewall" -t "$dns_rm_table" -D ${dns_rm_rule#-A } || exit 1
    done || return 1
  "$dns_rm_firewall" -t "$dns_rm_table" -F "$dns_rm_chain" >/dev/null 2>&1 || return 1
  "$dns_rm_firewall" -t "$dns_rm_table" -X "$dns_rm_chain" >/dev/null 2>&1 || return 1
  rm -f "$dns_rm_owner"
}

dns_tproxy_remove() {
  dns_tp_rc=0
  dns_chain_remove ip6tables mangle NBMOD_DNS6 || dns_tp_rc=1
  for dns_protocol in udp tcp; do
    while ip6tables -t mangle -C PREROUTING -i lo -m mark --mark "$dns_mark_tproxy/$dns_mark_mask" \
      -p "$dns_protocol" --dport 53 -j TPROXY --on-ip ::1 --on-port "$dns_listen" >/dev/null 2>&1; do
      ip6tables -t mangle -D PREROUTING -i lo -m mark --mark "$dns_mark_tproxy/$dns_mark_mask" \
        -p "$dns_protocol" --dport 53 -j TPROXY --on-ip ::1 --on-port "$dns_listen" || {
        dns_tp_rc=1
        break
      }
    done
  done
  while dns_rule_present 6 "$dns_pref_tproxy" "$dns_mark_tproxy"; do
    ip -6 rule del pref "$dns_pref_tproxy" fwmark "$dns_mark_tproxy/$dns_mark_mask" lookup "$dns_tproxy_table" || {
      dns_tp_rc=1
      break
    }
  done
  if [ -f "$dns_state/own.route6.$dns_tproxy_table" ]; then
    if ip -6 route show table "$dns_tproxy_table" 2>/dev/null | grep -Eq '^local (default|::/0) dev lo'; then
      ip -6 route del local ::/0 dev lo table "$dns_tproxy_table" || dns_tp_rc=1
    fi
    [ "$dns_tp_rc" = 0 ] && rm -f "$dns_state/own.route6.$dns_tproxy_table"
  fi
  [ "$dns_tp_rc" = 0 ] && rm -f "$dns_state/tproxy"
  return "$dns_tp_rc"
}

dns_cleanup() {
  dns_cleanup_rc=0
  if [ -f "$dns_state/owned" ]; then
    dns_owned_format=""
    dns_owned_boot=""
    read -r dns_owned_format dns_owned_boot < "$dns_state/owned"
    if [ -n "$dns_owned_boot" ] && [ -n "$dns_boot" ] && [ "$dns_owned_boot" != "$dns_boot" ]; then
      # A reboot cleared every rule; never act on records from before it.
      rm -f "$dns_state"/own.* "$dns_state/routes" "$dns_state/tproxy" "$dns_state/redirected" "$dns_state/owned"
    fi
  fi
  # 1. Stop redirecting new queries before touching the helper.
  dns_chain_remove iptables nat NBMOD_DNS4 || dns_cleanup_rc=1
  dns_chain_remove ip6tables nat NBMOD_DNS6 || dns_cleanup_rc=1
  dns_chain_remove ip6tables filter NBMOD_DNS6R || dns_cleanup_rc=1
  if [ -f "$dns_state/tproxy" ]; then
    dns_tproxy_remove || dns_cleanup_rc=1
  fi
  # Without the helper binary the translated flows cannot be flushed; they
  # expire on their own once the redirect is gone.
  if [ -f "$dns_state/redirected" ] && [ -x "$dns_helper" ]; then
    "$dns_helper" cleanup >/dev/null 2>&1 || dns_cleanup_rc=1
  fi
  if [ "$dns_cleanup_rc" -ne 0 ]; then
    # Keep the helper serving: rules that still redirect need a listener.
    dns_publish cleanup-pending cleanup-failed
    return 1
  fi
  # 2. No query reaches the helper any more.
  if dns_running; then
    kill "$dns_process" 2>/dev/null || true
    dns_wait=0
    while dns_running && [ "$dns_wait" -lt 30 ]; do
      sleep 0.1
      dns_wait=$((dns_wait + 1))
    done
    if dns_running; then kill -9 "$dns_process" 2>/dev/null || true; fi
  fi
  rm -f "$dns_pid_file" "$dns_config" "$dns_health" "$dns_state/listeners"
  # 3. Root upstream routing exception.
  dns_chain_remove iptables mangle NBMOD_DNS_UP4 || dns_cleanup_rc=1
  dns_chain_remove ip6tables mangle NBMOD_DNS_UP6 || dns_cleanup_rc=1
  if [ "$dns_cleanup_rc" -eq 0 ] && [ -f "$dns_state/routes" ]; then
    while read -r dns_family dns_route_table; do
      [ -n "$dns_family" ] || continue
      dns_ip "$dns_family" rule del pref "$dns_pref_upstream" fwmark "$dns_mark_upstream/$dns_mark_mask" \
        lookup "$dns_route_table" >/dev/null 2>&1 || {
        dns_upstream_rule_state=0
        dns_rule_present "$dns_family" "$dns_pref_upstream" "$dns_mark_upstream" || dns_upstream_rule_state=$?
        [ "$dns_upstream_rule_state" -eq 1 ] || dns_cleanup_rc=1
      }
    done < "$dns_state/routes"
  fi
  if [ "$dns_cleanup_rc" -eq 0 ]; then
    dns_chain_remove iptables nat NBMOD_DNS_SNAT4 POSTROUTING || dns_cleanup_rc=1
    dns_chain_remove ip6tables nat NBMOD_DNS_SNAT6 POSTROUTING || dns_cleanup_rc=1
  fi
  if [ "$dns_cleanup_rc" -ne 0 ]; then
    dns_publish cleanup-pending route-cleanup-failed
    return 1
  fi
  rm -f "$dns_state/routes" "$dns_state/owned" "$dns_state/redirected" "$dns_state/fingerprint" "$dns_state/ipv6" "$dns_state/name" "$dns_state/rules"
  dns_write_status off none off - false - - false
}

# Cleans up while the switch stays on (disconnect, stop, profile switch):
# report it as waiting rather than off.
dns_park() {
  dns_cleanup || return 1
  if dns_enabled; then dns_write_status waiting disconnected off - false - - false; fi
}

dns_fail() {
  dns_failure="$1"
  dns_cleanup || return 1
  dns_publish error "$dns_failure"
  return 1
}

# Exemptions shared by every interception backend. The helper and the root
# upstream exception carry module marks; root queries are intercepted except
# those addressed to NetBird's own upstreams and bootstrap resolvers.
dns_exempt() {
  dns_ex_firewall="$1"
  dns_ex_table="$2"
  dns_ex_chain="$3"
  dns_ex_family="$4"
  "$dns_ex_firewall" -t "$dns_ex_table" -A "$dns_ex_chain" -m mark --mark "$dns_mark_helper/$dns_mark_mask" -j RETURN || return 1
  "$dns_ex_firewall" -t "$dns_ex_table" -A "$dns_ex_chain" -m mark --mark "$dns_mark_upstream/$dns_mark_mask" -j RETURN || return 1
  if [ -n "$dns_default_netid" ]; then
    "$dns_ex_firewall" -t "$dns_ex_table" -A "$dns_ex_chain" \
      -m mark ! --mark 0/0xffff -m mark ! --mark "$dns_default_netid/0xffff" -j RETURN || return 1
  fi
  while read -r dns_ex_listener_family dns_ex_protocol dns_ex_scope; do
    [ "$dns_ex_listener_family" = "$dns_ex_family" ] || continue
    case "$dns_ex_scope:$dns_ex_family" in
      loopback:4) set -- -d 127.0.0.0/8 ;;
      loopback:6) set -- -d ::1/128 ;;
      wildcard:*) set -- -o lo ;;
      *) continue ;;
    esac
    "$dns_ex_firewall" -t "$dns_ex_table" -A "$dns_ex_chain" "$@" -p "$dns_ex_protocol" -j RETURN || return 1
  done <<EOF
$dns_local_resolvers
EOF
  if [ "$dns_root_mode" = bypass ]; then
    "$dns_ex_firewall" -t "$dns_ex_table" -A "$dns_ex_chain" -m owner --uid-owner 0 -j RETURN || return 1
  else
    for dns_ex_address in $(awk -v family="$dns_ex_family" '$1 == family {print $2}' "$dns_exempt_next"); do
      "$dns_ex_firewall" -t "$dns_ex_table" -A "$dns_ex_chain" -m owner --uid-owner 0 -d "$dns_ex_address" -j RETURN || return 1
    done
  fi
  "$dns_ex_firewall" -t "$dns_ex_table" -A "$dns_ex_chain" -o tun+ -j RETURN || return 1
  for dns_ex_iface in $dns_vpn_ifaces; do
    "$dns_ex_firewall" -t "$dns_ex_table" -A "$dns_ex_chain" -o "$dns_ex_iface" -j RETURN || return 1
  done
  # The helper routes a fallback query with the original Android mark.
  "$dns_ex_firewall" -t "$dns_ex_table" -A "$dns_ex_chain" -j CONNMARK --save-mark \
    --nfmask "$dns_android_mask" --ctmask "$dns_android_mask" || return 1
}

dns_chain_create() {
  dns_firewall="$1"
  dns_chain="$2"
  dns_destination="$3"
  dns_chain_new "$dns_firewall" nat "$dns_chain" || return 1
  dns_exempt "$dns_firewall" nat "$dns_chain" "$4" || return 1
  for dns_protocol in udp tcp; do
    "$dns_firewall" -t nat -A "$dns_chain" -p "$dns_protocol" --dport 53 \
      -j DNAT --to-destination "$dns_destination" || return 1
    "$dns_firewall" -t nat -A OUTPUT -p "$dns_protocol" --dport 53 -j "$dns_chain" || return 1
  done
}

dns_rule_present() {
  dns_rule_list="$(dns_ip "$1" rule show)" || return 2
  printf '%s\n' "$dns_rule_list" | awk -v pref="$2:" -v mark="$3/$dns_mark_mask" \
    '$1 == pref && index($0, "fwmark " mark) {found=1} END {exit !found}'
}

# Every rule of the backends recorded in dns-state must still be in place;
# a missing one (removed by another tool or a firewall reload) forces a
# rebuild instead of reporting a partial redirect as active.
dns_rules_present() {
  for dns_protocol in udp tcp; do
    iptables -t nat -C OUTPUT -p "$dns_protocol" --dport 53 -j NBMOD_DNS4 >/dev/null 2>&1 || return 1
    case "$dns_ipv6" in
      nat) ip6tables -t nat -C OUTPUT -p "$dns_protocol" --dport 53 -j NBMOD_DNS6 >/dev/null 2>&1 || return 1 ;;
      tproxy)
        ip6tables -t mangle -C OUTPUT -p "$dns_protocol" --dport 53 -j NBMOD_DNS6 >/dev/null 2>&1 || return 1
        ip6tables -t mangle -C PREROUTING -i lo -m mark --mark "$dns_mark_tproxy/$dns_mark_mask" \
          -p "$dns_protocol" --dport 53 -j TPROXY --on-ip ::1 --on-port "$dns_listen" >/dev/null 2>&1 || return 1
        ;;
      reject) ip6tables -t filter -C OUTPUT -p "$dns_protocol" --dport 53 -j NBMOD_DNS6R >/dev/null 2>&1 || return 1 ;;
    esac
  done
  if [ "$dns_ipv6" = tproxy ]; then
    dns_rule_present 6 "$dns_pref_tproxy" "$dns_mark_tproxy" || return 1
    ip -6 route show table "$dns_tproxy_table" 2>/dev/null | grep -Eq '^local (default|::/0) dev lo' || return 1
  fi
  while read -r dns_family dns_route_table; do
    [ -n "$dns_family" ] || continue
    dns_rule_present "$dns_family" "$dns_pref_upstream" "$dns_mark_upstream" || return 1
    dns_check_firewall=iptables
    [ "$dns_family" = 6 ] && dns_check_firewall=ip6tables
    "$dns_check_firewall" -t mangle -C OUTPUT -j "NBMOD_DNS_UP$dns_family" >/dev/null 2>&1 || return 1
    "$dns_check_firewall" -t nat -C POSTROUTING -j "NBMOD_DNS_SNAT$dns_family" >/dev/null 2>&1 || return 1
  done < "$dns_state/routes"
}

# The module's chains belong to it alone, so their full contents must match
# what was installed: a flushed chain or a deleted DNAT, MARK or MASQUERADE
# rule leaves the jumps in place but breaks query routing.
dns_rules_snapshot() {
  for dns_snap_owner in "$dns_state"/own.*; do
    [ -f "$dns_snap_owner" ] || continue
    dns_snap_name="${dns_snap_owner##*/own.}"
    case "$dns_snap_name" in route6.*) continue ;; esac
    dns_snap_firewall="${dns_snap_name%%.*}"
    dns_snap_rest="${dns_snap_name#*.}"
    dns_snap_table="${dns_snap_rest%%.*}"
    dns_snap_chain="${dns_snap_rest#*.}"
    printf '%s %s\n' "$dns_snap_firewall" "$dns_snap_table"
    "$dns_snap_firewall" -t "$dns_snap_table" -S "$dns_snap_chain" 2>/dev/null || printf 'missing\n'
  done
}

dns_tproxy_conflict() {
  ip -6 rule show | awk -v pref="$dns_pref_tproxy:" '$1 == pref {found=1} END {exit !found}' ||
    [ -n "$(ip -6 route show table "$dns_tproxy_table" 2>/dev/null)" ] ||
    ip6tables -t mangle -S NBMOD_DNS6 >/dev/null 2>&1
}

dns_tproxy_create() {
  : > "$dns_state/tproxy"
  : > "$dns_state/own.route6.$dns_tproxy_table"
  dns_mark_owned
  ip -6 route add local ::/0 dev lo table "$dns_tproxy_table" || {
    rm -f "$dns_state/own.route6.$dns_tproxy_table"
    return 1
  }
  ip -6 rule add pref "$dns_pref_tproxy" fwmark "$dns_mark_tproxy/$dns_mark_mask" lookup "$dns_tproxy_table" || return 1
  dns_chain_new ip6tables mangle NBMOD_DNS6 || return 1
  dns_exempt ip6tables mangle NBMOD_DNS6 6 || return 1
  for dns_protocol in udp tcp; do
    ip6tables -t mangle -A NBMOD_DNS6 -p "$dns_protocol" --dport 53 -j MARK --set-xmark "$dns_mark_tproxy/$dns_mark_mask" || return 1
    ip6tables -t mangle -A PREROUTING -i lo -m mark --mark "$dns_mark_tproxy/$dns_mark_mask" \
      -p "$dns_protocol" --dport 53 -j TPROXY --on-ip ::1 --on-port "$dns_listen" || return 1
    ip6tables -t mangle -A OUTPUT -p "$dns_protocol" --dport 53 -j NBMOD_DNS6 || return 1
  done
}

# Without an IPv6 backend, reject IPv6 plain DNS so Android's resolver moves
# on to an IPv4 server, which is intercepted.
dns_reject_create() {
  dns_chain_new ip6tables filter NBMOD_DNS6R || return 1
  dns_exempt ip6tables filter NBMOD_DNS6R 6 || return 1
  ip6tables -t filter -A NBMOD_DNS6R -p udp --dport 53 -j REJECT || return 1
  ip6tables -t filter -A NBMOD_DNS6R -p tcp --dport 53 -j REJECT --reject-with tcp-reset || return 1
  for dns_protocol in udp tcp; do
    ip6tables -t filter -A OUTPUT -p "$dns_protocol" --dport 53 -j NBMOD_DNS6R || return 1
  done
}

dns_list_local_resolvers() {
  for dns_socket_file in "$1/udp" "$1/udp6" "$1/tcp" "$1/tcp6"; do
    [ -r "$dns_socket_file" ] || continue
    awk 'FNR > 1 {
      protocol = FILENAME ~ /\/udp6?$/ ? "udp" : "tcp"
      family = FILENAME ~ /6$/ ? 6 : 4
      split($2, local, ":")
      if (local[2] != "0035" || (protocol == "udp" ? $4 != "07" : $4 != "0A")) next
      if (local[1] ~ /^0+$/) {
        print family, protocol, "wildcard"
        if (family == 6) print 4, protocol, "wildcard"
      } else if ((family == 4 && local[1] ~ /7F$/) || local[1] == "00000000000000000000000001000000") {
        print family, protocol, "loopback"
      }
    }' "$dns_socket_file" 2>/dev/null
  done | sort -u
}

dns_ipv6_present() {
  # procfs files report size 0, so read them instead of testing -s.
  grep -q . /proc/net/if_inet6 2>/dev/null && [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)" != 1 ]
}

dns_inspect_android() {
  dns_private="$(settings get global private_dns_mode 2>/dev/null)"
  case "$dns_private" in off | opportunistic | hostname) ;; *) dns_private=opportunistic ;; esac
  # The dump exceeds the argument limit of mksh's external printf: keep it
  # in a file rather than a variable.
  mkdir -p "$NB_RUN_DIR"
  dumpsys connectivity > "$dns_connectivity_file" 2>/dev/null
  dns_default_netid="$(awk '
    /^[[:space:]]*Active default network: [0-9]+[[:space:]]*$/ && $NF > 0 && $NF <= 65535 {print $NF + 0; exit}' "$dns_connectivity_file")"
  dns_vpn_ifaces="$(sed -n '/NetworkAgentInfo{network.*VPN CONNECTED/s/.*InterfaceName: \([A-Za-z0-9_.-]*\).*/\1/p' "$dns_connectivity_file" | sort -u)"
  dns_resolver_flags="$(dumpsys dnsresolver 2>/dev/null | awk -v netid="$dns_default_netid" '
    /^[[:space:]]*NetId: [0-9]+/ {network = $2; servers = 0}
    netid != "" && network != netid {next}
    /status\{success\}/ {dot = 1}
    /^[[:space:]]*DNS servers:/ {servers = 1; next}
    !/^    [^[:space:]]/ {servers = 0}
    servers && $1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {ipv4 = 1}
    END {print ipv4 ? 1 : 0, dot ? "true" : "false"}')"
  read -r dns_has_ipv4_server dns_dot <<EOF
$dns_resolver_flags
EOF
}

dns_sync() {
  if ! dns_enabled || [ -f "$dns_suspended" ] ||
    { [ -n "${NB_MOD_DIR:-}" ] && { [ -f "$NB_MOD_DIR/disable" ] || [ -f "$NB_MOD_DIR/remove" ]; }; }; then
    dns_park
    return "$?"
  fi
  if [ ! -x "$dns_helper" ]; then
    dns_fail helper-missing
    return 1
  fi
  if [ "$NB_DISABLE_DNS" != true ]; then
    dns_fail host-dns-conflict
    return 1
  fi
  mkdir -p "$dns_state"
  dns_status_file="$NB_RUN_DIR/dns-client-status.$$"
  dns_plan="$NB_RUN_DIR/dns-plan.$$"
  dns_routes_next="$NB_RUN_DIR/dns-routes.$$"
  dns_exempt_next="$NB_RUN_DIR/dns-exempt.$$"
  dns_fingerprint="$NB_RUN_DIR/dns-fingerprint.$$"
  trap 'rm -f "$dns_status_file" "$dns_plan" "$dns_routes_next" "$dns_exempt_next" "$dns_fingerprint" "$dns_connectivity_file"' EXIT
  if ! busybox timeout 10 netbird --daemon-addr "$NB_DAEMON_ADDR" status --json > "$dns_status_file" 2>/dev/null 9>&-; then
    dns_cleanup || return 1
    dns_publish waiting disconnected
    return 0
  fi
  if ! "$dns_helper" inspect < "$dns_status_file" > "$dns_plan" 2>/dev/null; then
    if grep -q '"daemonStatus": *"Connected"' "$dns_status_file"; then
      dns_fail resolver-unavailable
      return 1
    fi
    dns_cleanup || return 1
    dns_publish waiting disconnected
    return 0
  fi
  dns_target="$(awk '$1 == "target" {print $2}' "$dns_plan")"
  dns_name="$(awk '$1 == "name" {print $2}' "$dns_plan")"
  dns_fallback=false
  [ "$(awk '$1 == "catchall" {print $2}' "$dns_plan")" = 1 ] || dns_fallback=true
  dns_inspect_android
  : > "$dns_routes_next"
  : > "$dns_exempt_next"
  for dns_server in $(awk '$1 == "upstream" {print $2}' "$dns_plan"); do
    dns_endpoint="$("$dns_helper" endpoint "$dns_server")" || {
      dns_fail invalid-upstream
      return 1
    }
    read -r dns_family dns_address dns_port <<EOF
$dns_endpoint
EOF
    printf '%s %s\n' "$dns_family" "$dns_address" >> "$dns_exempt_next"
    dns_existing_route="$(dns_ip "$dns_family" route get "$dns_address" 2>/dev/null)"
    case "$dns_existing_route" in *' dev wt'* | *' dev wg'* | *' dev nb'* | *' dev tailscale'* | *' dev lo '*) continue ;; esac
    # No default route in this family (an IPv4-only Wi-Fi with an IPv6
    # upstream, for example): there is nothing to route around.
    dns_route_table="$(dns_table "$dns_family")" || continue
    dns_firewall=iptables
    [ "$dns_family" = 6 ] && dns_firewall=ip6tables
    "$dns_firewall" -t nat -S POSTROUTING >/dev/null 2>&1 || continue
    for dns_protocol in udp tcp; do
      printf '%s %s %s %s %s\n' "$dns_family" "$dns_address" "$dns_protocol" "$dns_port" "$dns_route_table" >> "$dns_routes_next"
    done
  done
  # NetBird's own lookups (management, relays) use the module resolv.conf.
  for dns_server in $(awk '$1 == "nameserver" {print $2}' /system/etc/resolv.conf 2>/dev/null); do
    dns_endpoint="$("$dns_helper" endpoint "$dns_server:53" 2>/dev/null)" || dns_endpoint="$("$dns_helper" endpoint "[$dns_server]:53" 2>/dev/null)" || continue
    read -r dns_family dns_address dns_port <<EOF
$dns_endpoint
EOF
    printf '%s %s\n' "$dns_family" "$dns_address" >> "$dns_exempt_next"
  done
  sort -u "$dns_exempt_next" -o "$dns_exempt_next"
  dns_local_resolvers="$(dns_list_local_resolvers /proc/net)"
  dns_ipv6=off
  if dns_ipv6_present; then
    dns_ipv6=tproxy
    ip6tables -t nat -S OUTPUT >/dev/null 2>&1 && dns_ipv6=nat
  fi
  dns_daemon_pid="$(busybox pgrep -f "$NB_DAEMON_CMD" 2>/dev/null | head -1)"
  dns_daemon_start="$(awk '{print $22}' "/proc/$dns_daemon_pid/stat" 2>/dev/null)"
  {
    cat "$dns_plan" "$dns_routes_next" "$dns_exempt_next"
    printf '%s\n%s\n%s %s %s %s\n%s %s\n' "$dns_vpn_ifaces" "$dns_local_resolvers" \
      "$dns_ipv6" "$dns_root_mode" "$dns_has_ipv4_server" "$dns_default_netid" "$dns_daemon_pid" "$dns_daemon_start"
  } > "$dns_fingerprint"
  if cmp -s "$dns_fingerprint" "$dns_state/fingerprint" && dns_running; then
    dns_planned_ipv6="$dns_ipv6"
    dns_ipv6="$(cat "$dns_state/ipv6" 2>/dev/null || echo off)"
    if dns_rules_present && dns_rules_snapshot | cmp -s - "$dns_state/rules" && dns_alive; then
      dns_publish active none
      return 0
    fi
    dns_ipv6="$dns_planned_ipv6"
  fi
  dns_cleanup || return 1
  # After cleanup any module-named chain left belongs to another tool.
  for dns_pair in 'iptables nat NBMOD_DNS4' 'ip6tables nat NBMOD_DNS6' 'ip6tables mangle NBMOD_DNS6' \
    'ip6tables filter NBMOD_DNS6R' 'iptables mangle NBMOD_DNS_UP4' 'ip6tables mangle NBMOD_DNS_UP6' \
    'iptables nat NBMOD_DNS_SNAT4' 'ip6tables nat NBMOD_DNS_SNAT6'; do
    set -- $dns_pair
    dns_chain_state "$1" "$2" "$3"
    case "$?" in
      0)
        dns_publish error chain-conflict
        return 1
        ;;
      2)
        dns_publish error firewall-busy
        return 1
        ;;
    esac
  done
  if [ "$dns_ipv6" = tproxy ] && dns_tproxy_conflict; then
    dns_publish error ipv6-rule-conflict
    return 1
  fi
  "$dns_helper" conntrack-check || {
    dns_publish error conntrack-unavailable
    return 1
  }
  : > "$dns_state/routes"
  while read -r dns_family dns_address dns_protocol dns_port dns_route_table; do
    [ -n "$dns_family" ] || continue
    dns_firewall=iptables
    [ "$dns_family" = 6 ] && dns_firewall=ip6tables
    dns_upstream_chain="NBMOD_DNS_UP$dns_family"
    dns_snat_chain="NBMOD_DNS_SNAT$dns_family"
    if ! awk -v family="$dns_family" '$1 == family {found=1} END {exit !found}' "$dns_state/routes"; then
      if dns_ip "$dns_family" rule show | awk -v pref="$dns_pref_upstream:" '$1 == pref {found=1} END {exit !found}'; then
        dns_fail route-conflict
        return 1
      fi
      dns_chain_new "$dns_firewall" nat "$dns_snat_chain" || {
        dns_fail chain-conflict
        return 1
      }
      if ! "$dns_firewall" -t nat -A "$dns_snat_chain" -m mark --mark "$dns_mark_upstream/$dns_mark_mask" -j MASQUERADE ||
        ! "$dns_firewall" -t nat -A POSTROUTING -j "$dns_snat_chain"; then
        dns_fail bypass-failed
        return 1
      fi
      dns_chain_new "$dns_firewall" mangle "$dns_upstream_chain" || {
        dns_fail chain-conflict
        return 1
      }
      "$dns_firewall" -t mangle -A "$dns_upstream_chain" -m mark --mark "$dns_mark_helper/$dns_mark_mask" -j RETURN || {
        dns_fail bypass-failed
        return 1
      }
      # Recorded first; cleanup only deletes this exact pref/mark/table rule.
      printf '%s %s\n' "$dns_family" "$dns_route_table" >> "$dns_state/routes"
      dns_ip "$dns_family" rule add pref "$dns_pref_upstream" fwmark "$dns_mark_upstream/$dns_mark_mask" lookup "$dns_route_table" || {
        dns_fail bypass-failed
        return 1
      }
      "$dns_firewall" -t mangle -A OUTPUT -j "$dns_upstream_chain" || {
        dns_fail bypass-failed
        return 1
      }
    fi
    "$dns_firewall" -t mangle -A "$dns_upstream_chain" -m owner --uid-owner 0 -d "$dns_address" \
      -p "$dns_protocol" --dport "$dns_port" -j MARK --set-xmark "$dns_mark_upstream/$dns_mark_mask" || {
      dns_fail bypass-failed
      return 1
    }
  done < "$dns_routes_next"
  "$dns_helper" config "$dns_target" "$dns_name" "$dns_state" "$dns_self" \
    $(awk '$1 == "zone" {print $2}' "$dns_plan") > "$dns_config" || {
    dns_fail invalid-resolver
    return 1
  }
  printf '%s\n' "$dns_name" > "$dns_state/name"
  dns_helper_start || return 1
  # The helper reports which IPv6 listener the kernel allowed.
  dns_listener6="$(cat "$dns_state/listeners" 2>/dev/null)"
  case "$dns_ipv6:$dns_listener6" in
    nat:none) dns_ipv6=none ;;
    tproxy:plain | tproxy:none) dns_ipv6=fallback ;;
  esac
  : > "$dns_state/redirected"
  dns_chain_create iptables NBMOD_DNS4 "127.0.0.1:$dns_listen" 4 || {
    dns_fail firewall-failed
    return 1
  }
  case "$dns_ipv6" in
    nat)
      dns_chain_create ip6tables NBMOD_DNS6 "[::1]:$dns_listen" 6 || {
        dns_fail firewall-failed
        return 1
      }
      ;;
    tproxy | fallback)
      if [ "$dns_ipv6" = fallback ] || ! dns_tproxy_create; then
        # Missing TPROXY support is a capability gap, not a reason to refuse IPv4.
        dns_tproxy_remove || {
          dns_fail ipv6-cleanup-failed
          return 1
        }
        if [ "$dns_has_ipv4_server" = 1 ]; then
          dns_reject_create || {
            dns_fail firewall-failed
            return 1
          }
          dns_ipv6=reject
        else
          dns_ipv6=none
        fi
      fi
      ;;
  esac
  printf '%s\n' "$dns_ipv6" > "$dns_state/ipv6"
  dns_rules_snapshot > "$dns_state/rules"
  mv -f "$dns_fingerprint" "$dns_state/fingerprint"
  dns_publish active none
}

case "${1:-status}" in
  status)
    dns_status
    exit 0
    ;;
  on | off | sync | suspend | resume | cleanup | check) [ "$#" = 1 ] || exit 2 ;;
  *)
    echo 'usage: dns.sh {on|off|status|check|sync|suspend|resume|cleanup}' >&2
    exit 2
    ;;
esac
# Lifecycle hooks run on every start, stop and heartbeat. With the switch off
# and nothing owned they must be free: no lock, no state writes.
case "$1" in
  sync | suspend | resume | cleanup)
    if ! dns_enabled && ! dns_has_state; then exit 0; fi
    ;;
esac
# Reconciles wait as long as user actions: a network change must not be
# dropped because a heartbeat holds the lock.
dns_lock_acquire 20 || {
  echo 'DNS operation already running' >&2
  exit 1
}
case "$1" in
  on | off)
    dns_value=0
    [ "$1" = on ] && dns_value=1
    printf '%s\n' "$dns_value" > "$dns_wanted.tmp.$$" && mv -f "$dns_wanted.tmp.$$" "$dns_wanted" || exit 1
    rm -f "$dns_suspended"
    dns_sync
    dns_rc="$?"
    dns_status
    exit "$dns_rc"
    ;;
  suspend)
    : > "$dns_suspended"
    dns_park
    ;;
  resume)
    rm -f "$dns_suspended"
    dns_sync
    ;;
  sync) dns_sync ;;
  cleanup)
    : > "$dns_suspended"
    dns_park
    ;;
  check)
    dns_running || exit 1
    dns_name="$(cat "$dns_state/name" 2>/dev/null)"
    [ -n "$dns_name" ] || exit 1
    "$dns_helper" check "127.0.0.1:$dns_listen" "$dns_name"
    ;;
esac
