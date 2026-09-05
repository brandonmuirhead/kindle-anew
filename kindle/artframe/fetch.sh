#!/bin/sh
# Art Frame - fetch.sh: download helper with curl -> xh -> wget fallback.
#
# Usage: sh fetch.sh <url> <out> [png]
#   <url>  source URL (https)
#   <out>  destination file (written atomically-ish: removed first, only
#          left in place on success)
#   [png]  if the literal word "png" is passed, the downloaded file must
#          start with the PNG signature or the fetch is treated as failed.
#
# Exit 0 on success (out exists, is non-empty, and passes the PNG check
# when requested). Exit non-zero on any failure. Every step is logged to
# stdout/stderr with a timestamp; the caller (loop.sh) redirects that to
# the log file, so this script never opens the log itself.
#
# Tool chain per PLAN.md section 5 ("fetch.sh"):
#   1. built-in curl (verified against GitHub over HTTPS, no -k needed)
#   2. /mnt/us/artframe/xh (copied to /var/tmp and retried if exec fails,
#      matching the noexec workaround already proven in
#      ArtFrame-Diagnostics.sh)
#   3. busybox wget --no-check-certificate (last resort)

ART_DIR=/mnt/us/artframe

url="$1"
out="$2"
kind="$3"

ts() { date -u '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] fetch.sh: $*"; }

if [ -z "$url" ] || [ -z "$out" ]; then
  log "usage: fetch.sh <url> <out> [png]"
  exit 2
fi

# Checks $out for non-empty, and (if kind=png) a PNG signature. We avoid
# tools that were never confirmed on the device (e.g. od/hexdump): a PNG
# file's first 8 bytes are 0x89 'P' 'N' 'G' 0x0D 0x0A 0x1A 0x0A, and the
# literal ASCII "PNG" only appears there for a genuine PNG, so scanning
# the first 8 bytes for that substring with grep (confirmed present, and
# busybox grep does not refuse to scan binary data) is a reliable check
# using only head/grep, both already exercised by
# ArtFrame-Diagnostics.sh.
check_result() {
  f="$1"
  if [ ! -s "$f" ]; then
    log "empty or missing file: $f"
    return 1
  fi
  if [ "$kind" = "png" ]; then
    if ! head -c 8 "$f" 2>/dev/null | grep -q PNG; then
      log "not a PNG (no PNG signature in first 8 bytes): $f"
      return 1
    fi
  fi
  return 0
}

rm -f "$out"

log "trying curl: $url"
if curl -fsS -L --max-time 60 -o "$out" "$url" 2>&1; then
  if check_result "$out"; then
    log "curl OK -> $out"
    exit 0
  fi
else
  log "curl exit non-zero"
fi
rm -f "$out"

log "trying xh: $url"
if "$ART_DIR/xh" -d -q -o "$out" get "$url" 2>&1; then
  if check_result "$out"; then
    log "xh OK -> $out"
    exit 0
  fi
else
  log "xh failed to run from $ART_DIR, copying to /var/tmp and retrying"
  rm -f "$out"
  cp "$ART_DIR/xh" /var/tmp/xh 2>/dev/null
  chmod +x /var/tmp/xh 2>/dev/null
  if /var/tmp/xh -d -q -o "$out" get "$url" 2>&1; then
    if check_result "$out"; then
      log "xh (/var/tmp) OK -> $out"
      exit 0
    fi
  else
    log "xh (/var/tmp) exit non-zero"
  fi
fi
rm -f "$out"

log "trying wget: $url"
if wget --no-check-certificate -q -O "$out" "$url" 2>&1; then
  if check_result "$out"; then
    log "wget OK -> $out"
    exit 0
  fi
else
  log "wget exit non-zero"
fi
rm -f "$out"

log "all download methods failed for $url"
exit 1
