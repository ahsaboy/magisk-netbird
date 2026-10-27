#!/system/bin/sh

DIR=$(dirname "$(realpath "$0")")
. "$DIR/../settings.sh"

RULE_DIR="$NB_DIR/automation/rules"
JOURNAL="$NB_RUN_DIR/automation.log"
LOCK_DIR="$NB_RUN_DIR/automation.lock"

valid_id() {
  case "${1:-}" in
    auto-[a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9]) return 0 ;;
  esac
  return 1
}

valid_name() {
  [ -n "${1:-}" ] && [ "${#1}" -le 192 ] || return 1
  name_tab="$(printf '\t')"
  name_cr="$(printf '\r')"
  name_lf="$(printf '\nx')"
  name_lf="${name_lf%x}"
  case "$1" in *'='*|*"$name_tab"*|*"$name_cr"*|*"$name_lf"*) return 1 ;; esac
}

valid_action() {
  case "${1:-}" in connect|disconnect) return 0 ;; esac
  return 1
}

valid_schedule() {
  case "${1:-}" in
    once:????-??-??T??:??|daily:??:??|weekdays:??:??|weekly:[1-7]@??:??) ;;
    *) return 1 ;;
  esac
  case "$1" in
    once:*) schedule_time="${1#*T}" ;;
    weekly:*) schedule_time="${1##*@}" ;;
    *) schedule_time="${1#*:}" ;;
  esac
  case "$schedule_time" in
    [01][0-9]:[0-5][0-9]|2[0-3]:[0-5][0-9]) ;;
    *) return 1 ;;
  esac
  if [ "${1%%:*}" = once ]; then
    schedule_date="${1#once:}"
    schedule_date="${schedule_date%T*}"
    case "$schedule_date" in ????-??-??) ;; *) return 1 ;; esac
    parsed_date="$(date -d "$schedule_date" '+%Y-%m-%d' 2>/dev/null || true)"
    [ "$parsed_date" = "$schedule_date" ] || return 1
  fi
  return 0
}

acquire_lock() {
  mkdir -p "$NB_RUN_DIR" "$RULE_DIR"
  lock_attempt=0
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    if [ -f "$LOCK_DIR/pid" ]; then
      lock_owner="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
      case "$lock_owner" in ''|*[!0-9]*) lock_owner=0 ;; esac
      if [ "$lock_owner" -gt 0 ] && ! kill -0 "$lock_owner" >/dev/null 2>&1; then
        rm -f "$LOCK_DIR/pid"
        rmdir "$LOCK_DIR" 2>/dev/null || true
      fi
    fi
    lock_attempt=$((lock_attempt + 1))
    [ "$lock_attempt" -lt 20 ] || return 1
    sleep 1
  done
  echo "$$" > "$LOCK_DIR/pid"
  trap 'rm -f "$LOCK_DIR/pid"; rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT HUP INT TERM
}

release_lock() {
  trap - EXIT HUP INT TERM
  rm -f "$LOCK_DIR/pid"
  rmdir "$LOCK_DIR" 2>/dev/null || true
}

rule_file() {
  valid_id "$1" || return 1
  printf '%s/%s.conf\n' "$RULE_DIR" "$1"
}

parse_rule() {
  parsed_id=""
  parsed_name=""
  parsed_action=""
  parsed_enabled=""
  parsed_priority=""
  parsed_mode=""
  parsed_conditions=""
  parsed_condition_count=0
  seen="|"
  while IFS= read -r rule_line || [ -n "$rule_line" ]; do
    case "$rule_line" in *=*) ;; *) return 1 ;; esac
    rule_key="${rule_line%%=*}"
    rule_value="${rule_line#*=}"
    case "$rule_key" in
      id|name|action|enabled|priority|mode) ;;
      condition)
        valid_schedule "$rule_value" || return 1
        parsed_condition_count=$((parsed_condition_count + 1))
        [ "$parsed_condition_count" -le 8 ] || return 1
        if [ -n "$parsed_conditions" ]; then parsed_conditions="$parsed_conditions,$rule_value"; else parsed_conditions="$rule_value"; fi
        continue
        ;;
      *) return 1 ;;
    esac
    case "$seen" in *"|$rule_key|"*) return 1 ;; esac
    seen="$seen$rule_key|"
    case "$rule_key" in
      id) parsed_id="$rule_value" ;;
      name) parsed_name="$rule_value" ;;
      action) parsed_action="$rule_value" ;;
      enabled) parsed_enabled="$rule_value" ;;
      priority) parsed_priority="$rule_value" ;;
      mode) parsed_mode="$rule_value" ;;
    esac
  done < "$1"
  valid_id "$parsed_id" && valid_name "$parsed_name" && valid_action "$parsed_action" || return 1
  case "$parsed_enabled" in 0|1) ;; *) return 1 ;; esac
  case "$parsed_priority" in [0-9]|[1-9][0-9]) ;; *) return 1 ;; esac
  case "$parsed_mode" in all|any) ;; *) return 1 ;; esac
  [ "$parsed_condition_count" -ge 1 ] || return 1
  return 0
}

write_rule() {
  write_id="$1"
  write_name="$2"
  write_action_name="$3"
  write_enabled="$4"
  write_priority="$5"
  write_mode="$6"
  shift 6
  [ "$#" -ge 1 ] && [ "$#" -le 8 ] || return 2
  valid_name "$write_name" && valid_action "$write_action_name" || return 2
  case "$write_enabled" in 0|1) ;; *) return 2 ;; esac
  case "$write_priority" in [0-9]|[1-9][0-9]) ;; *) return 2 ;; esac
  case "$write_mode" in all|any) ;; *) return 2 ;; esac
  for write_condition in "$@"; do valid_schedule "$write_condition" || return 2; done
  if [ -z "$write_id" ]; then
    rule_count=0
    for existing_rule in "$RULE_DIR"/*.conf; do
      [ -f "$existing_rule" ] && rule_count=$((rule_count + 1))
    done
    [ "$rule_count" -lt 100 ] || return 1
    while :; do
      write_id="auto-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
      valid_id "$write_id" || continue
      [ ! -e "$RULE_DIR/$write_id.conf" ] && break
    done
  else
    valid_id "$write_id" || return 2
    [ -f "$(rule_file "$write_id")" ] || return 1
  fi
  write_tmp="$RULE_DIR/.${write_id}.$$"
  {
    printf 'id=%s\nname=%s\naction=%s\nenabled=%s\npriority=%s\nmode=%s\n' \
      "$write_id" "$write_name" "$write_action_name" "$write_enabled" "$write_priority" "$write_mode"
    for write_condition in "$@"; do printf 'condition=%s\n' "$write_condition"; done
  } > "$write_tmp" || { rm -f "$write_tmp"; return 1; }
  chmod 0600 "$write_tmp" && mv -f "$write_tmp" "$(rule_file "$write_id")" || {
    rm -f "$write_tmp"
    return 1
  }
  printf '%s\n' "$write_id"
}

list_rules() {
  for file in "$RULE_DIR"/*.conf; do
    [ -f "$file" ] || continue
    parse_rule "$file" || continue
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$parsed_id" "$parsed_name" "$parsed_action" "$parsed_enabled" "$parsed_priority" "$parsed_mode" "$parsed_conditions"
  done | sort -t "$(printf '\t')" -k5,5nr -k1,1
}

delete_rule() {
  delete_file="$(rule_file "$1")" || return 2
  [ -f "$delete_file" ] || return 1
  rm -f "$delete_file"
}

valid_journal_key() {
  journal_key_value="${1:-}"
  case "$journal_key_value" in *:*) journal_key_rule="${journal_key_value%%:*}"; journal_key_time="${journal_key_value#*:}" ;; *) return 1 ;; esac
  valid_id "$journal_key_rule" || return 1
  case "$journal_key_time" in ????-??-??T??:??) ;; *) return 1 ;; esac
  case "$journal_key_time" in *[!0-9T:-]*) return 1 ;; esac
  case "${journal_key_time#*T}" in [01][0-9]:[0-5][0-9]|2[0-3]:[0-5][0-9]) return 0 ;; esac
  return 1
}

valid_journal_line() {
  set -f
  set -- $1
  [ "$#" -eq 6 ] || { set +f; return 1; }
  set +f
  [ "$1" = v=1 ] || return 1
  case "$2" in
    ts=????-??-??T??:??:??+[0-9][0-9]:[0-9][0-9]|ts=????-??-??T??:??:??-[0-9][0-9]:[0-9][0-9]) ;;
    *) return 1 ;;
  esac
  journal_timestamp="${2#ts=}"
  case "$journal_timestamp" in *[!0-9T:+-]*) return 1 ;; esac
  case "$3" in rule=auto-[a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9]) ;; *) return 1 ;; esac
  case "$4" in action=connect|action=disconnect) ;; *) return 1 ;; esac
  case "$5" in event=started|event=success|event=skipped|event=failed|event=conflict) ;; *) return 1 ;; esac
  case "$6" in key=*) valid_journal_key "${6#key=}" || return 1 ;; *) return 1 ;; esac
  journal_line_rule="${3#rule=}"
  journal_line_key="${6#key=}"
  [ "$journal_line_rule" = "${journal_line_key%%:*}" ] || return 1
  return 0
}

journal_event() {
  journal_rule="$1"
  journal_action_name="$2"
  journal_event_name="$3"
  journal_key="$4"
  valid_id "$journal_rule" && valid_action "$journal_action_name" || return 1
  case "$journal_event_name" in started|success|skipped|failed|conflict) ;; *) return 1 ;; esac
  valid_journal_key "$journal_key" || return 1
  journal_rotate || return 1
  printf 'v=1 ts=%s rule=%s action=%s event=%s key=%s\n' \
    "$(date '+%Y-%m-%dT%H:%M:%S%z' | sed 's/\([+-][0-9][0-9]\)\([0-9][0-9]\)$/\1:\2/')" "$journal_rule" "$journal_action_name" \
    "$journal_event_name" "$journal_key" >> "$JOURNAL"
}

journal_rotate() {
  [ -f "$JOURNAL" ] || return 0
  journal_size="$(wc -c < "$JOURNAL" | tr -d ' ')"
  case "$journal_size" in ''|*[!0-9]*) return 0 ;; esac
  [ "$journal_size" -ge 262144 ] || return 0
  journal_today="$(date '+%Y-%m-%d')"
  checkpoint_raw="$NB_RUN_DIR/automation.checkpoint.raw.$$"
  checkpoint_tmp="$NB_RUN_DIR/automation.checkpoint.$$"
  : > "$checkpoint_raw" || return 1
  for checkpoint_source in "$NB_RUN_DIR/automation.checkpoint" "$JOURNAL"; do
    [ -f "$checkpoint_source" ] || continue
    while IFS= read -r checkpoint_line || [ -n "$checkpoint_line" ]; do
      case "$checkpoint_line" in
        key=*) checkpoint_key="${checkpoint_line#key=}" ;;
        *) valid_journal_line "$checkpoint_line" || continue; checkpoint_key="${checkpoint_line##* key=}" ;;
      esac
      valid_journal_key "$checkpoint_key" || continue
      case "$checkpoint_key" in *:"$journal_today"T*) printf 'key=%s\n' "$checkpoint_key" >> "$checkpoint_raw" ;; esac
    done < "$checkpoint_source"
  done
  sort -u "$checkpoint_raw" > "$checkpoint_tmp" || {
    rm -f "$checkpoint_raw" "$checkpoint_tmp"
    return 1
  }
  rm -f "$checkpoint_raw"
  chmod 0600 "$checkpoint_tmp" && mv -f "$checkpoint_tmp" "$NB_RUN_DIR/automation.checkpoint" || {
    rm -f "$checkpoint_tmp"
    return 1
  }
  mv -f "$JOURNAL" "$JOURNAL.1" || return 1
}

journal_has_key() {
  journal_wanted="$1"
  for checkpoint_source in "$NB_RUN_DIR/automation.checkpoint" "$JOURNAL" "$JOURNAL.1"; do
    [ -f "$checkpoint_source" ] || continue
    while IFS= read -r journal_line || [ -n "$journal_line" ]; do
      case "$checkpoint_source:$journal_line" in
        *automation.checkpoint:key=*)
          [ "${journal_line#key=}" = "$journal_wanted" ] && valid_journal_key "${journal_line#key=}" && return 0
          ;;
        *)
          valid_journal_line "$journal_line" || continue
          journal_key_field="${journal_line##* key=}"
          [ "$journal_key_field" = "$journal_wanted" ] && return 0
          ;;
      esac
    done < "$checkpoint_source"
  done
  return 1
}

journal_has_event() {
  journal_wanted_key="$1"
  journal_wanted_event="$2"
  for journal_source in "$NB_RUN_DIR/automation.checkpoint" "$JOURNAL" "$JOURNAL.1"; do
    [ -f "$journal_source" ] || continue
    while IFS= read -r journal_line || [ -n "$journal_line" ]; do
      valid_journal_line "$journal_line" || continue
      case "$journal_line" in *" event=$journal_wanted_event key=$journal_wanted_key") return 0 ;; esac
    done < "$journal_source"
  done
  return 1
}

journal_list() {
  [ -f "$JOURNAL" ] || [ -f "$JOURNAL.1" ] || return 0
  for journal_source in "$JOURNAL.1" "$JOURNAL"; do
    [ -f "$journal_source" ] || continue
    while IFS= read -r journal_line || [ -n "$journal_line" ]; do
      valid_journal_line "$journal_line" && printf '%s\n' "$journal_line"
    done < "$journal_source"
  done
}

schedule_occurrence() {
  occurrence_schedule="$1"
  now_epoch="$(date '+%s')"
  now_date="$(date '+%Y-%m-%d')"
  now_day="$(date '+%u')"
  case "$occurrence_schedule" in
    once:*)
      occurrence="${occurrence_schedule#once:}"
      occurrence_date="${occurrence%T*}"
      occurrence_time="${occurrence#*T}"
      ;;
    daily:*) occurrence_date="$now_date"; occurrence_time="${occurrence_schedule#daily:}" ;;
    weekdays:*)
      [ "$now_day" -le 5 ] || return 1
      occurrence_date="$now_date"
      occurrence_time="${occurrence_schedule#weekdays:}"
      ;;
    weekly:*)
      occurrence_day="${occurrence_schedule#weekly:}"
      occurrence_day="${occurrence_day%%@*}"
      [ "$now_day" = "$occurrence_day" ] || return 1
      occurrence_date="$now_date"
      occurrence_time="${occurrence_schedule##*@}"
      ;;
    *) return 1 ;;
  esac
  occurrence_epoch="$(date -d "$occurrence_date $occurrence_time" '+%s' 2>/dev/null || true)"
  case "$occurrence_epoch" in ''|*[!0-9]*) return 1 ;; esac
  delta=$((now_epoch - occurrence_epoch))
  [ "$delta" -ge 0 ] && [ "$delta" -le 300 ] || return 1
  printf '%sT%s\n' "$occurrence_date" "$occurrence_time"
}

automation_daemon_running() {
  if command -v busybox >/dev/null 2>&1; then
    busybox pgrep -f "$NB_DAEMON_CMD" >/dev/null 2>&1
  else
    ps -A -o PID,ARGS 2>/dev/null | awk '/netbird service run/ && $0 !~ /awk/ { found = 1 } END { exit !found }'
  fi
}

automation_status_json() {
  if command -v busybox >/dev/null 2>&1; then
    busybox timeout 10 netbird --daemon-addr "$NB_DAEMON_ADDR" status --json 2>/dev/null
  else
    netbird --daemon-addr "$NB_DAEMON_ADDR" status --json 2>/dev/null
  fi
}

execute_rule() {
  execute_id="$1"
  execute_action="$2"
  execute_key="$3"
  execute_service="$NB_SCRIPTS_DIR/netbird.service"
  if automation_daemon_running; then
    execute_status="$(automation_status_json || true)"
  else
    execute_status=""
  fi
  case "$execute_action:$execute_status" in
    connect:*'"daemonStatus":"Connected"'*)
      journal_event "$execute_id" "$execute_action" skipped "$execute_key"
      return 0
      ;;
    disconnect:*'"daemonStatus":"Disconnected"'*)
      journal_event "$execute_id" "$execute_action" skipped "$execute_key"
      return 0
      ;;
  esac
  if [ "$execute_action" = disconnect ] && ! automation_daemon_running; then
    journal_event "$execute_id" "$execute_action" skipped "$execute_key"
    return 0
  fi
  journal_event "$execute_id" "$execute_action" started "$execute_key" || return 1
  execute_command=up
  [ "$execute_action" = connect ] || execute_command=down
  "$execute_service" "$execute_command" >/dev/null 2>&1
  execute_rc="$?"
  if [ "$execute_rc" -eq 0 ]; then
    journal_event "$execute_id" "$execute_action" success "$execute_key"
  else
    journal_event "$execute_id" "$execute_action" failed "$execute_key"
  fi
  return "$execute_rc"
}

# `all` requires every condition to resolve to the same planned minute;
# `any` evaluates each due planned minute independently.
evaluate_occurrence() {
  evaluate_id="$1"
  evaluate_action="$2"
  evaluate_key="$evaluate_id:$3"
  chosen_action="$(awk -F '\t' -v wanted="$3" '$1 == wanted { print $2; exit }' "$occurrence_actions")"
  if [ -z "$chosen_action" ]; then
    printf '%s\t%s\n' "$3" "$evaluate_action" >> "$occurrence_actions"
    chosen_action="$evaluate_action"
  fi
  if [ "$chosen_action" != "$evaluate_action" ]; then
    journal_has_event "$evaluate_key" conflict || journal_event "$evaluate_id" "$evaluate_action" conflict "$evaluate_key"
    return 0
  fi
  journal_has_key "$evaluate_key" && return 0
  execute_rule "$evaluate_id" "$evaluate_action" "$evaluate_key" || true
}

evaluate_rules() {
  acquire_lock || return 1
  occurrence_actions="$NB_RUN_DIR/automation.actions.$$"
  rules_tmp="$NB_RUN_DIR/automation.rules.$$"
  : > "$occurrence_actions" || { release_lock; return 1; }
  list_rules > "$rules_tmp" || { rm -f "$rules_tmp" "$occurrence_actions"; release_lock; return 1; }
  while IFS="$(printf '\t')" read -r parsed_id parsed_name parsed_action parsed_enabled parsed_priority parsed_mode parsed_conditions; do
    [ "$parsed_enabled" = 1 ] || continue
    due_occurrences=""
    matched_conditions=0
    condition_count=0
    for parsed_schedule in $(printf '%s' "$parsed_conditions" | tr ',' ' '); do
      condition_count=$((condition_count + 1))
      occurrence="$(schedule_occurrence "$parsed_schedule" 2>/dev/null || true)"
      [ -n "$occurrence" ] || continue
      matched_conditions=$((matched_conditions + 1))
      case " $due_occurrences " in *" $occurrence "*) ;; *) due_occurrences="${due_occurrences}${due_occurrences:+ }$occurrence" ;; esac
    done
    [ -n "$due_occurrences" ] || continue
    case "$parsed_mode" in
      all)
        [ "$matched_conditions" -eq "$condition_count" ] || continue
        set -- $due_occurrences
        [ "$#" -eq 1 ] || continue
        evaluate_occurrence "$parsed_id" "$parsed_action" "$1"
        ;;
      any)
        for due_occurrence in $due_occurrences; do
          evaluate_occurrence "$parsed_id" "$parsed_action" "$due_occurrence"
        done
        ;;
    esac
  done < "$rules_tmp"
  rm -f "$rules_tmp" "$occurrence_actions"
  release_lock
}

if [ "${NB_AUTOMATION_LIBRARY_ONLY:-0}" != 1 ]; then
case "${1:-}" in
  list)
    mkdir -p "$RULE_DIR"
    list_rules
    ;;
  save)
    shift
    [ "$#" -ge 7 ] && [ "$#" -le 14 ] || exit 2
    acquire_lock || exit 1
    saved_id="$(write_rule "$@")"
    save_rc="$?"
    release_lock
    [ "$save_rc" -eq 0 ] || exit "$save_rc"
    printf '%s\n' "$saved_id"
    ;;
  delete)
    shift
    [ "$#" -eq 1 ] || exit 2
    acquire_lock || exit 1
    delete_rule "$1"
    delete_rc="$?"
    release_lock
    exit "$delete_rc"
    ;;
  evaluate)
    evaluate_rules
    ;;
  log)
    journal_list
    ;;
  *)
    echo "usage: automation.sh {list|save id-or-new name action enabled priority mode condition...|delete id|evaluate|log}" >&2
    exit 2
    ;;
esac
fi
