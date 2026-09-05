# Kindle Art Frame

Turn a jailbroken Kindle Paperwhite 3 into a Wi-Fi-updated e-ink display of
famous, public-domain paintings. The Kindle wakes once a day (or every other
day), fetches the next picture from a static GitHub Pages site, paints it in
full-screen e-ink refresh, turns its front light off, and goes back to deep
sleep on an RTC alarm — so the only power it spends is a ~20-30 s burst of
Wi-Fi and CPU once per cycle. See `PLAN.md` for the full design rationale,
verified device facts and phase-by-phase history; this file is the
day-to-day operator's manual.

## Architecture

A small Python **generator** (`generator/`) runs on your PC whenever you want
new art: it pulls curated public-domain paintings from Wikimedia Commons,
the Art Institute of Chicago and the Met, fits each one onto a
1072x1448 8-bit grayscale canvas without ever cropping the work, adds a
museum-style caption, dithers it to the panel's real 16 gray levels, and
writes the results to `docs/art/001.png … NNN.png` plus `docs/pool.txt` and
`docs/index.json`. Committing and pushing `docs/` publishes it as a static
site on **GitHub Pages** — nothing runs on a server, nothing expires, and the
Kindle doesn't need the PC to be awake. On the Kindle side, a POSIX-`sh`
loop (`kindle/artframe/loop.sh`, launched by tapping the **ArtFrame-Start**
scriptlet) stops the Kindle's own UI, computes which pool image today's date
maps to (`(days_since_pool_start / INTERVAL_DAYS) % count`), downloads it
over HTTPS, paints it with `eips`, sets a wake alarm on the PMIC's RTC, and
suspends with `echo mem > /sys/power/state` until the alarm fires and the
loop repeats.

```
PC: generator/  --(git push)-->  GitHub Pages (docs/)  --(HTTPS GET, ~once/day)-->  Kindle: artframe/loop.sh
```

## PC setup

1. Install Python 3.10+ (this project was built and tested against
   3.14 + Pillow 12) and the generator's dependencies:

   ```sh
   pip install -r generator/requirements.txt
   ```

2. Build (or rebuild) the pool. This downloads source images (cached under
   `generator/cache/`, gitignored), renders each one to the Kindle's exact
   format, and (re)writes `docs/art/`, `docs/pool.txt` and `docs/index.json`:

   ```sh
   python generator/build_pool.py                 # full pool (POOL_SIZE in generator/config.py)
   python generator/build_pool.py --limit 12       # quick run, first 12 works only
   python generator/build_pool.py --only commons    # one source only: commons | artic | met
   ```

   Re-running `build_pool.py` is idempotent — it's safe to do any time you
   want to refresh the art, change `ORIENTATION`/`GAMMA` in
   `generator/config.py`, or extend `generator/sources/commons_curated.txt`.

3. Eyeball the results before publishing:

   ```sh
   python generator/preview.py
   ```

   This produces a contact sheet of the whole pool plus an "as the Kindle
   will see it" single-image viewer, so you can check cropping, captions and
   tonality without plugging in the device.

4. Two one-off maintenance images already live in `kindle/artframe/` and are
   regenerated the same way if you ever change their look:

   ```sh
   python generator/make_test_image.py     # 16-level gray ramp, used to sanity check the panel
   python generator/make_charge_image.py   # "please charge" screen shown at low battery
   ```

## Publishing

The Kindle only ever talks to `BASE_URL` (`kindle/artframe/config.sh`,
currently `https://brandonmuirhead.github.io/kindle-anew`), which is served
from this repo's `docs/` folder via GitHub Pages. Publishing a new pool is
just:

```sh
git add docs/
git commit -m "Refresh art pool"
git push
```

Pages redeploys automatically after the push (usually within a minute or
two). You can confirm it's live from any machine:

```sh
curl -s https://brandonmuirhead.github.io/kindle-anew/pool.txt
curl -sI https://brandonmuirhead.github.io/kindle-anew/art/001.png
```

If Pages isn't enabled yet on a fresh clone of this repo, turn it on once
under **Settings → Pages → Build and deployment → Source: Deploy from a
branch → `main` / `/docs`** (or `gh api -X POST repos/<owner>/<repo>/pages
-f "source[branch]=main" -f "source[path]=/docs"`).

## Installing on the Kindle

The Kindle must already be jailbroken (see **Jailbreak** below) before any
of this works. Over USB, with the Kindle mounted as drive `D:`:

1. Copy the entire `kindle/artframe/` folder to `D:\artframe\` (this
   includes `loop.sh`, `config.sh`, `fetch.sh`, the optional `xh` binary,
   `charge.png` and `test.png`). `xh` is not committed to git: it is only a
   fallback downloader (the built-in curl is primary), so if you want it, take
   the `xh` file out of `kindle-dash-v1.0.0-beta.4.tgz` from
   https://github.com/pascalw/kindle-dash/releases and drop it in `kindle/artframe/`.
2. Copy the three files in `kindle/documents/` to `D:\documents\`:
   `ArtFrame-Diagnostics.sh`, `ArtFrame-TestDisplay.sh`, `ArtFrame-Start.sh`.
3. Eject the drive safely. Each `.sh` file you copied into `documents/`
   shows up as a "book" in the Kindle's library within a few seconds; tap
   one to run it (Kindle scriptlets — no KUAL, no SSH required).

## First run

Do these in order the first time; after that, just leave it running.

1. **Tap `ArtFrame-TestDisplay`.** It fetches `art/001.png` from
   `BASE_URL` (falling back to the bundled `charge.png` if that fails),
   paints it with `eips`, waits 15 s, then clears and returns to the
   library — the UI framework is never stopped, so this is safe to run as
   many times as you like. This step alone confirms Wi-Fi, HTTPS and the
   image format all work on the real panel before you let the device go to
   sleep unattended.
2. **Set a short test interval.** Edit `D:\artframe\config.sh` and set
   `INTERVAL_MINUTES_TEST=3` (anything > 0 overrides the daily schedule).
   Copy the file back to the device.
3. **Tap `ArtFrame-Start`.** You'll briefly see "Art Frame starting - the
   screen will change in about 15 s" on screen, then the UI disappears, the
   first picture is painted, and the device suspends. Confirm on your own
   clock that it wakes up, fetches and repaints roughly every 3 minutes for
   a couple of cycles (check `D:\artframe\logs\artframe.log` over USB to
   see timestamps and battery readings for each iteration).
4. **Switch to the real schedule.** Once you've confirmed a couple of
   successful test cycles, stop the loop (see below), set
   `INTERVAL_MINUTES_TEST=0` in `config.sh`, adjust `WAKE_HOUR_UTC` /
   `INTERVAL_DAYS` if you want something other than the default (daily at
   09:00 UTC), copy `config.sh` back over, and tap `ArtFrame-Start` again.

## Stopping the loop, and where the logs are

`loop.sh` deliberately never gives you a "stop" scriptlet, because it stops
the UI framework it would need to run one — the only reliable way back in is
the hardware itself:

* **Hold the power button for about 40 seconds** until the device reboots.
  The normal Kindle UI comes back on its own; you don't need to do anything
  else. (While the loop is running and the framework is stopped, the
  Kindle will not appear as a USB drive — reboot first, *then* plug in USB.)
* **Logs**: `D:\artframe\logs\artframe.log` — every step of every iteration
  (battery %, Wi-Fi wait, which file was fetched, paint, the RTC alarm
  read-back, suspend/resume timing) is appended with a UTC timestamp. The
  file is rotated (renamed to `artframe.log.old`, one backup kept) once it
  passes 200 KB, so it never grows unbounded.
* **Diagnostics**: tap `ArtFrame-Diagnostics` any time (it never stops the
  framework or suspends) to refresh `D:\artframe\diag.txt` with a full
  snapshot of device state — useful to attach when asking for help.

## Config reference (`kindle/artframe/config.sh`)

| Variable | Default | Meaning |
|---|---|---|
| `BASE_URL` | `https://brandonmuirhead.github.io/kindle-anew` | Where `pool.txt` and `art/NNN.png` are fetched from. No trailing slash. |
| `WAKE_HOUR_UTC` | `9` | Hour (0-23, UTC) the daily refresh targets. 9 = 04:00 EST / 05:00 EDT. |
| `INTERVAL_DAYS` | `1` | `1` = new picture every day, `2` = every other day, etc. |
| `WIFI_TEST_IP` | `1.1.1.1` | Address pinged to detect that Wi-Fi has come up after wake. |
| `WIFI_TIMEOUT` | `90` | Seconds to wait for Wi-Fi before giving up for this cycle. |
| `RETRY_SECS` | `3600` | How long to sleep before retrying after a failed Wi-Fi wait or fetch (the current picture stays on screen). |
| `LOW_BATTERY_PCT` | `10` | Below this battery percentage, `charge.png` is shown instead of fetching, and the device sleeps 24 h before checking again. |
| `INTERVAL_MINUTES_TEST` | `0` | Set > 0 to override the whole daily schedule with "wake every N minutes", for testing only. Set back to `0` for normal use. |

## Troubleshooting

| Symptom | Likely cause | What to do |
|---|---|---|
| Tapping the scriptlet does nothing, or WinterBreak's store step fails | Kindle not registered to Amazon, or the Kindle Store didn't load Mesquito | Register the Kindle (Settings → My Account) and retry; if the store still shows only its normal page, delete `.active_content_sandbox/store/resource/LocalStorage` and retry; failing that, use LanguageBreak (fully offline) instead |
| Device never wakes up after the first sleep | `rtc1`'s alarm isn't actually waking the SoC | Check `artframe.log` for the `wakealarm=… since_epoch=…` line right before each sleep — it should read back non-empty and roughly `since_epoch + sleep_secs`; if it's empty, `loop.sh` already falls back to `rtc0` automatically. As a last resort, hold power ~40 s to reboot and try `rtcwake` manually via `ArtFrame-Diagnostics.sh`'s output for clues |
| `echo mem > /sys/power/state` returns almost immediately, screen never changes again | A wakelock is held (suspend refused) | `loop.sh` detects a return within 30 s as a refusal, retries every 60 s, and after 10 failures falls back to a plain `sleep` (so the device stays awake but still keeps schedule) — check `lipc-get-prop com.lab126.powerd status` in the diagnostics output and confirm `initctl stop lab126_gui` actually ran |
| Wi-Fi never reconnects after waking | wifid didn't re-associate on resume | `loop.sh` already nudges `com.lab126.cmd wirelessEnable` and `com.lab126.wifid enable` after 30 s of failed pings; if it still times out after `WIFI_TIMEOUT`, it sleeps `RETRY_SECS` and tries again on the next cycle, keeping the current picture in the meantime |
| Fetch fails / falls back to `wget` | The `xh` binary won't execute (ABI mismatch) or `/mnt/us` behaves as `noexec` on your build | `fetch.sh` already tries `curl` (built-in, verified against GitHub over HTTPS) first, then `xh` from `/mnt/us/artframe` and again from `/var/tmp`, then `wget --no-check-certificate` as a last resort; check `artframe.log` to see which one actually succeeded |
| `eips -f -g` shows a garbled or blank image | The PNG isn't 8-bit grayscale, has alpha, or isn't exactly 1072x1448 | The generator always writes mode `L`, exact size, no alpha; `fetch.sh` rejects anything that doesn't start with the PNG signature, and `loop.sh` additionally rejects any downloaded art file under 10 KB. Re-run `build_pool.py` if a specific file looks wrong |
| Battery drains faster than expected, or won't charge while running | Some Kindles can't charge while suspended | Stop the loop (hold power ~40 s) before charging on a cable, then restart `ArtFrame-Start` afterwards; `artframe.log`'s battery-percent-per-iteration line lets you track the actual drain rate over a few days |
| You'd rather not host the art publicly | GitHub Pages repos are public | Make the GitHub repo private and instead run `python -m http.server` on your PC, pointing `BASE_URL` at `http://<pc-ip>:8000`; the PC must then be on and reachable whenever the Kindle wakes |

## The jailbreak

This device was jailbroken with **[WinterBreak](https://kindlemodding.org/jailbreaking/WinterBreak)**
(v2.1.0), which works on firmware ≤ 5.18.0 and therefore covers this
Paperwhite 3's 5.16.2.1.1 (the final firmware ever shipped for this model,
so there's no OTA update that could ever undo it). The procedure: airplane
mode → reboot → copy the release's files onto the Kindle over USB → eject →
open the Kindle Store, which loads a modified page ("Mesquito") → tap
**WinterBreak** → wait for it to finish → the UI restarts jailbroken. It
pre-installs the **KPM** package manager (`;kpm update` / `;kpm install
<pkg>` from the search bar). If the Store step fails (device not
registered, or it won't load Mesquito), **LanguageBreak** is the offline
fallback for the same firmware, at the cost of a factory reset and more
manual steps.

**KUAL is not used and is not needed** — as of the 2026 jailbreak landscape,
KUAL is obsolete on this firmware. Everything here runs as a **scriptlet**
instead: any `.sh` file placed in `documents/` appears as a book in the
library, and tapping it runs the script directly (`sh script.sh`, as root).
That's the entire mechanism behind `ArtFrame-Start`, `ArtFrame-TestDisplay`
and `ArtFrame-Diagnostics` — no SSH, no MRPI, no KUAL menu.
