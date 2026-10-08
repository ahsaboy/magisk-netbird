#!/system/bin/sh

# Network IDs can start with a dot, for example `.nb.test`.
# Keep the accepted alphabet narrow enough that IDs cannot inject shell syntax.
network_id_valid() {
  case "${1:-}" in
    all) return 0 ;;
    ''|*[!A-Za-z0-9_.:-]*) return 1 ;;
    *) return 0 ;;
  esac
}

network_id_valid all
network_id_valid .nb.test
network_id_valid network-route-srvs-site
network_id_valid 'aws-eu-central-1-vpc'
! network_id_valid 'route/id'
! network_id_valid 'route id'
! network_id_valid 'route;id'
! network_id_valid ''

echo "network ID validation: passed"
