#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM

mkdir -p "$tmp_dir/scripts" "$tmp_dir/bin"
cp "$repo_dir/module/netbird/scripts/automation.sh" "$tmp_dir/scripts/automation.sh"
cp "$repo_dir/module/netbird/settings.sh" "$tmp_dir/settings.sh"
cat > "$tmp_dir/scripts/netbird.service" <<'SERVICE'
#!/bin/sh
printf '%s\n' "$1" >> "$NB_DIR/actions.log"
exit 0
SERVICE
chmod +x "$tmp_dir/scripts/netbird.service" "$tmp_dir/scripts/automation.sh"
cat > "$tmp_dir/bin/netbird" <<'NETBIRD'
#!/bin/sh
printf '%s\n' '{"daemonStatus":"Disconnected"}'
NETBIRD
chmod +x "$tmp_dir/bin/netbird"

export NB_DIR="$tmp_dir"
export NB_WATCHDOG=off
automation="$tmp_dir/scripts/automation.sh"
schedule="daily:$(date -d '1 minute ago' '+%H:%M')"
rule_id="$(sh "$automation" save '' "Night disconnect" disconnect 1 10 all "$schedule")"
localized_id="$(sh "$automation" save '' '夜间连接规则' connect 0 5 all "$schedule")"
case "$rule_id" in auto-[a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9]) ;; *) exit 1 ;; esac

if sh "$automation" save '' bad-name 'disconnect;id' 1 10 all "$schedule" >/dev/null 2>&1; then
  echo "unsafe action was accepted" >&2
  exit 1
fi

list_output="$(sh "$automation" list)"
printf '%s\n' "$list_output" | grep -F "$rule_id$(printf '\t')Night disconnect$(printf '\t')disconnect$(printf '\t')1" >/dev/null
printf '%s\n' "$list_output" | grep -F "$localized_id$(printf '\t')夜间连接规则" >/dev/null

sh "$automation" evaluate
sh "$automation" evaluate
journal="$tmp_dir/run/automation.log"
negative_id="$(TZ=Etc/GMT+8 sh "$automation" save '' 'West timezone' disconnect 1 9 any "daily:$(TZ=Etc/GMT+8 date -d '1 minute ago' '+%H:%M')")"
TZ=Etc/GMT+8 sh "$automation" evaluate
TZ=Etc/GMT+8 sh "$automation" evaluate
[ "$(grep -c "key=$negative_id:" "$journal")" = 1 ]
grep -F "rule=$rule_id action=disconnect event=skipped key=$rule_id:" "$journal" >/dev/null
sh "$automation" log | grep -F "event=skipped" >/dev/null
forged_ts="$(date '+%Y-%m-%dT%H:%M:%S%z' | sed 's/\([+-][0-9][0-9]\)\([0-9][0-9]\)$/\1:\2/')"
forged_record="v=1 ts=$forged_ts rule=$localized_id action=connect event=success key=$rule_id:$(date '+%Y-%m-%dT%H:%M')"
printf '%s\n' "$forged_record" >> "$journal"
if sh "$automation" log | grep -F "$forged_record" >/dev/null; then
  echo "journal accepted a mismatched rule/key record" >&2
  exit 1
fi

connect_id="$(sh "$automation" save '' 'Higher priority connect' connect 1 20 all "$schedule")"
sh "$automation" evaluate
[ "$(grep -c '^up$' "$tmp_dir/actions.log")" = 1 ]
grep -F "rule=$rule_id action=disconnect event=conflict key=$rule_id:" "$journal" >/dev/null
sh "$automation" evaluate
[ "$(grep -c '^up$' "$tmp_dir/actions.log")" = 1 ]
any_second_schedule="daily:$(date -d '2 minutes ago' '+%H:%M')"
any_id="$(sh "$automation" save '' 'Any matching' connect 1 40 any "$schedule" "$any_second_schedule")"
all_id="$(sh "$automation" save '' 'All matching' connect 1 50 all "$schedule" "$schedule")"
sh "$automation" evaluate
[ "$(grep -c '^up$' "$tmp_dir/actions.log")" = 4 ]
sh "$automation" evaluate
[ "$(grep -c '^up$' "$tmp_dir/actions.log")" = 4 ]

rotate_id="$(sh "$automation" save '' 'Rotation checkpoint' connect 1 30 all "$schedule")"
old_key="$rule_id:$(date -d '1 minute ago' '+%Y-%m-%dT%H:%M')"
old_record="v=1 ts=$(date '+%Y-%m-%dT%H:%M:%S%z' | sed 's/\([+-][0-9][0-9]\)\([0-9][0-9]\)$/\1:\2/') rule=$rule_id action=disconnect event=skipped key=$old_key"
count=0
while [ "$count" -lt 6000 ]; do
  printf '%s\n' "$old_record" >> "$journal"
  count=$((count + 1))
done
sh "$automation" evaluate
[ -f "$tmp_dir/run/automation.checkpoint" ]
[ -f "$journal.1" ]
[ "$(wc -c < "$journal" | tr -d ' ')" -lt 262144 ]
sh "$automation" evaluate
[ "$(grep -c '^up$' "$tmp_dir/actions.log")" = 5 ]

if sh "$automation" delete auto-deadbeef >/dev/null 2>&1; then
  echo "unknown rule deletion succeeded" >&2
  exit 1
fi
sh "$automation" delete "$rule_id"
sh "$automation" delete "$connect_id"
sh "$automation" delete "$rotate_id"
sh "$automation" delete "$localized_id"
sh "$automation" delete "$negative_id"
sh "$automation" delete "$any_id"
sh "$automation" delete "$all_id"
[ -z "$(sh "$automation" list)" ]
printf 'automation protocol tests: ok\n'
