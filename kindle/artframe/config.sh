#!/bin/sh
# Art Frame - configuration
#
# This file is sourced (". config.sh"), never executed, by loop.sh, fetch.sh
# and the scriptlets that need BASE_URL. Keep it plain "VAR=value" lines: no
# command substitution that could fail, no arrays, no bashisms.
#
# See PLAN.md section 5 ("config.sh") for the source of truth.

BASE_URL="https://brandonmuirhead.github.io/kindle-anew"   # no trailing slash
WAKE_HOUR_UTC=9          # 0-23; 09 UTC = 04:00 EST / 05:00 EDT
INTERVAL_DAYS=1          # 1 = daily, 2 = every other day
WIFI_TEST_IP=1.1.1.1
WIFI_TIMEOUT=90          # seconds to wait for network after wake
RETRY_SECS=3600          # sleep before retrying after a failed fetch
LOW_BATTERY_PCT=10
INTERVAL_MINUTES_TEST=0  # >0 overrides the daily schedule (for testing only)
