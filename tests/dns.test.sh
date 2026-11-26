#!/bin/sh
set -eu

dns_repo="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
dns_fixture="$(mktemp -d)"
trap 'rm -rf "$dns_fixture"' EXIT INT TERM
mkdir -p "$dns_fixture/scripts" "$dns_fixture/bin"
cp "$dns_repo/module/netbird/settings.sh" "$dns_fixture/settings.sh"
cp "$dns_repo/module/netbird/scripts/dns.sh" "$dns_fixture/scripts/dns.sh"
export NB_DIR="$dns_fixture"
export DNS_TEST_TRACE="$dns_fixture/trace"
dns() { sh "$dns_fixture/scripts/dns.sh" "$@"; }

# Mirrors Android's toybox flock, which only knows -s/-x/-u/-n (no -w).
cat > "$dns_fixture/bin/flock" <<'FLOCK'
#!/bin/sh
case "$1" in -s | -x | -u | -n) ;; *) echo "flock: Unknown option '$1'" >&2; exit 1 ;; esac
[ "$2" = 9 ] && (: >&9)
FLOCK
chmod +x "$dns_fixture/bin/flock"

# Switch off and nothing owned: lifecycle hooks are no-ops without writes.
for dns_hook in sync suspend resume cleanup; do dns "$dns_hook"; done
[ ! -e "$dns_fixture/dns-state" ] && [ ! -e "$dns_fixture/run/dns.lock" ] && [ ! -e "$dns_fixture/run/dns.suspended" ]
dns status | grep -q '"enabled":false,"state":"off","reason":"none","ipv6":"off"'
dns status | grep -q '"root":"intercept"'
NB_DNS_ROOT=bypass sh "$dns_fixture/scripts/dns.sh" status | grep -q '"root":"bypass"'
dns off | grep -q '"state":"off"'
[ "$(cat "$dns_fixture/dns.enabled")" = 0 ]
if dns on extra >/dev/null 2>&1; then exit 1; fi
[ "$(cat "$dns_fixture/dns.enabled")" = 0 ]
if dns on >/dev/null 2>&1; then exit 1; fi
dns status | grep -q '"reason":"helper-missing"'
dns off >/dev/null

cat > "$dns_fixture/bin/nb-dns" <<'HELPER'
#!/bin/sh
printf '%s\n' "helper $*" >> "$DNS_TEST_TRACE"
[ "${DNS_TEST_FAIL_CLEANUP:-0}" != 1 ]
HELPER
cat > "$dns_fixture/bin/ip" <<'IP'
#!/bin/sh
printf '%s\n' "ip $*" >> "$DNS_TEST_TRACE"
if [ "${DNS_TEST_FAIL_UPSTREAM_RULE:-0}" = 1 ]; then
  case "$*" in '-4 rule del pref 84 '* | '-4 rule show') exit 1 ;; esac
fi
if [ "${DNS_TEST_TPROXY_ROUTE:-0}" = 1 ] && [ "$*" = '-6 route show table 7121' ]; then
  echo 'local default dev lo metric 1024 pref medium'
fi
exit 0
IP
cat > "$dns_fixture/bin/iptables" <<'FIREWALL'
#!/bin/sh
exit 1
FIREWALL
cp "$dns_fixture/bin/iptables" "$dns_fixture/bin/ip6tables"
chmod +x "$dns_fixture/bin/nb-dns" "$dns_fixture/bin/ip" "$dns_fixture/bin/iptables" "$dns_fixture/bin/ip6tables"

# Chains are only removed when the module recorded creating them: a chain of
# the same name owned by another tool survives cleanup.
cat > "$dns_fixture/bin/iptables" <<'FIREWALL'
#!/bin/sh
printf '%s\n' "iptables $*" >> "$DNS_TEST_TRACE"
case "$*" in
  *"-S NBMOD_DNS4") exit "${DNS_TEST_CHAIN_STATUS:-0}" ;;
  *"-S POSTROUTING") echo '-A POSTROUTING -j NBMOD_DNS_SNAT4'; exit 0 ;;
  *NBMOD_DNS_UP4* | *NBMOD_DNS_SNAT4* | *NBMOD_DNS4*) exit 0 ;;
esac
exit 1
FIREWALL
mkdir -p "$dns_fixture/dns-state"
printf 'per-resource\n' > "$dns_fixture/dns-state/owned"
: > "$dns_fixture/dns-state/own.iptables.nat.NBMOD_DNS4"
dns off >/dev/null
grep -q 'iptables -w 5 -t nat -X NBMOD_DNS4' "$DNS_TEST_TRACE"
if grep -q -- '-F NBMOD_DNS_UP4\|-X NBMOD_DNS_UP4' "$DNS_TEST_TRACE"; then exit 1; fi
[ ! -f "$dns_fixture/dns-state/own.iptables.nat.NBMOD_DNS4" ]

# An xtables lock timeout leaves chain ownership intact for the next retry.
printf 'per-resource\n' > "$dns_fixture/dns-state/owned"
: > "$dns_fixture/dns-state/own.iptables.nat.NBMOD_DNS4"
: > "$DNS_TEST_TRACE"
if DNS_TEST_CHAIN_STATUS=4 sh "$dns_fixture/scripts/dns.sh" off >/dev/null; then exit 1; fi
test -f "$dns_fixture/dns-state/owned"
test -f "$dns_fixture/dns-state/own.iptables.nat.NBMOD_DNS4"
dns status | grep -q '"state":"cleanup-pending","reason":"cleanup-failed"'
if grep -Eq -- '-[FX] NBMOD_DNS4' "$DNS_TEST_TRACE"; then exit 1; fi
dns off >/dev/null
test ! -f "$dns_fixture/dns-state/owned"
test ! -f "$dns_fixture/dns-state/own.iptables.nat.NBMOD_DNS4"

# A missing helper still allows recorded firewall and routing state to be removed.
mv "$dns_fixture/bin/nb-dns" "$dns_fixture/bin/nb-dns.saved"
printf 'per-resource\n' > "$dns_fixture/dns-state/owned"
: > "$dns_fixture/dns-state/own.iptables.nat.NBMOD_DNS4"
: > "$dns_fixture/dns-state/own.iptables.mangle.NBMOD_DNS_UP4"
: > "$dns_fixture/dns-state/own.iptables.nat.NBMOD_DNS_SNAT4"
: > "$dns_fixture/dns-state/redirected"
printf '4 1023\n' > "$dns_fixture/dns-state/routes"
: > "$DNS_TEST_TRACE"
if DNS_TEST_FAIL_UPSTREAM_RULE=1 sh "$dns_fixture/scripts/dns.sh" on >/dev/null; then exit 1; fi
dns status | grep -q '"state":"cleanup-pending","reason":"route-cleanup-failed"'
test -f "$dns_fixture/dns-state/own.iptables.nat.NBMOD_DNS_SNAT4"
if grep -Eq -- '-D POSTROUTING|-[FX] NBMOD_DNS_SNAT4' "$DNS_TEST_TRACE"; then exit 1; fi
if dns on >/dev/null; then exit 1; fi
dns status | grep -q '"state":"error","reason":"helper-missing"'
grep -q 'iptables -w 5 -t nat -X NBMOD_DNS4' "$DNS_TEST_TRACE"
cat > "$dns_fixture/expected-cleanup" <<'CLEANUP'
iptables -w 5 -t mangle -X NBMOD_DNS_UP4
ip -4 rule del pref 84 fwmark 0x4e400000/0xffe00000 lookup 1023
ip -4 rule del pref 84 fwmark 0x4e400000/0xffe00000 lookup 1023
iptables -w 5 -t nat -D POSTROUTING -j NBMOD_DNS_SNAT4
iptables -w 5 -t nat -X NBMOD_DNS_SNAT4
CLEANUP
grep -E -- '(-X NBMOD_DNS_UP4|rule del pref 84|-D POSTROUTING|-X NBMOD_DNS_SNAT4)' "$DNS_TEST_TRACE" | diff -u "$dns_fixture/expected-cleanup" -
if grep -q '^helper cleanup$' "$DNS_TEST_TRACE"; then exit 1; fi
for dns_record in owned own.iptables.nat.NBMOD_DNS4 own.iptables.mangle.NBMOD_DNS_UP4 own.iptables.nat.NBMOD_DNS_SNAT4 redirected routes; do
  test ! -f "$dns_fixture/dns-state/$dns_record"
done
mv "$dns_fixture/bin/nb-dns.saved" "$dns_fixture/bin/nb-dns"
dns off >/dev/null

# A cleanup that removed every chain but failed later keeps "owned": the
# retry must not claim chains it has no record of.
printf 'per-resource\n' > "$dns_fixture/dns-state/owned"
: > "$dns_fixture/dns-state/redirected"
: > "$DNS_TEST_TRACE"
if DNS_TEST_FAIL_CLEANUP=1 sh "$dns_fixture/scripts/dns.sh" off >/dev/null; then exit 1; fi
sh "$dns_fixture/scripts/dns.sh" off >/dev/null
if grep -q -- '-F NBMOD_DNS_UP4\|-X NBMOD_DNS_UP4\|-F NBMOD_DNS4\|-X NBMOD_DNS4' "$DNS_TEST_TRACE"; then exit 1; fi

# Owned state is cleaned even with the switch off.
: > "$dns_fixture/dns-state/owned"
: > "$dns_fixture/dns-state/redirected"
printf '4 1023\n' > "$dns_fixture/dns-state/routes"
dns sync
grep -q '^helper cleanup$' "$DNS_TEST_TRACE"
grep -q 'rule del pref 84 fwmark 0x4e400000/0xffe00000 lookup 1023' "$DNS_TEST_TRACE"
[ ! -f "$dns_fixture/dns-state/owned" ] && [ ! -f "$dns_fixture/dns-state/routes" ]
dns off >/dev/null

# A failed cleanup is reported and retried; the helper is not stopped.
: > "$dns_fixture/dns-state/owned"
: > "$dns_fixture/dns-state/redirected"
if DNS_TEST_FAIL_CLEANUP=1 sh "$dns_fixture/scripts/dns.sh" off >/dev/null; then exit 1; fi
[ -f "$dns_fixture/dns-state/owned" ]
dns status | grep -q '"state":"cleanup-pending"'
dns off >/dev/null
[ ! -f "$dns_fixture/dns-state/owned" ]

# IPv6 TPROXY leftovers: table 7121 is only cleared when the module added it.
printf 'per-resource\n' > "$dns_fixture/dns-state/owned"
: > "$dns_fixture/dns-state/tproxy"
: > "$dns_fixture/dns-state/own.iptables.nat.NBMOD_DNS4"
DNS_TEST_TPROXY_ROUTE=1 sh "$dns_fixture/scripts/dns.sh" off >/dev/null
if grep -q 'ip -6 route del local ::/0 dev lo table 7121' "$DNS_TEST_TRACE"; then exit 1; fi
printf 'per-resource\n' > "$dns_fixture/dns-state/owned"
: > "$dns_fixture/dns-state/tproxy"
: > "$dns_fixture/dns-state/own.route6.7121"
DNS_TEST_TPROXY_ROUTE=1 sh "$dns_fixture/scripts/dns.sh" off >/dev/null
grep -q 'ip -6 route del local ::/0 dev lo table 7121' "$DNS_TEST_TRACE"
[ ! -f "$dns_fixture/dns-state/tproxy" ] && [ ! -f "$dns_fixture/dns-state/own.route6.7121" ]

# Identical status is not rewritten on every heartbeat.
dns_before="$(ls -i "$dns_fixture/dns-state/status")"
dns off >/dev/null
[ "$(ls -i "$dns_fixture/dns-state/status")" = "$dns_before" ]

mkdir "$dns_fixture/proc-net"
printf '%s\n' header '0: 0200007F:0035 0:0 07' '1: 00000000:0035 0:0 0A' > "$dns_fixture/proc-net/udp"
printf '%s\n' header '0: 00000000000000000000000001000000:0035 0:0 07' > "$dns_fixture/proc-net/udp6"
printf '%s\n' header '0: 00000000:0035 0:0 07' '1: 0200007F:0036 0:0 0A' > "$dns_fixture/proc-net/tcp"
printf '%s\n' header '0: 00000000000000000000000000000000:0035 0:0 0A' > "$dns_fixture/proc-net/tcp6"
sed '/^case "${1:-status}" in$/,$d' "$dns_fixture/scripts/dns.sh" > "$dns_fixture/scripts/dns-functions.sh"
cat >> "$dns_fixture/scripts/dns-functions.sh" <<'FUNCTIONS'
set -eu
settings() { echo opportunistic; }
dumpsys() {
  case "$1" in
    connectivity)
      printf '%s\n' "Active default network: $dns_fixture_netid" 'NetworkAgentInfo{network VPN CONNECTED InterfaceName: tun42}'
      ;;
    dnsresolver)
      cat <<'RESOLVER'
NetId: 100
  DNS servers:
    fe80::53 <no data>
  DoT configuration (1 entries)
    192.0.2.53 name{} status{failed}
NetId: 101
  DNS servers:
    192.0.2.53 <no data>
  DoT configuration (1 entries)
    192.0.2.53 name{} status{success}
RESOLVER
      ;;
  esac
}
dns_fixture_netid=100
dns_inspect_android
[ "$dns_default_netid:$dns_has_ipv4_server:$dns_dot:$dns_vpn_ifaces" = '100:0:false:tun42' ]
dns_fixture_netid=101
dns_inspect_android
[ "$dns_default_netid:$dns_has_ipv4_server:$dns_dot" = '101:1:true' ]
dns_fixture_netid=none
dns_inspect_android
[ "$dns_default_netid:$dns_has_ipv4_server:$dns_dot" = ':1:true' ]

dns_local_resolvers="$(dns_list_local_resolvers "$NB_DIR/proc-net")"
printf '%s\n' "$dns_local_resolvers" | diff -u - "$NB_DIR/expected-listeners"
dns_fixture_netid=100
dns_inspect_android
dns_exempt_next=/dev/null
dns_fake_firewall() { printf '%s\n' "$*"; }
dns_exempt dns_fake_firewall nat NBMOD_DNS4 4
dns_exempt dns_fake_firewall mangle NBMOD_DNS6 6

# dns_running streams /proc/<pid>/cmdline through cat so tr never reads procfs
# directly (toybox tr spins at 100% CPU on ESRCH read errors).
dns_proc="$NB_DIR/proc"
mkdir -p "$dns_proc/4242" "$dns_state"
printf '4242 (nb-dns) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 98765 0\n' > "$dns_proc/4242/stat"
printf '%s\000serve\000%s\000' "$dns_helper" "$dns_config" > "$dns_proc/4242/cmdline"
printf '4242 98765\n' > "$dns_pid_file"
(
  tr() { [ -p /dev/fd/0 ] || exit 99; command tr "$@"; }
  dns_running
  ( cat() { return 1; }; ! dns_running )
  printf '%s\000other\000%s\000' "$dns_helper" "$dns_config" > "$dns_proc/4242/cmdline"
  ! dns_running
  printf '%s\000serve\000%s\000' "$dns_helper" "$dns_config" > "$dns_proc/4242/cmdline"
  printf '4242 11111\n' > "$dns_pid_file"
  ! dns_running
  printf '4242 98765\n' > "$dns_pid_file"
  rm -f "$dns_proc/4242/cmdline"
  ! dns_running
)
rm -f "$dns_pid_file"
FUNCTIONS
printf '%s\n' '4 tcp wildcard' '4 udp loopback' '6 tcp wildcard' '6 udp loopback' > "$dns_fixture/expected-listeners"
cat > "$dns_fixture/expected-rules" <<'RULES'
-t nat -A NBMOD_DNS4 -o lo -p tcp -j RETURN
-t nat -A NBMOD_DNS4 -d 127.0.0.0/8 -p udp -j RETURN
-t mangle -A NBMOD_DNS6 -o lo -p tcp -j RETURN
-t mangle -A NBMOD_DNS6 -d ::1/128 -p udp -j RETURN
RULES
sh "$dns_fixture/scripts/dns-functions.sh" > "$dns_fixture/rules-trace"
grep -Fxq -- '-t nat -A NBMOD_DNS4 -m mark ! --mark 0/0xffff -m mark ! --mark 100/0xffff -j RETURN' "$dns_fixture/rules-trace"
grep -E -- '(-o lo|-d 127\.0\.0\.0/8|-d ::1/128) -p' "$dns_fixture/rules-trace" | diff -u "$dns_fixture/expected-rules" -

cat > "$dns_fixture/bin/iptables" <<'FIREWALL'
#!/bin/sh
dns_firewall="${0##*/}"
printf '%s\n' "$dns_firewall $*" >> "$DNS_TEST_TRACE"
shift 3
case "$dns_firewall:$1" in ip6tables:nat) exit 3 ;; esac
case "$*" in
  'nat -S POSTROUTING') exit 0 ;;
  'nat -S NBMOD_DNS_SNAT4')
    if [ -f "$NB_DIR/dns-state/own.iptables.nat.NBMOD_DNS_SNAT4" ]; then
      echo '-A NBMOD_DNS_SNAT4 -m mark --mark 0x4e400000/0xffe00000 -j MASQUERADE'
      exit 0
    fi
    exit 1
    ;;
  *' -S '*) exit 1 ;;
esac
exit 0
FIREWALL
cp "$dns_fixture/bin/iptables" "$dns_fixture/bin/ip6tables"
cat > "$dns_fixture/bin/ip" <<'IP'
#!/bin/sh
printf '%s\n' "ip $*" >> "$DNS_TEST_TRACE"
shift
case "$*" in
  'rule show') echo '32766: from all fwmark 0x0/0xffff iif lo lookup 1023' ;;
  'route show table 1023') echo 'default dev wlan0' ;;
  'route get '*) echo ' dev tun42 ' ;;
esac
IP
cat > "$dns_fixture/bin/nb-dns" <<'HELPER'
#!/bin/sh
case "$*" in
  inspect) printf '%s\n' 'target 100.64.0.1:53' 'upstream 192.0.2.53:53' 'upstream [2001:db8::53]:53' ;;
  'endpoint 192.0.2.53:53') echo '4 192.0.2.53 53' ;;
  'endpoint [2001:db8::53]:53') echo '6 2001:db8::53 53' ;;
  conntrack-check | 'config '*) exit 0 ;;
  *) exit 1 ;;
esac
HELPER
sed '/^case "${1:-status}" in$/,$d' "$dns_fixture/scripts/dns.sh" > "$dns_fixture/scripts/dns-sync.sh"
cat >> "$dns_fixture/scripts/dns-sync.sh" <<'SYNC'
busybox() { [ "$1" != timeout ] || printf '%s\n' '{"daemonStatus":"Connected"}'; }
dns_inspect_android() { dns_has_ipv4_server=1; }
dns_ipv6_present() { return 0; }
dns_helper_start() { echo both > "$dns_state/listeners"; }
dns_lock_acquire 20 && dns_sync
SYNC
: > "$DNS_TEST_TRACE"
echo 1 > "$dns_fixture/dns.enabled"
sh "$dns_fixture/scripts/dns-sync.sh"
grep -q '^active none tproxy ' "$dns_fixture/dns-state/status"
grep -Fxq '4 1023' "$dns_fixture/dns-state/routes"
grep -Fxq -- '-A NBMOD_DNS_SNAT4 -m mark --mark 0x4e400000/0xffe00000 -j MASQUERADE' "$dns_fixture/dns-state/rules"
cat > "$dns_fixture/expected-install" <<'INSTALL'
iptables -w 5 -t nat -N NBMOD_DNS_SNAT4
iptables -w 5 -t nat -A NBMOD_DNS_SNAT4 -m mark --mark 0x4e400000/0xffe00000 -j MASQUERADE
iptables -w 5 -t nat -A POSTROUTING -j NBMOD_DNS_SNAT4
ip -4 rule add pref 84 fwmark 0x4e400000/0xffe00000 lookup 1023
iptables -w 5 -t mangle -A NBMOD_DNS_UP4 -m owner --uid-owner 0 -d 192.0.2.53 -p udp --dport 53 -j MARK --set-xmark 0x4e400000/0xffe00000
iptables -w 5 -t mangle -A NBMOD_DNS_UP4 -m owner --uid-owner 0 -d 192.0.2.53 -p tcp --dport 53 -j MARK --set-xmark 0x4e400000/0xffe00000
INSTALL
grep -E -- '(-[NA] NBMOD_DNS_SNAT4|-A POSTROUTING|rule add pref 84|-A NBMOD_DNS_UP[46].* --set-xmark)' "$DNS_TEST_TRACE" | diff -u "$dns_fixture/expected-install" -
if grep -Eq -- '-[NA] (NBMOD_DNS_UP6|NBMOD_DNS_SNAT6)' "$DNS_TEST_TRACE"; then exit 1; fi
# Sourcing settings.sh repeatedly must not duplicate PATH entries.
sh -c '
  expected_path="$NB_DIR/bin:$NB_DIR/scripts:/data/adb/magisk:/data/adb/ksu/bin:/usr/bin:/bin:/system/bin"
  PATH="/usr/bin:/bin"
  . "$NB_DIR/settings.sh"
  [ "$PATH" = "$expected_path" ] || exit 1
  . "$NB_DIR/settings.sh"
  [ "$PATH" = "$expected_path" ] || exit 1
  PATH="/usr/bin:/bin:/system/bin"
  . "$NB_DIR/settings.sh"
  [ "$PATH" = "$expected_path" ] || exit 1
  . "$NB_DIR/settings.sh"
  [ "$PATH" = "$expected_path" ] || exit 1
'

echo 'PASS: DNS lifecycle, cleanup retries, resolver scoping, and upstream source NAT'
