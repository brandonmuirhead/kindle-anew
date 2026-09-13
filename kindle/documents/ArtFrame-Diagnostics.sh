#!/bin/sh
# Art Frame - Diagnostics
# Collects device facts into /mnt/us/artframe/diag.txt so the loop script can be
# written against the real device. SAFE: never suspends, never stops the UI.
# Run by tapping this file in the Kindle library (scriptlet).

D=/mnt/us/artframe
mkdir -p "$D/logs"
OUT="$D/diag.txt"
exec >"$OUT" 2>&1

sec() { echo; echo "===== $* ====="; }
run() { echo "\$ $*"; "$@"; echo "[exit $?]"; }

echo "Art Frame diagnostics  $(date -u '+%Y-%m-%d %H:%M:%S') UTC"

sec identity
run id
run uname -a
run cat /etc/prettyversion.txt
run cat /proc/version

sec "script context"
echo "\$0=$0  args=$*  PPID=$PPID"
echo "parent cmdline: $(tr '\0' ' ' </proc/$PPID/cmdline 2>/dev/null)"
run pwd
run env

sec processes
run ps

sec rtc
run ls -la /sys/class/rtc/
for r in /sys/class/rtc/rtc*; do
  echo "$r: name=[$(cat "$r/name" 2>&1)] wakealarm=[$(cat "$r/wakealarm" 2>&1)] since_epoch=[$(cat "$r/since_epoch" 2>&1)]"
done
run cat /sys/power/state
run ls -la /sys/devices/platform/mxc_rtc.0/
run ls -la /sys/power/

sec display
run eips -i

sec mounts
run mount
run df -h

sec tools
for t in xh curl wget rtcwake setsid nohup gasgauge-info lipc-set-prop lipc-get-prop lipc-wait-event initctl eips fbink sed awk ping date sleep; do
  printf '%-16s %s\n' "$t" "$(command -v "$t" 2>/dev/null || echo MISSING)"
done
run curl -V
echo "\$ wget --help (head)"; wget --help 2>&1 | head -4

sec services
echo "\$ initctl list (filtered)"; initctl list 2>&1 | grep -iE 'framework|powerd|wifid|cmd|pillow|webreader|lab126|blanket'

sec power
run lipc-get-prop com.lab126.powerd status
run lipc-get-prop com.lab126.powerd preventScreenSaver
run gasgauge-info -c
run gasgauge-info -s
run cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
run cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors

sec wifi
run lipc-get-prop com.lab126.wifid cmState
run lipc-get-prop com.lab126.wifid signalStrength
run lipc-get-prop com.lab126.cmd wirelessEnable
run ifconfig wlan0
run ping -c 2 -W 3 1.1.1.1

sec "network path (separates 'no network' from 'ICMP blocked')"
run route -n
GW=$(route -n 2>/dev/null | awk '$1=="0.0.0.0"{print $2; exit}')
echo "default gateway=[$GW]"
[ -n "$GW" ] && run ping -c 2 -W 3 "$GW"
run cat /etc/resolv.conf
if command -v nslookup >/dev/null 2>&1; then
  run nslookup brandonmuirhead.github.io
fi

sec "BASE_URL reachability (exactly what the frame fetches)"
BASE_URL=""
[ -f "$D/config.sh" ] && . "$D/config.sh"
echo "BASE_URL=[$BASE_URL]"
if [ -n "$BASE_URL" ]; then
  echo "\$ curl $BASE_URL/pool.txt"
  curl -sS -o /var/tmp/diag_pool.txt \
       -w 'http=%{http_code} ssl_verify=%{ssl_verify_result} time=%{time_total}s size=%{size_download}\n' \
       --max-time 30 "$BASE_URL/pool.txt" 2>&1
  echo "[exit $?]"
  echo "--- pool.txt contents (expect two numbers: count, start-day) ---"
  cat /var/tmp/diag_pool.txt 2>&1
  echo "--- if that is HTML, this network has a captive portal or a filter ---"

  echo "\$ curl $BASE_URL/art/001.png"
  curl -sS -o /var/tmp/diag_art.png \
       -w 'http=%{http_code} ssl_verify=%{ssl_verify_result} time=%{time_total}s size=%{size_download}\n' \
       --max-time 60 "$BASE_URL/art/001.png" 2>&1
  echo "[exit $?]"
  run ls -la /var/tmp/diag_art.png
  echo "--- first 8 bytes (a real PNG is 137 80 78 71 13 10 26 10) ---"
  od -An -tu1 -N8 /var/tmp/diag_art.png 2>&1

  echo "--- same request with -k: if this succeeds where the above failed,"
  echo "--- a proxy is intercepting TLS with a CA this Kindle does not trust ---"
  run curl -k -sS -o /dev/null -w '%{http_code}\n' --max-time 30 "$BASE_URL/pool.txt"
  rm -f /var/tmp/diag_pool.txt /var/tmp/diag_art.png
fi

sec "xh from /var/tmp (noexec workaround)"
run cp "$D/xh" /var/tmp/xh
run chmod +x /var/tmp/xh
run /var/tmp/xh --version
run /var/tmp/xh -d -o /var/tmp/diag_dl.png get https://raw.githubusercontent.com/pascalw/kindle-dash/main/example/example.png
run ls -la /var/tmp/diag_dl.png

sec "built-in curl TLS (without and with -k)"
run curl -sS -o /dev/null -w '%{http_code}\n' --max-time 30 https://raw.githubusercontent.com/pascalw/kindle-dash/main/example/example.png
run curl -k -sS -o /dev/null -w '%{http_code}\n' --max-time 30 https://raw.githubusercontent.com/pascalw/kindle-dash/main/example/example.png

sec "fbink shipped by the jailbreak (libkh)"
run ls -la /mnt/us/libkh/bin/
run /mnt/us/libkh/bin/fbink -v
run cp /mnt/us/libkh/bin/fbink /var/tmp/fbink
run chmod +x /var/tmp/fbink
run /var/tmp/fbink -v
run /var/tmp/fbink -e

sec "test image on panel (16-level ramp, 1072x1448 8-bit gray)"
run eips -f -g "$D/test.png"
sleep 8

echo
echo "diag done $(date -u '+%H:%M:%S')"
eips 0 0 "diag done - artframe/diag.txt"
exit 0
