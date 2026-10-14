#!/system/bin/sh

DIR=$(dirname "$(realpath "$0")")
. "$DIR/../settings.sh"

custom_ca_files() {
  [ -f "$NB_DIR/ca.crt" ] && echo "$NB_DIR/ca.crt"

  if [ -d "$NB_CERT_DIR" ]; then
    for cert in "$NB_CERT_DIR"/*.crt "$NB_CERT_DIR"/*.pem "$NB_CERT_DIR"/*.cer; do
      [ -f "$cert" ] && echo "$cert"
    done
  fi
}

build_bundle() {
  tmp_file="$NB_CA_BUNDLE.tmp.$$"
  count=0
  : > "$tmp_file"

  for cert in $(custom_ca_files); do
    if grep -q "BEGIN CERTIFICATE" "$cert" 2>/dev/null; then
      sed 's/\r$//' "$cert" >> "$tmp_file"
      echo >> "$tmp_file"
      count=$((count + 1))
    fi
  done

  mv -f "$tmp_file" "$NB_CA_BUNDLE"
  echo "$count" > "$NB_CA_COUNT_FILE"
  chmod 0644 "$NB_CA_BUNDLE" "$NB_CA_COUNT_FILE" 2>/dev/null || true
}

show_status() {
  build_bundle
  count="$(cat "$NB_CA_COUNT_FILE" 2>/dev/null || echo 0)"
  echo "custom CA certificates: $count"
  echo "SSL_CERT_FILE=$NB_CA_BUNDLE"
  echo "SSL_CERT_DIR=$SSL_CERT_DIR"
  custom_ca_files
}

case "${1:-update}" in
  update)
    build_bundle
    ;;
  status)
    show_status
    ;;
  *)
    echo "usage: cert-trust.sh {update|status}"
    exit 1
    ;;
esac
