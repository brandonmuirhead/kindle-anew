# Wi-Fi off during sleep (PW4 battery drain)

## Brandon's words

> unfortunately the second kindle we set up that I've been using in work usually only lasts a few days or maybe a week and then the battery runs down. Is it possible to replace a battery cheaply? Do you know what kind that one is?

> I just connected the kindle - can you check that out directly

(After Claude reported that the log shows one ~2-minute wake per day but a 10-25%
per-day drop while asleep, and proposed turning Wi-Fi off before each sleep plus
logging battery voltage so the next week tells software from a worn battery:)

> yes, make the change and load it on the kindle

## Plan

Evidence (device log, Sep 24 - Oct 2): the loop wakes once a day for 1-2 minutes
and otherwise suspends for the full ~86,300 s, yet the battery falls 99 -> 90 ->
77 -> 64 -> 51 -> 25 -> 20 -> 9 -> 0. The drain is during suspend. `loop.sh`
bypasses the Kindle framework (which normally turns Wi-Fi off before sleeping)
and never turns Wi-Fi off itself.

Change, in `kindle/artframe/loop.sh` only:

1. `enter_sleep` turns Wi-Fi off (`lipc-set-prop com.lab126.cmd wirelessEnable 0`)
   before suspending, on every path (daily, retry, low battery).
2. `wait_for_wifi` turns Wi-Fi back on at its start, instead of only as a nudge
   after 30 s.
3. Each iteration logs one best-effort battery-detail line (voltage, current and
   capacity from whatever `/sys/class/power_supply` nodes and `gasgauge-info`
   flags exist) so a worn battery can be recognised.

Must never happen: the frame ends up with Wi-Fi off and stuck - every fetch path
goes through `wait_for_wifi`, which re-enables first, and the existing 30 s
nudge stays as a second attempt.

Left out: any other power tuning; the battery replacement itself.

Proof: shell syntax check, the existing sourced-for-test arithmetic still loads,
then a real week on the device judged from `artframe.log` (battery % per day).
