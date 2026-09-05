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

. "$ART_DIR/config.sh"

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
# Args: count start now interval_days
compute_pool_index() {
  count="$1"; start="$2"; now="$3"; interval="$4"
  day=$(( now / 86400 ))
  [ "$day" -lt "$start" ] && day=$start
  IDX=$(( ((day - start) / interval) % count + 1 ))
  IMG_FILE=$(printf '%03d.png' "$IDX")
}

# Wrapper that calls date itself (so tests can stub `date` and exercise the
# real call site). Requires INTERVAL_DAYS to already be set. Sets IDX/IMG_FILE.
pool_index_now() {
  count="$1"; start="$2"
  now=$(date -u +%s)
  compute_pool_index "$count" "$start" "$now" "$INTERVAL_DAYS"
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

# Writes the RTC wakealarm for the given number of seconds from now, reads
# it back and logs it, falling back from rtc1 to rtc0 if the read-back is
# empty. Attempts "echo mem > /sys/power/state" once and reports whether the
# device appeared to actually sleep (elapsed >= 30s) or was refused (fast
# return). Returns 0 if it slept, 1 if refused.
suspend_once() {
  secs="$1"
  rtc=/sys/class/rtc/rtc1
  echo "" >"$rtc/wakealarm" 2>/dev/null
  echo "+$secs" >"$rtc/wakealarm" 2>/dev/null
  wa=$(cat "$rtc/wakealarm" 2>/dev/null)
  if [ -z "$wa" ]; then
    log "rtc1 wakealarm read back empty, falling back to rtc0"
    rtc=/sys/class/rtc/rtc0
    echo "" >"$rtc/wakealarm" 2>/dev/null
    echo "+$secs" >"$rtc/wakealarm" 2>/dev/null
    wa=$(cat "$rtc/wakealarm" 2>/dev/null)
  fi
  se=$(cat "$rtc/since_epoch" 2>/dev/null)
  log "wakealarm=$wa since_epoch=$se rtc=$rtc"
  before=$(date -u +%s)
  echo mem >/sys/power/state 2>/dev/null
  after=$(date -u +%s)
  elapsed=$(( after - before ))
  if [ "$elapsed" -lt 30 ]; then
    log "suspend returned after ${elapsed}s - refused"
    return 1
  fi
  log "resumed after ${elapsed}s asleep"
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
    log "day-index: count=$count start=$start interval=${INTERVAL_DAYS} -> idx=$IDX file=$IMG_FILE"

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
