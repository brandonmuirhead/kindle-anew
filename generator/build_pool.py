"""Gather artworks from all sources, dedupe, order, download, render, and
write docs/art/NNN.png + docs/pool.txt + docs/index.json.

Order (PLAN.md section 6): curated Wikimedia Commons icons first (in
commons_curated.txt order), then Art Institute of Chicago, then the Met --
deduped by normalized (artist, title) so an earlier source's version of a
duplicate wins. Only the AIC and Met groups are shuffled (independently,
with SEED) before merging; Commons stays in curated order.

Usage:
    python build_pool.py                  # full build, default POOL_SIZE
    python build_pool.py --limit 12       # quick run, first 12 artworks only
    python build_pool.py --only commons   # gather from a single source
"""
import argparse
import hashlib
import json
import random
import re
import sys
import time
from pathlib import Path

import requests

import config
from pipeline import render
from sources import Artwork
from sources import artic as artic_source
from sources import commons as commons_source
from sources import met as met_source


def normalize_key(artist: str, title: str) -> tuple[str, str]:
    def norm(s: str) -> str:
        s = s.lower()
        s = re.sub(r"[^a-z0-9]+", " ", s)
        return " ".join(s.split())

    return (norm(artist), norm(title))


def gather(only: str | None, needed: int | None = None) -> list[Artwork]:
    """Return the ordered, deduped candidate list: commons (curated order),
    then AIC (shuffled), then Met (shuffled).

    Sources are queried in that order and a later source is skipped once
    `needed` deduped candidates are already in hand: the Met walk alone
    takes minutes of paced API calls, so a rebuild only pays for the
    sources it will actually use."""
    seen = set()
    deduped: list[Artwork] = []

    def add_all(items: list[Artwork]) -> None:
        for art in items:
            key = normalize_key(art.artist, art.title)
            if key in seen:
                print(f"build_pool: dedupe skip ({art.source}) {art.artist!r} - {art.title!r}", file=sys.stderr)
                continue
            seen.add(key)
            deduped.append(art)

    def enough() -> bool:
        return needed is not None and len(deduped) >= needed

    if (only is None or only == "commons") and config.USE_COMMONS:
        add_all(commons_source.candidates())
    if (only is None or only == "artic") and config.USE_ARTIC and not enough():
        items = artic_source.candidates()
        random.Random(config.SEED).shuffle(items)
        add_all(items)
    if (only is None or only == "met") and config.USE_MET and not enough():
        items = met_source.candidates()
        random.Random(config.SEED).shuffle(items)
        add_all(items)

    return deduped


def _cache_path(url: str) -> Path:
    h = hashlib.sha1(url.encode("utf-8")).hexdigest()
    return config.CACHE_DIR / f"{h}.bin"


def download(url: str) -> bytes | None:
    """Download url with an on-disk cache, 3 retries, 60s timeout. Returns
    None (and logs) on failure, or if Content-Length exceeds the cap."""
    config.CACHE_DIR.mkdir(parents=True, exist_ok=True)
    cache_file = _cache_path(url)
    if cache_file.exists() and cache_file.stat().st_size > 0:
        return cache_file.read_bytes()

    last_err = None
    for attempt in range(1, config.DOWNLOAD_RETRIES + 1):
        try:
            resp = requests.get(
                url,
                headers={"User-Agent": config.USER_AGENT},
                timeout=config.DOWNLOAD_TIMEOUT,
                stream=True,
            )
            if resp.status_code == 403:
                # Some image CDNs (e.g. AIC's IIIF server) 403 any UA that
                # contains a URL. Retry once with a bare fallback UA before
                # counting this as a failed attempt.
                resp = requests.get(
                    url,
                    headers={"User-Agent": config.FALLBACK_USER_AGENT},
                    timeout=config.DOWNLOAD_TIMEOUT,
                    stream=True,
                )
            resp.raise_for_status()

            content_length = resp.headers.get("Content-Length")
            if content_length and int(content_length) > config.MAX_CONTENT_LENGTH:
                print(f"build_pool: skip (Content-Length {content_length} > cap): {url}", file=sys.stderr)
                return None

            data = bytearray()
            for chunk in resp.iter_content(chunk_size=65536):
                data.extend(chunk)
                if len(data) > config.MAX_CONTENT_LENGTH:
                    print(f"build_pool: skip (exceeded {config.MAX_CONTENT_LENGTH} bytes while streaming): {url}", file=sys.stderr)
                    return None

            data = bytes(data)
            if not data:
                raise ValueError("empty response body")
            cache_file.write_bytes(data)
            return data
        except (requests.RequestException, ValueError) as e:
            last_err = e
            if attempt < config.DOWNLOAD_RETRIES:
                time.sleep(min(2**attempt, 10))

    print(f"build_pool: download failed after {config.DOWNLOAD_RETRIES} attempts: {url} ({last_err})", file=sys.stderr)
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--limit", type=int, default=None, help="cap the number of artworks processed (quick runs)")
    parser.add_argument("--only", choices=["commons", "artic", "met"], default=None, help="gather from a single source")
    args = parser.parse_args()

    pool_size = args.limit if args.limit is not None else config.POOL_SIZE
    # Ask for a few spare candidates so download/render failures don't leave
    # the pool short; the loop below stops as soon as pool_size succeed.
    artworks = gather(args.only, needed=pool_size + 15)
    print(f"build_pool: {len(artworks)} deduped candidates for a pool of {pool_size}", file=sys.stderr)

    art_dir = config.OUTPUT_DIR / "art"
    art_dir.mkdir(parents=True, exist_ok=True)

    index = []
    for art in artworks:
        if len(index) >= pool_size:
            break
        i = len(index) + 1
        filename = f"{i:03d}.png"
        print(f"build_pool: [{i}/{pool_size}] {art.source}: {art.artist} - {art.title}", file=sys.stderr)

        data = download(art.image_url)
        if data is None:
            print(f"build_pool: SKIP (download failed): {art.artist} - {art.title}", file=sys.stderr)
            continue

        try:
            img = render(data, art, config)
        except Exception as e:
            print(f"build_pool: SKIP (render failed, {e}): {art.artist} - {art.title}", file=sys.stderr)
            continue

        out_path = art_dir / filename
        img.save(out_path, optimize=True)
        index.append(
            {
                "file": f"art/{filename}",
                "title": art.title,
                "artist": art.artist,
                "year": art.year,
                "source": art.source,
                "source_url": art.source_url,
            }
        )

    # Idempotent: remove any stale docs/art/NNN.png left over from a larger
    # previous build.
    final_count = len(index)
    for existing in art_dir.glob("*.png"):
        if existing.stem.isdigit() and int(existing.stem) > final_count:
            existing.unlink()

    config.OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    start_day = int(time.time() // 86400)
    with open(config.OUTPUT_DIR / "pool.txt", "w", encoding="utf-8") as f:
        f.write(f"{final_count}\n{start_day}\n")

    with open(config.OUTPUT_DIR / "index.json", "w", encoding="utf-8") as f:
        json.dump(index, f, indent=2, ensure_ascii=False)
        f.write("\n")

    print(f"build_pool: wrote {final_count} images to {art_dir}, pool.txt, index.json", file=sys.stderr)


if __name__ == "__main__":
    main()
