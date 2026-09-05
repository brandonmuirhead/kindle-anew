#!/bin/sh
# Art Frame - Test Display (scriptlet). Tap this to sanity-check Wi-Fi, TLS
# and image painting without stopping the framework or suspending the
# device. Safe to run repeatedly; the UI repaints itself afterwards.
#
# Per PLAN.md section 5 ("ArtFrame-TestDisplay.sh"): fetch art/001.png
# (fallback: the bundled charge.png), paint it with eips, wait 15s, clear.

D=/mnt/us/artframe
. "$D/config.sh"

ts() { date -u '+%Y-%m-%d %H:%M:%S'; }
echo "[$(ts)] ArtFrame-TestDisplay: starting"

OUT="$D/testdisplay.png"
if sh "$D/fetch.sh" "$BASE_URL/art/001.png" "$OUT" png; then
  echo "[$(ts)] fetched $BASE_URL/art/001.png"
else
  echo "[$(ts)] fetch failed, falling back to $D/charge.png"
  OUT="$D/charge.png"
fi

eips -f -g "$OUT"
echo "[$(ts)] painted $OUT - staying up for 15s"
sleep 15
eips -c
echo "[$(ts)] done, UI will repaint"
exit 0
