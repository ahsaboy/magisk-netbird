#!/system/bin/sh

network_list='Available Networks:

  - ID: .nb.test
    Network: .nb.test
    Status: Selected

  - ID: network-route-srvs-site
    Network: 192.168.100.0/24
    Status: Selected'

network_id_valid() {
  network_id="$1"
  [ -n "$network_id" ] || return 1
  [ "$network_id" != "--" ] || return 1
  case "$network_id" in *[[:space:]]*) return 1 ;; esac
  return 0
}

network_id_exists() {
  network_id_valid "$1" || return 1
  printf '%s\n' "$network_list" |
    awk -v wanted="$1" '$1 == "-" && $2 == "ID:" && $3 == wanted { found = 1 } END { exit !found }'
}

network_id_exists .nb.test
network_id_exists network-route-srvs-site
! network_id_exists route/id
! network_id_exists 'route id'
! network_id_exists unknown-route
! network_id_exists --
! network_id_exists ''

echo "network ID validation: passed"
