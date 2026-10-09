#!/system/bin/sh

SKIPUNZIP=1
SKIPMOUNT=false

if [ "$BOOTMODE" != true ]; then
  ui_print "! Please install in Magisk Manager or KernelSU/APatch Manager"
  abort "! Install from recovery is not supported"
fi

NB_DIR="/data/adb/netbird"
NB_BIN_DIR="$NB_DIR/bin"
NB_SCRIPTS_DIR="$NB_DIR/scripts"
NB_RUN_DIR="$NB_DIR/run"
NB_CERT_DIR="$NB_DIR/certs"

case "$ARCH" in
  arm64)
    RELEASE_ARCH="arm64"
    BUNDLED_ARCH="arm64"
    UPDATE_KEY="arm64-v8a"
    ;;
  arm)
    RELEASE_ARCH="armv6"
    BUNDLED_ARCH="arm"
    UPDATE_KEY="armv7"
    ;;
  x64)
    RELEASE_ARCH="amd64"
    BUNDLED_ARCH="x86_64"
    UPDATE_KEY="x86_64"
    ;;
  *)
    abort "! Unsupported architecture: $ARCH"
    ;;
esac

ui_print "- Detected architecture: $ARCH"

# Fetch a URL into a file, preferring TLS verification. The insecure retry is
# only needed because Magisk's busybox wget often has no CA store available.
gh_fetch() {
  fetch_timeout="$1"
  fetch_out="$2"
  fetch_url="$3"
  rm -f "$fetch_out"
  if wget --timeout="$fetch_timeout" -qO "$fetch_out" "$fetch_url" 2>/dev/null && [ -s "$fetch_out" ]; then
    return 0
  fi
  rm -f "$fetch_out"
  if wget --no-check-certificate --timeout="$fetch_timeout" -qO "$fetch_out" "$fetch_url" 2>/dev/null && [ -s "$fetch_out" ]; then
    return 0
  fi
  rm -f "$fetch_out"
  return 1
}

# Verify the downloaded archive against the release checksums.txt (sha256).
gh_verify_sha256() {
  verify_file="$1"
  if ! command -v sha256sum >/dev/null 2>&1; then
    ui_print "! sha256sum unavailable; skipping SHA256 verification"
    return 0
  fi
  verify_name="$(basename "$verify_file")"
  sums_name="$(echo "$verify_name" | sed 's/_linux_.*$//')_checksums.txt"
  sums_url="$(grep -o '"browser_download_url": *"[^"]*"' "$release_json" | grep "$sums_name" |
    sed 's/.*"browser_download_url": *"\([^"]*\)".*/\1/' | head -n 1)"
  if [ -z "$sums_url" ]; then
    ui_print "! No checksums file ($sums_name) in release; skipping SHA256 verification"
    return 0
  fi
  if ! gh_fetch 30 "$TMPDIR/$sums_name" "$sums_url"; then
    ui_print "! Unable to download checksums file; skipping SHA256 verification"
    return 0
  fi
  expected="$(grep " $verify_name\$" "$TMPDIR/$sums_name" | awk '{ print $1 }' | head -n 1)"
  if [ -z "$expected" ]; then
    ui_print "! $verify_name not listed in checksums; skipping SHA256 verification"
    return 0
  fi
  actual="$(sha256sum "$verify_file" | awk '{ print $1 }')"
  if [ "$expected" != "$actual" ]; then
    ui_print "! SHA256 mismatch for $verify_name"
    ui_print "!  expected: $expected"
    ui_print "!  actual:   $actual"
    rm -f "$verify_file"
    return 1
  fi
  ui_print "- SHA256 verified: $verify_name"
}

gh_download() {
  repo="$1"
  match="$2"
  release_json="$TMPDIR/gh-release.json"
  gh_fetch 10 "$release_json" "https://api.github.com/repos/${repo}/releases/latest" || return 1
  download_url="$(
    grep -o '"browser_download_url": *"[^"]*"' "$release_json" |
      grep "$match" |
      sed 's/.*"browser_download_url": *"\([^"]*\)".*/\1/' |
      head -n 1 || true
  )"
  if [ -z "$download_url" ]; then
    return 1
  fi
  filename=$(basename "$download_url")
  ui_print "- Downloading $filename"
  gh_fetch 120 "$TMPDIR/$filename" "$download_url" || return 1
  gh_verify_sha256 "$TMPDIR/$filename" || return 1
}

ui_print "- Extracting module files"
unzip -qqo "$ZIPFILE" -x 'META-INF/*' 'netbird/*' -d "$MODPATH"

# Per-arch update manifest: the Magisk app fetches this URL to show the
# "update available" banner (version/versionCode/zipUrl live in update/*.json).
UPDATE_JSON_URL="https://cdn.jsdelivr.net/gh/ahsaboy/magisk-netbird@main/update/update-${UPDATE_KEY}.json"
if [ -f "$MODPATH/module.prop" ]; then
  if grep -q '^updateJson=' "$MODPATH/module.prop"; then
    sed -i "s|^updateJson=.*|updateJson=${UPDATE_JSON_URL}|" "$MODPATH/module.prop"
  else
    printf 'updateJson=%s\n' "$UPDATE_JSON_URL" >> "$MODPATH/module.prop"
  fi
fi

mkdir -p "$NB_BIN_DIR" "$NB_SCRIPTS_DIR" "$NB_RUN_DIR" "$NB_CERT_DIR" "$MODPATH/system/bin"
echo "$MODPATH" > "$NB_DIR/module.path"

unzip -qqjo "$ZIPFILE" "netbird/scripts/*" -d "$NB_SCRIPTS_DIR"
unzip -qqjo "$ZIPFILE" "netbird/settings.sh" -d "$NB_DIR"
# User-config template; the live config is /data/adb/netbird/.env and is
# never touched by updates.
unzip -qqjo "$ZIPFILE" "netbird/netbird.env.example" -d "$NB_DIR" 2>/dev/null || true

# Bundled binary: stage into a fresh temp dir and check for the FILE (device
# unzip returns rc=0 even when no member matched), then atomically replace.
# rm first avoids ETXTBSY when the old daemon still has the file mapped.
rm -rf "$NB_DIR/.newbin"
mkdir -p "$NB_DIR/.newbin" "$NB_BIN_DIR"
unzip -qqjo "$ZIPFILE" "netbird/bin/netbird-$BUNDLED_ARCH" -d "$NB_DIR/.newbin" 2>/dev/null || true
new_bin="$NB_DIR/.newbin/netbird-$BUNDLED_ARCH"
if [ ! -f "$new_bin" ]; then
  unzip -qqjo "$ZIPFILE" "netbird/bin/netbird" -d "$NB_DIR/.newbin" 2>/dev/null || true
  new_bin="$NB_DIR/.newbin/netbird"
fi
if [ -f "$new_bin" ]; then
  rm -f "$NB_BIN_DIR/netbird"
  mv -f "$new_bin" "$NB_BIN_DIR/netbird"
  ui_print "- Installed bundled netbird binary"
else
  ui_print "! No bundled netbird binary in zip; keeping existing or downloading"
fi
rm -rf "$NB_DIR/.newbin"

if [ ! -f "$NB_BIN_DIR/netbird" ]; then
  gh_download "netbirdio/netbird" "netbird_.*_linux_${RELEASE_ARCH}\\.tar\\.gz" || abort "! Unable to download NetBird release"
  tar -xzf "$TMPDIR/$filename" -C "$TMPDIR" || abort "! Unable to extract NetBird archive"
  found="$(find "$TMPDIR" -type f -name netbird | head -n 1)"
  [ -n "$found" ] || abort "! NetBird binary not found in archive"
  mv -f "$found" "$NB_BIN_DIR/netbird"
fi

ln -sf "$NB_BIN_DIR/netbird" "$MODPATH/system/bin/netbird"
ln -sf "$NB_SCRIPTS_DIR/netbird.service" "$MODPATH/system/bin/netbird.service"

ui_print "- Setting permissions"
set_perm_recursive "$NB_BIN_DIR" 0 0 0755 0755 "u:object_r:system_file:s0"
set_perm_recursive "$NB_SCRIPTS_DIR" 0 0 0755 0755 "u:object_r:system_file:s0"
set_perm_recursive "$MODPATH/system/bin" 0 0 0755 0755 "u:object_r:system_file:s0"
set_perm "$MODPATH/service.sh" 0 0 0755 "u:object_r:system_file:s0"
if [ -f "$MODPATH/action.sh" ]; then
  set_perm "$MODPATH/action.sh" 0 0 0755 "u:object_r:system_file:s0"
fi

ui_print "- Starting NetBird service in background"
"$NB_SCRIPTS_DIR/start.sh" postinstall >/dev/null 2>&1 &

ln -sf "$NB_BIN_DIR/netbird" /dev/netbird
ln -sf "$NB_SCRIPTS_DIR/netbird.service" /dev/netbird.service

ui_print "-----------------------------------------------------------"
ui_print " NetBird commands"
ui_print "-----------------------------------------------------------"
ui_print " Before reboot:"
ui_print "   su -c '/dev/netbird.service up --setup-key <KEY> --management-url <URL>'"
ui_print "   su -c '/dev/netbird.service status'"
ui_print " After reboot:"
ui_print "   su -c 'netbird.service up --setup-key <KEY> --management-url <URL>'"
ui_print "   su -c 'netbird.service status'"
ui_print " DNS management is disabled by default with --disable-dns."
ui_print " Tip: prefer --setup-key-file <path> over --setup-key to keep the key"
ui_print "      out of shell history and 'ps' output."
