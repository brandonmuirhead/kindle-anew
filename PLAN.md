# Kindle Art Frame — Project Plan

Turn a Kindle Paperwhite 3 into a Wi-Fi-updated e-ink display of famous, recognizable
public-domain paintings. Refresh cadence: daily or every other day. The Kindle sleeps between updates.

This plan was written by Fable after inspecting the actual device over USB and researching the
current (Sept 2026) jailbreak and homebrew landscape. Sonnet implements; Fable reviews.
Everything stated as a fact below was verified unless marked *assumed* or *to confirm on device*.

---

## 0. What we know (verified facts)

### The device
| Item | Value | How verified |
|---|---|---|
| Model | **Kindle Paperwhite 3** (2015, 7th gen, "KPW3", i.MX6SL "Wario") | USB serial `G090G1…` prefix |
| Screen | **1072 × 1448 px**, 300 ppi, 16 gray levels (4-bit) | model spec |
| Firmware | **5.16.2.1.1** | `D:\system\version.txt` |
| Firmware status | **Final firmware for this model.** 5.16.3+ dropped PW3 support, so no OTA update can ever patch the jailbreak. Wi-Fi is safe to use. | MobileRead firmware wiki, Wikipedia |
| Jailbroken? | **Yes, since 2026-09-04** via WinterBreak v2.1.0 (`documents/JAILBROKEN.txt`, `kmc/`, `libkh/` present; `;kpm update` works) | USB listing + on-device test |
| Storage | 3.04 GB, 2.81 GB free, FAT32, mounts as `D:` (label "Kindle") | `Get-Volume` |
| Has been used | 76 items in `documents/`; device booted Aug 2026 (so the battery works) | USB listing |

### The PC (build/host machine, Windows 11)
Python 3.14.3 + Pillow 12.1.1, git 2.53, GitHub CLI 2.93 logged in as `brandonmuirhead`, GNU tar (extracts `.tar.gz`).
No ImageMagick, no 7-Zip (neither is needed).

### Jailbreak landscape (Sept 2026)
* **WinterBreak** (v2.1.0, June 2026) works on firmware **≤ 5.18.0**, so it covers 5.16.2.1.1. Procedure: airplane mode → reboot →
  copy release files to the Kindle root over USB → eject → open the Kindle Store (it prompts to leave airplane mode; say Yes) →
  the store loads a modified page ("Mesquito") → tap **WinterBreak** → ~30 s of text on screen → UI restarts. **Requires the
  Kindle to be registered to an Amazon account and on Wi-Fi.** It pre-installs the update block, the hotfix and the **KPM**
  package manager. Source: kindlemodding.org/jailbreaking/WinterBreak (page source read directly from the site's GitHub repo).
* **LanguageBreak** is the fallback if the Kindle cannot be registered or the store fails. Fully offline, but requires a factory reset,
  demo mode, and ~20 manual steps. Firmware ≤ 5.16.2.1.1 only (exactly ours).
* **Popcorn** is a hardware jailbreak (open the case, jumper wire). Not needed.
* **KUAL is obsolete.** kindlemodding.org now says: "software called KUAL was formerly used to launch applications … this is
  now obsolete and does not work." The modern mechanism is **scriptlets**: any `.sh` file placed in `documents/` shows up in
  the library as a book; tapping it runs the script (via `sh`, not bash). KPM installs packages from the search bar
  (`;kpm update`, `;kpm install <pkg>`). The KPM package list is small (9 packages) and has **no SSH package**, so we design
  for **zero-SSH operation**: everything is installed by copying files over USB and launched by tapping scriptlets.

### Prior art we build on
* **pascalw/kindle-dash** (cloned and read in full). A proven "fetch PNG → `eips` → RTC sleep" loop. Reused ideas:
  stop the Kindle UI framework, `lipc-set-prop com.lab126.powerd preventScreenSaver 1`, `powersave` governor, ping-wait for
  Wi-Fi, `eips -f -g image.png`, `echo mem > /sys/power/state`, battery via `gasgauge-info -c`. Its release tarball
  (`kindle-dash-v1.0.0-beta.4.tgz`, 4.4 MB) bundles **`xh`**, a static ARM (musl) HTTP client with modern TLS. kindle-dash needed it because the Kindle 4's
  `curl`/`wget` linked an ancient OpenSSL; on this PW3 the built-in curl works (see diagnostics), so `xh` is only a fallback. **We do not use kindle-dash's RTC path or its `next-wakeup`
  binary** (Kindle-4-specific / unnecessary).
* **Paperwhite-3-specific sleep/wake recipe** (from a PW3 dashboard write-up at blog.4dcu.be and kindle-dash PR #23 "Reconfigure to Kindle PW3"):
  ```sh
  echo "" > /sys/class/rtc/rtc1/wakealarm      # clear
  echo "+3600" > /sys/class/rtc/rtc1/wakealarm # relative seconds
  echo mem > /sys/power/state                  # suspend; returns when the alarm fires
  ```
  The PW3 has rtc0/rtc1/rtc2 (confirmed by diagnostics); **rtc1** is the one PW3 projects use to wake the SoC. *The actual wake is tested in Phase 4.*
* Gotchas reported by PW3 users: `/mnt/us` is often described as **noexec**. **Verified on this device (2026-09-04): on 5.16.2.1.1 `/mnt/us` is a
  FUSE (`fsp`) mount without `noexec`, and both `xh` and `fbink` execute directly from it.** Keep the `/var/tmp` copy only as a fallback. Shell scripts are
  still invoked as `sh script.sh`. If the Kindle UI is left running, powerd puts the device into its own deep sleep after 10 min and it stops waking, so we
  stop the GUI umbrella job (`initctl stop lab126_gui`, which is what KOReader does on 5.x; it takes framework, pillow and webreader down together).

### Device diagnostics (Phase 0.6, run on the jailbroken device 2026-09-04; full output in `kindle/artframe/diag-2026-09-04.txt`)
| Fact | Value |
|---|---|
| Scriptlet execution | runs as **root** (`uid=0`), via `sh -l "<file>" 2>&1 \| /mnt/us/libkh/bin/fbink -y 5 -r` (stdout is painted on screen), cwd `/`, framework keeps running, `PATH=/usr/local/bin:/bin:/usr/bin:/usr/sbin:/sbin:/app/bin:/app/tools:/app/tools/bin`, `HOME=/tmp/root` |
| Kernel | Linux 3.0.35-lab126, armv7l, busybox 1.34.1 |
| RTCs | `rtc0` and `rtc1` = `max77696-rtc` (two alarms on the PMIC), `rtc2` = `snvs_rtc`. All have an empty `wakealarm`. `/sys/power/state` offers `standby mem`. No `mxc_rtc.0` (kindle-dash's K4 path). **Use `rtc1`, read `wakealarm` back after writing to confirm; fall back to `rtc0`.** `rtcwake` (busybox) exists too |
| Framebuffer | 1072×1448, 8 bpp grayscale, `line_length` 1088, `rotate: 3`; `eips -f -g test.png` (1072×1448, mode L, 16 levels) painted correctly, all 16 bands visible |
| FBInk | **1.25.0 ships with the jailbreak at `/mnt/us/libkh/bin/fbink`** and runs in place. Useful for on-screen status text (`fbink -y -2 -m "…"`) and as an alternative image painter. Caveat: `fbink -e` segfaults on this build, so treat fbink image display as untested; **eips is the primary painter** |
| HTTP clients | built-in `curl 7.86.0 / OpenSSL 1.0.2q` fetched `raw.githubusercontent.com` over HTTPS with a **200 without `-k`** (CA bundle is fine). `xh 0.16.1` also works. busybox `wget` has `--no-check-certificate` |
| Upstart jobs | `lab126_gui` (umbrella), `framework`, `pillow`, `webreader`, `wifid`, `powerd`, `cmd` all running; `initctl` at `/sbin/initctl` |
| Power | powerd `Active`, `prevent_screen_saver:0`, battery 80%, governor `ondemand` (`powersave` available); `gasgauge-info -c` → `80%`, `-s` → `80` |
| Wi-Fi | `com.lab126.wifid cmState` = `CONNECTED`, signal 5/5, `com.lab126.cmd wirelessEnable` = `1`, IP 192.168.1.123, ping 1.1.1.1 OK |
| Tools present | `setsid`, `nohup`, `sed`, `awk`, `date`, `sleep`, `lipc-*`, `gasgauge-info`, `eips` |

### Art sources (all probed live, no API keys needed)
| Source | Query that works | Result |
|---|---|---|
| **Art Institute of Chicago** | `POST https://api.artic.edu/api/v1/artworks/search` with `bool.must: [{term:{is_boosted:true}}, {term:{is_public_domain:true}}, {term:{artwork_type_id:1}}]`, fields `id,title,artist_title,date_display,image_id` | **120** famous PD paintings (Grande Jatte, Van Gogh's Bedroom, Caillebotte's Paris Street, Monet…). Image: `https://www.artic.edu/iiif/2/{image_id}/full/1686,/0/default.jpg` → 200 OK, ~850 KB |
| **Met Museum** | `GET https://collectionapi.metmuseum.org/public/collection/v1/search?isHighlight=true&isPublicDomain=true&hasImages=true&medium=Paintings&q=painting` → objectIDs; then `/objects/{id}` → `primaryImage` | **420** highlight PD paintings (e.g. Wheat Field with Cypresses). `primaryImage` is the full-res original (can be 5–15 MB) |
| **Wikimedia Commons** (for the icons the two museums don't own: Mona Lisa, Starry Night, Girl with a Pearl Earring, Great Wave, Birth of Venus, The Scream, Night Watch…) | `GET https://commons.wikimedia.org/w/api.php?action=query&titles=File:kindle-anew&prop=imageinfo&iiprop=url|size|extmetadata&iiurlwidth=1920&format=json` → use the returned **`thumburl`**. Do NOT hand-build `upload.wikimedia.org/.../2000px-…` URLs; those return 400 on huge scans. Send a descriptive `User-Agent`. | Verified for Starry Night, Mona Lisa, Girl with a Pearl Earring → 200 OK, 1.4–2.4 MB |

---

## 1. Design decisions

1. **Jailbreak with WinterBreak** (user does this by hand, guided). LanguageBreak is the fallback. Firmware is final, so there is no update-blocking anxiety.
2. **No KUAL, no SSH, no MRPI.** Install = copy a folder to `D:\artframe\` and three `.sh` scriptlets to `D:\documents\`. Launch = tap a "book". Debug = read `D:\artframe\logs\` and `D:\artframe\diag.txt` over USB.
3. **Kindle runtime = a small POSIX-sh loop** modelled on kindle-dash but using the PW3 `rtc1` alarm and plain shell arithmetic for scheduling (no cron parser binary). Full-refresh `eips -f -g` every time (daily updates, so a flash is fine and it kills ghosting).
4. **HTTPS via the built-in `curl`** (verified on the device against GitHub, no `-k` needed). `xh` (static ARM binary from the kindle-dash release, already at `D:\artframe\xh`) is the fallback.
5. **Hosting = GitHub Pages, static pre-generated pool, no server cron.** The PC generates N ready-to-display PNGs (`docs/art/001.png … NNN.png` + `pool.txt` + `index.json`). The Kindle computes `index = ((days_since_epoch - start_day) / INTERVAL_DAYS) % N` and fetches that file, so image 001 shows on launch day. Nothing has to be running at 4 AM; nothing expires; refreshing the pool is "rerun the generator, `git push`". Alternative if the user prefers: `python -m http.server` on the PC over plain HTTP (then `xh` isn't even needed), but the PC must be awake when the Kindle wakes.
6. **Never crop a famous painting.** Fit the whole work inside the screen (`ImageOps.contain`), pad with paper-white, and print a small museum-style caption ("Title — Artist, Year") in the spare band. (Gemini's `ImageOps.fit` crop would decapitate the Mona Lisa.)
7. **Dither to the panel's real 16 levels** (0, 17, 34, …, 255) with Floyd–Steinberg so eips's 8-to-4-bit truncation is lossless. Autocontrast (1% cutoff), mild sharpen, optional gamma lift (e-ink midtones run dark; make it a config knob and judge on the device).
8. **Orientation is a config switch.** `portrait` (default) is the Kindle's natural orientation; `landscape` rotates the composed image 90° before saving so the file stays 1072×1448 in framebuffer coordinates. Roughly half of iconic paintings are landscape and half portrait; either way the off-axis ones are letterboxed with the caption. *Ask the user which way the frame will stand.*
9. **Schedule:** wake at `WAKE_HOUR_UTC` (default 09 = 4–5 AM US Eastern) every `INTERVAL_DAYS` (1 or 2). On fetch failure keep the current picture and retry in 1 h. Below `LOW_BATTERY_PCT` show a "please charge" image instead of fetching.
10. **Front light off** (user requirement): the Kindle is normally lit while on. The loop turns the light off (`flIntensity 0`) right after painting and before suspending; the e-ink panel keeps the picture with no power, so the only energy spent per day is the ~30 s wake to fetch and paint.

---

## 2. Architecture

```
 ┌──────────── PC (Windows) — run whenever you want new art ────────────┐
 │ generator/                                                           │
 │   sources: Commons curated list · AIC boosted+PD · Met highlights    │
 │      ↓ download (cached)                                             │
 │   pipeline: contain → gray → autocontrast → sharpen → caption band   │
 │             → 16-level Floyd–Steinberg → 8-bit "L" PNG 1072×1448     │
 │      ↓                                                               │
 │   docs/art/001.png … NNN.png, docs/pool.txt, docs/index.json        │
 └──────────────┬───────────────────────────────────────────────────────┘
                │ git push
                ▼
      GitHub Pages  https://<user>.github.io/kindle-anew/art/NNN.png  (HTTPS, always on)
                ▲
                │ xh GET (once a day, ~20 s of Wi-Fi)
 ┌──────────────┴──────────── Kindle PW3 (jailbroken) ──────────────────┐
 │ tap "ArtFrame-Start" scriptlet → setsid loop.sh                   │
 │ loop: stop UI framework · wait Wi-Fi · fetch count + today's PNG     │
 │       → eips -f -g → set rtc1 alarm → echo mem > /sys/power/state    │
 │       → (wakes at alarm) → repeat                                    │
 └──────────────────────────────────────────────────────────────────────┘
```

---

## 3. Repository layout (this folder, `C:\dev\kindle-anew`)

```
kindle-anew/
├─ PLAN.md                     ← this file
├─ README.md                   ← user-facing: setup, operation, troubleshooting
├─ generator/
│  ├─ requirements.txt         Pillow, requests
│  ├─ config.py                WIDTH=1072 HEIGHT=1448 ORIENTATION POOL_SIZE CAPTION GAMMA SEED OUTPUT_DIR sources on/off
│  ├─ sources/
│  │  ├─ commons.py            curated titles → imageinfo API → thumburl (1920 px)
│  │  ├─ commons_curated.txt   one work per line: File title | Title | Artist | Year
│  │  ├─ artic.py              boosted + public domain + painting → IIIF 1686 px
│  │  └─ met.py                highlight + public domain + paintings → primaryImage
│  ├─ pipeline.py              bytes → finished 1072×1448 8-bit grayscale PNG (+ metadata)
│  ├─ build_pool.py            gather → dedupe → shuffle(SEED) → write docs/art, pool.txt, index.json
│  ├─ preview.py               contact sheet / open one result for eyeballing
│  └─ cache/                   raw downloads (gitignored)
├─ docs/                       ← GitHub Pages root
│  ├─ art/001.png …
│  ├─ pool.txt                 two lines: count ("120") and start day (days since epoch when the pool was published)
│  └─ index.json               [{file, title, artist, year, source, source_url}]
└─ kindle/                     ← copy contents to the Kindle over USB
   ├─ artframe/                → D:\artframe\
   │  ├─ loop.sh               main loop
   │  ├─ config.sh             BASE_URL WAKE_HOUR_UTC INTERVAL_DAYS WIFI_TEST_IP LOW_BATTERY_PCT
   │  ├─ fetch.sh              xh-or-curl download helper
   │  ├─ xh                    static ARM binary from the kindle-dash release (document where to get it; do not commit if size is a concern)
   │  ├─ charge.png            "please charge" screen, 1072×1448 8-bit gray
   │  └─ logs/                 (created on device)
   └─ documents/               → D:\documents\
      ├─ ArtFrame-Diagnostics.sh
      ├─ ArtFrame-TestDisplay.sh
      └─ ArtFrame-Start.sh
```

---

## 4. Phases

### Phase 0 — Jailbreak + device diagnostics — **DONE 2026-09-04**
WinterBreak v2.1.0 succeeded (`documents/JAILBROKEN.txt`, `;kpm update` prints text). Fable wrote and ran the diagnostic scriptlet
(`kindle/documents/ArtFrame-Diagnostics.sh`); results are in the "Device diagnostics" table in §0 and in `kindle/artframe/diag-2026-09-04.txt`.
`D:\artframe\` already holds `xh` and `test.png`. The store crash dump `documents/KPPMainAppV2_*crash*` (3.5 MB) can be deleted.
Steps kept for reference:
0.1 Confirm the Kindle is **registered** to an Amazon account (Settings → My Account) and can join the home Wi-Fi.
0.2 Download **WinterBreak.tar.gz** (v2.1.0, 289 KB) from `https://github.com/KindleModding/WinterBreak/releases/latest`.
    *Fable will ask for permission before downloading, or the user downloads it.*
0.3 On the Kindle: Airplane mode ON → restart. Plug in USB. Extract the tarball on the PC (`tar -xzf`), copy **all** contents
    (including the hidden `.active_content_sandbox` folder) to `D:\`, replacing existing files. Delete any `*.bin` at the `D:\` root.
0.4 Eject. Tap the **Store** (cart) icon → "Yes" to leave airplane mode → wait for Mesquito → tap **WinterBreak** → wait ~30 s
    for text to scroll → UI restarts. If the store shows only its normal home page, follow the "LocalStorage Replacement"
    troubleshooting on the WinterBreak page (delete `.active_content_sandbox/store/resource/LocalStorage`, retry).
0.5 Verify: `;kpm update` in the search bar should print text at the top of the screen. (Optional: `;kpm install hello`.)
0.6 Copy `kindle/documents/ArtFrame-Diagnostics.sh` to `D:\documents\`, eject, tap it in the library. It writes
    `D:\artframe\diag.txt`. Plug back in; Fable reads it and confirms or adjusts the loop spec (rtc device, eips info,
    noexec mounts, curl TLS, whether scriptlets run as root, whether Wi-Fi comes back after resume).

**Acceptance:** `diag.txt` exists and shows `uid=0`, an `rtc1` with a writable `wakealarm`, `eips -i` reporting 1072×1448, and `xh --version` succeeding from `/var/tmp`.

### Phase 1 — Generator — **DONE 2026-09-04** (Sonnet built it; Fable reviewed, moved sharpening after the resize, made the gather stop once the pool is full, raised POOL_SIZE to 160; full build: 98/98 Commons titles resolved, 62 AIC works, 160 images, 52.5 MB, all validated)
1.1 Scaffold `generator/` per §3; `requirements.txt`; `config.py` with the constants in §6.
1.2 `sources/*.py`: each exposes `candidates() -> list[Artwork]` where `Artwork = {id, title, artist, year, source, source_url, image_url}`.
    Commons: read `commons_curated.txt`, batch titles 50 at a time into the imageinfo API, **skip and log titles the API reports missing**
    (the curated list will contain typos on the first pass; that is expected, iterate).
1.3 `pipeline.py`: `render(image_bytes, artwork, cfg) -> PIL.Image` implementing §6 exactly; unit-testable with a local JPEG.
1.4 `build_pool.py`: gather all sources → dedupe by (artist, title) → shuffle with fixed `SEED` → download with on-disk cache and retries →
    render → write `docs/art/NNN.png`, `docs/pool.txt`, `docs/index.json`. Idempotent; `--limit 10` for quick runs; `--only commons`.
1.5 `preview.py`: contact sheet of the pool plus an "as the Kindle will see it" viewer. Fable reviews a handful of outputs for crop, caption and tonality.

**Acceptance:** `python build_pool.py --limit 12` produces 12 PNGs that are mode `L`, exactly 1072×1448, contain only the 16 palette values,
every painting fully visible with a legible caption; `index.json` matches.

### Phase 2 — Hosting — **DONE 2026-09-04** (repo github.com/brandonmuirhead/kindle-anew, Pages from main:/docs, `https://brandonmuirhead.github.io/kindle-anew/pool.txt` and `art/001.png` verified 200; `.gitattributes` forces LF; `xh`, the diagnostics dump and `vendor/` are gitignored)
2.1 `git init`, `.gitignore` (`generator/cache/`, `__pycache__`), commit.
2.2 `gh repo create brandonmuirhead/kindle-anew --public --source . --push` (name is the user's call; suggest `kindle-anew`).
2.3 Enable Pages from `main` / `docs`:
    `gh api -X POST repos/brandonmuirhead/kindle-anew/pages -f "source[branch]=main" -f "source[path]=/docs"`.
2.4 Verify `https://brandonmuirhead.github.io/kindle-anew/pool.txt` and `/art/001.png` return 200 from the PC.

**Acceptance:** both URLs load; `BASE_URL` is recorded in `kindle/artframe/config.sh`.

### Phase 3 — Kindle client — **DONE 2026-09-04** (Sonnet wrote it; Fable reviewed, added `curl --fail`; staged on the device with `INTERVAL_MINUTES_TEST=3` for the first run)
3.1 `loop.sh`, `config.sh`, `fetch.sh`, the three scriptlets, `charge.png`.
3.2 Obtain `xh`: download `kindle-dash-v1.0.0-beta.4.tgz` from `https://github.com/pascalw/kindle-dash/releases` (4.4 MB), extract, take `xh` only.
3.3 Static checks on the PC: shellcheck-style review by Fable; scripts must be POSIX `sh` (busybox ash), LF line endings, no bashisms
    (`[[ ]]`, arrays, `local -n`, `$'..'`, `source`). Test the date/index arithmetic under Git Bash's `sh` with `date` stubbed.

### Phase 4 — First run — **test cycles PASSED 2026-09-05** (five 3-minute cycles: `lab126_gui` stopped, front light 0 via `max77696-bl`, Wi-Fi up within 1 s of every resume, curl fetched pool.txt and the image, eips painted, `rtc1` wakealarm read back as since_epoch+180 and the device resumed after 180-181 s each time, battery 100→99%). Log: `kindle/artframe/firstrun-2026-09-05.log`. Remaining: run on the daily schedule and observe two real 09:00 UTC wakes.
4.1 Copy `kindle/artframe` → `D:\artframe`, scriptlets → `D:\documents`. Eject.
4.2 Tap **ArtFrame-TestDisplay**: shows `docs/art/001.png` fetched over Wi-Fi (or a bundled test image) via `eips -f -g`, returns to the
    library after 15 s without sleeping. Confirms Wi-Fi + TLS + image format on the real panel.
4.3 Tap **ArtFrame-Start**: UI disappears, picture shows, device suspends ~20 s later. Confirm it wakes at the next alarm
    (for the first test set `INTERVAL_MINUTES_TEST=3` in config so we don't wait a day), then set the real schedule.
4.4 Battery check over 3–4 days via the log (each wake logs `gasgauge-info -c`).
4.5 To stop or get logs: hold the power button ~40 s until the device reboots into the normal UI, then connect USB.
    (Verified 2026-09-05: USB drive mode still works while the UI is stopped, but connecting mid-cycle raced the loop and left `current.png` at 0 bytes once, so reboot before connecting.)

**Acceptance:** two consecutive scheduled updates observed in the log; battery drop per day noted in README.

### Phase 5 — Nice-to-haves (after everything above works)
* **Auto-start on boot** (survives battery death): scriptlet that installs an upstart job in `/etc/upstart/artframe.conf` (`mntroot rw` first).
* **Local pool mirror**: copy `docs/art` to `D:\artframe\pool` once over USB; the loop displays from the local pool and only uses Wi-Fi to sync `pool.txt`
  and any new files, so it works even when Wi-Fi is down.
* SSH over Wi-Fi (NiLuJe's USBNetwork package via MRPI) for live debugging, only if we get stuck.
* FBInk (`https://github.com/NiLuJe/FBInk` v1.25.0 ships a static Kindle binary) if `eips -g` turns out to be finicky.

---

## 5. Kindle-side specification (what Sonnet must implement exactly)

All scripts: `#!/bin/sh`, POSIX/busybox-ash only, LF endings, invoked as `sh /path/script.sh` (never rely on the +x bit).
Log every step with timestamps to `/mnt/us/artframe/logs/artframe.log` (append; rotate at 200 KB).

### `config.sh`
```sh
BASE_URL="https://brandonmuirhead.github.io/kindle-anew"   # no trailing slash
WAKE_HOUR_UTC=9          # 0-23; 09 UTC = 04:00 EST / 05:00 EDT
INTERVAL_DAYS=1          # 1 = daily, 2 = every other day
WIFI_TEST_IP=1.1.1.1
WIFI_TIMEOUT=90          # seconds to wait for network after wake
RETRY_SECS=3600          # sleep before retrying after a failed fetch
LOW_BATTERY_PCT=10
INTERVAL_MINUTES_TEST=0  # >0 overrides the daily schedule (for testing only)
```

### `ArtFrame-Diagnostics.sh` (scriptlet)
Writes `/mnt/us/artframe/diag.txt` with: `id`, `uname -a`, `cat /etc/prettyversion.txt`, `pwd`, `echo "$0 $*"`, `env`,
`ls -la /sys/class/rtc/`, and for each `/sys/class/rtc/rtc*`: its `name` and current `wakealarm`;
`cat /sys/power/state`, `eips -i`, `mount`, `df -h`, `which xh curl wget rtcwake setsid nohup gasgauge-info lipc-set-prop lipc-get-prop initctl`,
`curl -V`, `initctl list | grep -iE 'framework|powerd|wifid|cmd|pillow'`, `lipc-get-prop com.lab126.powerd status`, `gasgauge-info -c`,
`lipc-get-prop com.lab126.wifid cmState`, `date -u`, `ping -c 2 1.1.1.1`. Then it copies `xh` to `/var/tmp`, `chmod +x`, and runs
`/var/tmp/xh --version` and `/var/tmp/xh -d -o /var/tmp/t.txt get "$BASE_URL/pool.txt"` (if BASE_URL is set), logging results.
Must never suspend or stop the framework. Ends with `eips 0 0 "diag done"` so the user sees it finished.

### `ArtFrame-TestDisplay.sh` (scriptlet)
Fetch `$BASE_URL/art/001.png` (fallback: `/mnt/us/artframe/charge.png`) → `eips -f -g` → `sleep 15` → `eips -c` → exit.
Framework stays running (the UI will repaint itself).

### `ArtFrame-Start.sh` (scriptlet)
```sh
mkdir -p /mnt/us/artframe/logs
setsid sh /mnt/us/artframe/loop.sh >> /mnt/us/artframe/logs/artframe.log 2>&1 < /dev/null &
```
Nothing else. Detaching first is essential because `loop.sh` will stop the framework that launched this scriptlet. The launcher pipes the scriptlet's stdout to fbink, so an `echo "Art Frame starting - the screen will change in about 15 s"` placed before the setsid line is shown on the panel (loop.sh output itself goes to the log).

### `loop.sh`
```
init:
  . config.sh
  sleep 5
  lipc-set-prop com.lab126.powerd preventScreenSaver 1
  frontlight_off
  initctl stop lab126_gui    (umbrella job: stops framework, pillow, webreader; the UI comes back with `initctl start lab126_gui` or a reboot)
  sleep 3
  echo powersave > /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor   (ignore errors)
loop forever:
  batt=$(gasgauge-info -c | tr -dc 0-9)
  if batt < LOW_BATTERY_PCT: eips -f -g charge.png; sleep_secs=86400; goto sleep
  wait_for_wifi (ping WIFI_TEST_IP once/sec up to WIFI_TIMEOUT; after 30 s of failure also try
                 `lipc-set-prop com.lab126.cmd wirelessEnable 1` and `lipc-set-prop com.lab126.wifid enable 1`)
  if no wifi: sleep_secs=RETRY_SECS; goto sleep
  fetch "$BASE_URL/pool.txt" -> count=$(sed -n 1p), start=$(sed -n 2p)   # validate both are integers > 0
  now=$(date -u +%s); day=$(( now / 86400 )); [ "$day" -lt "$start" ] && day=$start
  idx=$(( ((day - start) / INTERVAL_DAYS) % count + 1 ))   # pool day 0 = image 001, so the front-loaded icons show first
  file=$(printf '%03d.png' "$idx")
  fetch "$BASE_URL/art/$file" -> /mnt/us/artframe/new.png  (tmp file; verify size > 10 KB and PNG magic bytes)
  on failure: sleep_secs=RETRY_SECS; goto sleep (keep old picture)
  mv new.png current.png; eips -f -g /mnt/us/artframe/current.png; sleep 3
  frontlight_off     (user requirement: the e-ink image persists with the light off and the SoC asleep)
  sleep_secs = seconds until next WAKE_HOUR_UTC boundary (+ (INTERVAL_DAYS-1)*86400); if INTERVAL_MINUTES_TEST>0 use that*60
sleep:
  clamp sleep_secs to [60, 3*86400]
  log "sleeping ${sleep_secs}s, battery ${batt}%"
  RTC=/sys/class/rtc/rtc1
  echo ""              > $RTC/wakealarm
  echo "+$sleep_secs"  > $RTC/wakealarm
  log "wakealarm=$(cat $RTC/wakealarm) since_epoch=$(cat $RTC/since_epoch)"   # expect wakealarm ≈ since_epoch + sleep_secs
  # if wakealarm reads back empty, retry once with RTC=/sys/class/rtc/rtc0 before suspending
  echo mem > /sys/power/state
  # if we return within 30 s, the suspend was refused (busy): sleep 60 and try again; count consecutive failures,
  # after 10 fall back to a plain `sleep $sleep_secs`
```
`frontlight_off`: `lipc-set-prop com.lab126.powerd flIntensity 0` (PW3 front light range 0-24), then `for b in /sys/class/backlight/*/brightness; do echo 0 > "$b" 2>/dev/null; done`, and log `ls -la /sys/class/backlight/` plus `lipc-get-prop com.lab126.powerd flIntensity` once per run so we learn the exact node. Call it in init and again right after every paint; never turn the light back on.

`fetch.sh`: primary `curl -sS -L --max-time 60 -o "$out" "$url"` (built-in curl verified against GitHub over HTTPS, no `-k` needed);
fallback `/mnt/us/artframe/xh -d -q -o "$out" get "$url"` (if it fails to exec, copy to `/var/tmp` and retry); last resort
`wget --no-check-certificate -q -O "$out" "$url"`. Exit non-zero on any failure, on an empty file, or on a non-PNG when a PNG was expected.

Next-wake arithmetic (pure sh):
```sh
now=$(date -u +%s); day_start=$(( now - now % 86400 ))
target=$(( day_start + WAKE_HOUR_UTC * 3600 ))
[ "$target" -le "$(( now + 120 ))" ] && target=$(( target + 86400 ))
sleep_secs=$(( target - now + (INTERVAL_DAYS - 1) * 86400 ))
```

---

## 6. Generator specification

* Canvas 1072×1448 (portrait). For `ORIENTATION=landscape`, compose on 1448×1072 then `transpose(Image.Transpose.ROTATE_90)` (verify direction on device; make it a config value `ROTATE=90|270`).
* Margins 24 px; caption band at the bottom: 2 lines max, serif font (Pillow ≥ 10.1 `ImageFont.load_default(size=…)` is scalable; or bundle an OFL font
  such as EB Garamond or Libre Baskerville under `generator/fonts/`), line 1 = *Title* (36 px), line 2 = Artist, Year (28 px), centered, ellipsize beyond 60 chars.
* Painting area = canvas minus margins minus caption band; `ImageOps.contain(img, area, Image.Resampling.LANCZOS)`; center; 1-px 40%-gray hairline border around the painting.
* Tone: `ImageOps.autocontrast(cutoff=1)`, optional `GAMMA` (default 1.0; expose 1.1–1.3 as the knob to try on device), `ImageEnhance.Sharpness(1.25)`.
* Quantize: palette image with 16 entries `[i*17 for i in range(16)]`, `img.convert("RGB").quantize(palette=pal, dither=Image.Dither.FLOYDSTEINBERG).convert("L")`; save PNG `optimize=True`. Assert mode `L`, exact size, unique values ⊆ palette.
* Downloads: `requests` with `User-Agent: kindle-art-frame/0.1 (+https://github.com/brandonmuirhead/kindle-anew)`, 3 retries, 60 s timeout, cache by sha1(url) in `generator/cache/`. Met originals can exceed 10 MB; skip images whose Content-Length is over 40 MB.
* Selection and order (user request): default `POOL_SIZE=160`. The pool is **ordered, not globally shuffled**: curated Wikimedia Commons icons first, in the order of `commons_curated.txt`, then AIC, then Met; dedupe by normalized (artist, title); shuffle only *within* the AIC and Met groups with `SEED=20260904`. `pool.txt` line 2 records the publish day so the Kindle shows image 001 on launch day and walks the list from there.
* Curated Commons starter (verified titles): `Van_Gogh_-_Starry_Night_-_Google_Art_Project.jpg`, `Mona_Lisa,_by_Leonardo_da_Vinci,_from_C2RMF_retouched.jpg`, `1665_Girl_with_a_Pearl_Earring.jpg`. Sonnet extends this to ~60–100 iconic works (Great Wave, Birth of Venus, The Scream (1893), Night Watch, Las Meninas, The Kiss, Liberty Leading the People, Impression Sunrise, Whistler's Mother, Garden of Earthly Delights, Arnolfini Portrait, Wanderer above the Sea of Fog, The Swing, Ophelia, Bal du moulin de la Galette, Café Terrace at Night, Sunflowers…). Skip works that are not public domain (Nighthawks, Christina's World, most post-1930 works). **Only public-domain works:** rely on the API's `LicenseShortName` containing "Public domain" and skip anything else.

---

## 7. Risks and fallbacks
| Risk | Mitigation |
|---|---|
| WinterBreak store step fails (unregistered device, store error) | Register the device (Amazon account) and retry; else LanguageBreak (offline) |
| `rtc1` alarm doesn't wake the PW3 | Diagnostics show which rtc has `wakealarm`; try rtc0/rtc2; last resort `rtcwake` if present |
| `echo mem` refused (wakelocks held) | Loop detects fast return and retries; check `lipc-get-prop com.lab126.powerd status`; ensure the framework is really stopped |
| Wi-Fi doesn't re-associate after resume | wifid nudge via lipc; longer timeout; RETRY_SECS keeps the old picture |
| `xh` binary won't run (ABI) | `curl -k` fallback; or host over plain HTTP from the PC and use busybox `wget` |
| `eips -g` rejects the PNG | Ensure 8-bit `L`, no alpha, non-interlaced, exact size; else FBInk |
| Device can't charge while suspended (reported on other models) | Charge with the loop stopped (reboot first); log battery so we know the cadence |
| Public repo shows the art | All works are public domain; if undesired, use a private repo + plain-HTTP PC server instead |

---

## 8. Open questions for the user — **all answered 2026-09-04**: portrait; registered and on home Wi-Fi; Fable downloaded both files; public repo `kindle-anew` under brandonmuirhead; daily at 09:00 UTC. Kept for the record:
1. Frame orientation: portrait or landscape? [portrait]
2. Is the Kindle registered to your Amazon account, and are you fine connecting it to your home Wi-Fi? (Firmware is final, so no update risk.) [yes]
3. OK to download WinterBreak.tar.gz (289 KB) and kindle-dash-v1.0.0-beta.4.tgz (4.4 MB) from their GitHub release pages, or will you? [Fable downloads with your OK]
4. Hosting on a public GitHub Pages repo named `kindle-anew` under brandonmuirhead? [yes]
5. Refresh time and cadence: daily at ~4–5 AM Eastern? [WAKE_HOUR_UTC=9, INTERVAL_DAYS=1]

---

## 9. Handoff brief for the coding agent (Sonnet)
Read §0, §1, §3, §5, §6 fully. Build in this order, committing after each step:
1. Phase 1 generator (§3, §6). Start with `commons.py` + `pipeline.py` + `build_pool.py --limit 5 --only commons`, show 5 outputs for review.
2. Phase 3 Kindle scripts (§5). The diagnostics scriptlet already exists in `kindle/documents/` and must keep working. POSIX sh only; you cannot run them here, so keep them small, defensive and heavily logged.
3. README.md: install steps (copy to `D:\`), how to start and stop, how to read logs, how to refresh the pool.
Do not: use bash-only syntax in `kindle/`; crop artwork; hardcode the GitHub URL outside `config.sh`/`config.py`; commit `generator/cache/`.
Ask Fable (via the user) before: changing the sleep/RTC recipe, adding binaries other than `xh`, or touching anything under `/etc` on the device.
