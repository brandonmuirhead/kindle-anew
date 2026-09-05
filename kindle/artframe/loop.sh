#!/bin/sh
# Art Frame - main loop.
#
# Runs detached (via setsid, launched by the ArtFrame-Start scriptlet),
# stops the Kindle UI framework, and repeatedly: checks battery, waits for
# Wi-Fi, fetches today's pool image, paints it with eips, turns the front
# light off, sets an RTC wake alarm and suspends. See PLAN.md section 5
# ("loop.sh") for the exact spec this file implements.
#
# POSIX sh (busybox ash) only. Invoked as "sh /mnt/us/artframe/loop.sh".
# All output goes to stdout/stderr, which the Start scriptlet has already
# redirected (append) to /mnt/us/artframe/logs/artframe.log; log() below
# additionally rotates that file once it exceeds 200 KB.
#
# Testability: ART_DIR defaults to the real device path but can be
# overridden by the environment (used by the local arithmetic tests under
# Git Bash). Setting ARTFRAME_SOURCED_FOR_TEST=1 before sourcing this file
# loads every function definition without starting main(), so the pure
# arithmetic helpers (compute_pool_index, compute_next_wake_secs and their
# date-calling wrappers) can be exercised directly with a stubbed `date`.

ART_DIR="${ART_DIR:-/mnt/us/artframe}"
LOG="$ART_DIR/logs/artframe.log"
# A short power-button press while asleep = "next picture". Each press adds 1
# to this file, which shifts the whole rotation forward. Delete it to reset.
OFFSET_FILE="$ART_DIR/offset.txt"
EARLY_WAKE=0

. "$ART_DIR/config.sh"

read_offset() {
  o=""
  [ -f "$OFFSET_FILE" ] && o=$(tr -dc '0-9' <"$OFFSET_FILE")
  [ -z "$o" ] && o=0
  echo "$o"
}

# --- logging ---------------------------------------------------------------

ts() { date -u '+%Y-%m-%d %H:%M:%S'; }

log() {
  echo "[$(ts)] $*"
}

# Rotates $LOG (single .old backup) once it exceeds 200 KB. Reopens our own
# stdout/stderr onto the (now fresh) log path so appends keep working
# regardless of how the process was originally launched.
rotate_log_if_needed() {
  sz=$(wc -c <"$LOG" 2>/dev/null)
  case "$sz" in
    ''|*[!0-9]*) return 0 ;;
  esac
  if [ "$sz" -gt 204800 ]; then
    mv -f "$LOG" "$LOG.old" 2>/dev/null
    exec >>"$LOG" 2>&1
    log "rotated log (was ${sz} bytes)"
  fi
}

# --- front light -------------------------------------------------------------

FRONTLIGHT_LOGGED=0

# Turns the front light off via lipc and every backlight sysfs node we can
# find. Never turns it back on. Logs the backlight node list and the
# post-set flIntensity value exactly once per loop.sh run so we learn the
# exact node on this device.
frontlight_off() {
  lipc-set-prop com.lab126.powerd flIntensity 0 2>/dev/null
  for b in /sys/class/backlight/*/brightness; do
    [ -e "$b" ] || continue
    echo 0 >"$b" 2>/dev/null
  done
  if [ "$FRONTLIGHT_LOGGED" -eq 0 ]; then
    log "backlight nodes: $(ls -la /sys/class/backlight/ 2>&1 | tr '\n' ' ')"
    log "flIntensity now: $(lipc-get-prop com.lab126.powerd flIntensity 2>&1)"
    FRONTLIGHT_LOGGED=1
  fi
}

# --- Wi-Fi -------------------------------------------------------------------

# Pings WIFI_TEST_IP once a second for up to WIFI_TIMEOUT seconds. After 30 s
# of failure, nudges wifid/cmd back on once. Returns 0 once a ping succeeds,
# 1 on timeout.
wait_for_wifi() {
  waited=0
  nudged=0
  while :; do
    if ping -c 1 "$WIFI_TEST_IP" >/dev/null 2>&1; then
      log "wifi up after ${waited}s"
      return 0
    fi
    if [ "$waited" -ge "$WIFI_TIMEOUT" ]; then
      log "wifi wait timed out after ${WIFI_TIMEOUT}s"
      return 1
    fi
    if [ "$waited" -ge 30 ] && [ "$nudged" -eq 0 ]; then
      log "wifi still down after 30s, nudging wifid/cmd back on"
      lipc-set-prop com.lab126.cmd wirelessEnable 1 2>/dev/null
      lipc-set-prop com.lab126.wifid enable 1 2>/dev/null
      nudged=1
    fi
    sleep 1
    waited=$((waited + 1))
  done
}

# --- pool day-index arithmetic (pure; testable) -----------------------------

# Sets globals IDX (1-based) and IMG_FILE ("NNN.png").
# Args: count start now interval_days [offset]
compute_pool_index() {
  count="$1"; start="$2"; now="$3"; interval="$4"; offset="${5:-0}"
  day=$(( now / 86400 ))
  [ "$day" -lt "$start" ] && day=$start
  IDX=$(( ((day - start) / interval + offset) % count + 1 ))
  IMG_FILE=$(printf '%03d.png' "$IDX")
}

# Wrapper that calls date itself (so tests can stub `date` and exercise the
# real call site). Requires INTERVAL_DAYS to already be set. Sets IDX/IMG_FILE.
pool_index_now() {
  count="$1"; start="$2"
  now=$(date -u +%s)
  compute_pool_index "$count" "$start" "$now" "$INTERVAL_DAYS" "$(read_offset)"
}

# --- next-wake arithmetic (pure; testable) ----------------------------------

# Sets global SLEEP_SECS. Args: now wake_hour_utc interval_days interval_minutes_test
compute_next_wake_secs() {
  now="$1"; wake_hour="$2"; interval="$3"; minutes_test="$4"
  if [ -n "$minutes_test" ] && [ "$minutes_test" -gt 0 ] 2>/dev/null; then
    SLEEP_SECS=$(( minutes_test * 60 ))
    return 0
  fi
  day_start=$(( now - now % 86400 ))
  target=$(( day_start + wake_hour * 3600 ))
  [ "$target" -le "$(( now + 120 ))" ] && target=$(( target + 86400 ))
  SLEEP_SECS=$(( target - now + (interval - 1) * 86400 ))
}

# Wrapper that calls date itself. Requires WAKE_HOUR_UTC, INTERVAL_DAYS,
# INTERVAL_MINUTES_TEST to already be set. Sets SLEEP_SECS.
next_wake_now() {
  now=$(date -u +%s)
  compute_next_wake_secs "$now" "$WAKE_HOUR_UTC" "$INTERVAL_DAYS" "$INTERVAL_MINUTES_TEST"
}

# --- suspend / RTC alarm -----------------------------------------------------

# Arms the RTC wakealarm for $1 seconds from now (clearing any pending alarm
# first), reads it back, and falls back from rtc1 to rtc0 if the read-back is
# empty. Sets RTC_USED and ALARM_AT (epoch seconds, or empty on failure).
arm_alarm() {
  secs="$1"
  RTC_USED=/sys/class/rtc/rtc1
  echo "" >"$RTC_USED/wakealarm" 2>/dev/null
  echo "+$secs" >"$RTC_USED/wakealarm" 2>/dev/null
  ALARM_AT=$(cat "$RTC_USED/wakealarm" 2>/dev/null)
  if [ -z "$ALARM_AT" ]; then
    log "rtc1 wakealarm read back empty, falling back to rtc0"
    RTC_USED=/sys/class/rtc/rtc0
    echo "" >"$RTC_USED/wakealarm" 2>/dev/null
    echo "+$secs" >"$RTC_USED/wakealarm" 2>/dev/null
    ALARM_AT=$(cat "$RTC_USED/wakealarm" 2>/dev/null)
  fi
  [ -n "$ALARM_AT" ]
}

# Arms the alarm, suspends with "echo mem > /sys/power/state", and classifies
# the return: refused (write failed or came back within 3 s) -> return 1;
# woke at our alarm -> EARLY_WAKE=0; woke before our alarm (power button, or
# another RTC alarm the system had pending on rtc0) -> EARLY_WAKE=1 for a
# button press, 0 if it matched that other alarm. Returns 0 whenever the
# device actually slept.
suspend_once() {
  secs="$1"
  arm_alarm "$secs"
  se=$(cat "$RTC_USED/since_epoch" 2>/dev/null)
  other_alarm=""
  [ "$RTC_USED" != /sys/class/rtc/rtc0 ] && other_alarm=$(cat /sys/class/rtc/rtc0/wakealarm 2>/dev/null)
  log "wakealarm=$ALARM_AT since_epoch=$se rtc=$RTC_USED rtc0_alarm=[$other_alarm]"
  before=$(date -u +%s)
  if ! echo mem >/sys/power/state 2>/dev/null; then
    log "suspend write to /sys/power/state failed - refused"
    return 1
  fi
  after=$(date -u +%s)
  elapsed=$(( after - before ))
  if [ "$elapsed" -lt 3 ]; then
    log "suspend returned after ${elapsed}s - refused"
    return 1
  fi
  EARLY_WAKE=0
  rtc_now=$(cat "$RTC_USED/since_epoch" 2>/dev/null)
  case "$rtc_now$ALARM_AT" in *[!0-9]*|'') rtc_now="" ;; esac
  if [ -n "$rtc_now" ] && [ "$rtc_now" -lt $(( ALARM_AT - 5 )) ]; then
    if [ -n "$other_alarm" ] && [ "$rtc_now" -ge $(( other_alarm - 5 )) ] && [ "$rtc_now" -le $(( other_alarm + 5 )) ]; then
      log "woke early after ${elapsed}s at the system's rtc0 alarm, not a button press"
    else
      EARLY_WAKE=1
      log "woke early after ${elapsed}s (our alarm was $(( ALARM_AT - rtc_now ))s away): treating as a power-button press"
    fi
  else
    log "resumed after ${elapsed}s asleep"
  fi
  return 0
}

# Clamps sleep_secs to [60, 3*86400], logs, then tries to suspend up to 10
# times (60s apart) before falling back to a plain `sleep`.
enter_sleep() {
  [ "$sleep_secs" -lt 60 ] && sleep_secs=60
  [ "$sleep_secs" -gt 259200 ] && sleep_secs=259200
  log "sleeping ${sleep_secs}s, battery ${batt:-unknown}%"
  fails=0
  while [ "$fails" -lt 10 ]; do
    if suspend_once "$sleep_secs"; then
      return 0
    fi
    fails=$((fails + 1))
    sleep 60
  done
  log "suspend refused 10 times in a row, falling back to plain sleep ${sleep_secs}s"
  sleep "$sleep_secs"
  return 0
}

# --- main --------------------------------------------------------------------

main() {
  sleep 5
  lipc-set-prop com.lab126.powerd preventScreenSaver 1 2>/dev/null
  frontlight_off
  initctl stop lab126_gui 2>/dev/null
  sleep 3
  echo powersave >/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null

  while true; do
    rotate_log_if_needed
    log "--- iteration start ---"

    # Safety net: if anything else (powerd reacting to the button, a crash)
    # suspends the device mid-iteration, this alarm still brings it back.
    # enter_sleep replaces it with the real one at the end of the iteration.
    arm_alarm "$RETRY_SECS"

    if [ "$EARLY_WAKE" = 1 ]; then
      EARLY_WAKE=0
      off=$(( $(read_offset) + 1 ))
      echo "$off" >"$OFFSET_FILE"
      log "power button: skipping to the next picture (offset now $off)"
      lipc-set-prop com.lab126.powerd preventScreenSaver 1 2>/dev/null
      lipc-set-prop com.lab126.powerd deferSuspend 60000 2>/dev/null
      log "powerd after button wake: $(lipc-get-prop com.lab126.powerd status 2>&1 | tr '\n' ' ' | tr -s ' ')"
      log "dmesg tail: $(dmesg 2>/dev/null | tail -6 | tr '\n' '|')"
    fi

    batt=$(gasgauge-info -c 2>/dev/null | tr -dc '0-9')
    [ -z "$batt" ] && { log "gasgauge-info returned no battery reading, assuming OK"; batt=100; }
    log "battery=${batt}%"

    if [ "$batt" -lt "$LOW_BATTERY_PCT" ]; then
      log "battery ${batt}% < LOW_BATTERY_PCT=${LOW_BATTERY_PCT}%, showing charge screen"
      eips -f -g "$ART_DIR/charge.png"
      frontlight_off
      sleep_secs=86400
      enter_sleep
      continue
    fi

    if ! wait_for_wifi; then
      sleep_secs="$RETRY_SECS"
      enter_sleep
      continue
    fi

    POOL_TMP="$ART_DIR/pool.txt.tmp"
    if ! sh "$ART_DIR/fetch.sh" "$BASE_URL/pool.txt" "$POOL_TMP"; then
      log "failed to fetch pool.txt"
      sleep_secs="$RETRY_SECS"
      enter_sleep
      continue
    fi
    count=$(sed -n '1p' "$POOL_TMP" 2>/dev/null | tr -dc '0-9')
    start=$(sed -n '2p' "$POOL_TMP" 2>/dev/null | tr -dc '0-9')
    rm -f "$POOL_TMP"
    if [ -z "$count" ] || [ "$count" -le 0 ] 2>/dev/null || [ -z "$start" ] || [ "$start" -le 0 ] 2>/dev/null; then
      log "pool.txt invalid: count=[$count] start=[$start]"
      sleep_secs="$RETRY_SECS"
      enter_sleep
      continue
    fi

    pool_index_now "$count" "$start"
    log "day-index: count=$count start=$start interval=${INTERVAL_DAYS} offset=$(read_offset) -> idx=$IDX file=$IMG_FILE"

    NEW_PNG="$ART_DIR/new.png"
    if ! sh "$ART_DIR/fetch.sh" "$BASE_URL/art/$IMG_FILE" "$NEW_PNG" png; then
      log "failed to fetch art/$IMG_FILE"
      sleep_secs="$RETRY_SECS"
      enter_sleep
      continue
    fi
    newsz=$(wc -c <"$NEW_PNG" 2>/dev/null)
    case "$newsz" in ''|*[!0-9]*) newsz=0 ;; esac
    if [ "$newsz" -lt 10240 ]; then
      log "art/$IMG_FILE too small (${newsz} bytes), rejecting and keeping current picture"
      rm -f "$NEW_PNG"
      sleep_secs="$RETRY_SECS"
      enter_sleep
      continue
    fi

    mv -f "$NEW_PNG" "$ART_DIR/current.png"
    eips -f -g "$ART_DIR/current.png"
    log "painted $IMG_FILE"
    sleep 3
    frontlight_off

    next_wake_now
    log "next wake in ${SLEEP_SECS}s (WAKE_HOUR_UTC=${WAKE_HOUR_UTC} INTERVAL_DAYS=${INTERVAL_DAYS} INTERVAL_MINUTES_TEST=${INTERVAL_MINUTES_TEST})"
    sleep_secs="$SLEEP_SECS"
    enter_sleep
  done
}

if [ "${ARTFRAME_SOURCED_FOR_TEST:-0}" != "1" ]; then
  main
fi
