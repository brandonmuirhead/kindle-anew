"""Wikimedia Commons source: curated famous public-domain paintings.

Reads commons_curated.txt (File title | Title | Artist | Year, most-iconic
first), batches the titles 50 at a time into the imageinfo API, and returns
one Artwork per title that both (a) resolves (the API doesn't report it
missing) and (b) is tagged "Public domain" in LicenseShortName. Titles that
fail either check are skipped and logged to stderr -- the curated list is
allowed to contain the occasional stale title; iterate on the misses.

Order is preserved: candidates() returns Artwork objects in the same order
as commons_curated.txt, since PLAN.md specifies Commons works come first,
in curated order, in the final pool.
"""
import sys
from pathlib import Path

import requests

import config
from sources import Artwork

API_URL = "https://commons.wikimedia.org/w/api.php"
CURATED_FILE = Path(__file__).resolve().parent / "commons_curated.txt"
BATCH_SIZE = 50


def _read_curated(path: Path = CURATED_FILE):
    """Parse commons_curated.txt into a list of (file_title, title, artist, year)."""
    rows = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = [p.strip() for p in line.split("|")]
            if len(parts) != 4:
                print(f"commons: skipping malformed line: {line!r}", file=sys.stderr)
                continue
            rows.append(tuple(parts))
    return rows


def _batched(seq, n):
    for i in range(0, len(seq), n):
        yield seq[i : i + n]


def _fetch_imageinfo(file_titles):
    """Query imageinfo for a batch (<=50) of 'File:...' titles.

    Returns a dict mapping the *originally requested* title (without the
    'File:' prefix, using the MediaWiki normalization map to recover it)
    to a result dict with keys: status ("ok"/"missing"/"nopd"), thumburl,
    license.
    """
    resp = requests.get(
        API_URL,
        params={
            "action": "query",
            "titles": "|".join(f"File:{t}" for t in file_titles),
            "prop": "imageinfo",
            "iiprop": "url|size|extmetadata",
            "iiurlwidth": 1920,
            "format": "json",
            "formatversion": "2",
        },
        headers={"User-Agent": config.USER_AGENT},
        timeout=config.DOWNLOAD_TIMEOUT,
    )
    resp.raise_for_status()
    data = resp.json()

    # MediaWiki normalizes titles (underscores<->spaces, first letter case);
    # build a map from normalized title back to what we requested so results
    # key on the original file_titles entries.
    norm_map = {}
    for n in data.get("query", {}).get("normalized", []):
        norm_map[n["to"]] = n["from"]

    results = {}
    pages = data.get("query", {}).get("pages", [])
    for page in pages:
        page_title = page.get("title", "")
        requested = norm_map.get(page_title, page_title)
        key = requested[5:] if requested.startswith("File:") else requested

        if page.get("missing"):
            results[key] = {"status": "missing"}
            continue

        imageinfo = page.get("imageinfo")
        if not imageinfo:
            results[key] = {"status": "missing"}
            continue

        info = imageinfo[0]
        extmeta = info.get("extmetadata", {})
        license_short = extmeta.get("LicenseShortName", {}).get("value", "")
        thumburl = info.get("thumburl") or info.get("url")

        if "Public domain" not in license_short:
            results[key] = {"status": "nopd", "license": license_short}
        else:
            results[key] = {"status": "ok", "thumburl": thumburl, "license": license_short}

    return results


def candidates() -> list[Artwork]:
    rows = _read_curated()
    works = []

    for batch in _batched(rows, BATCH_SIZE):
        file_titles = [r[0] for r in batch]
        try:
            results = _fetch_imageinfo(file_titles)
        except requests.RequestException as e:
            print(f"commons: batch request failed ({e}); skipping {len(file_titles)} titles", file=sys.stderr)
            continue

        for file_title, title, artist, year in batch:
            res = results.get(file_title)
            if res is None or res["status"] == "missing":
                print(f"commons: MISSING (not found on Commons): {file_title!r}", file=sys.stderr)
                continue
            if res["status"] == "nopd":
                print(f"commons: SKIP (not public domain, license={res['license']!r}): {file_title!r}", file=sys.stderr)
                continue

            page_url = "https://commons.wikimedia.org/wiki/File:" + file_title.replace(" ", "_")
            works.append(
                Artwork(
                    id=file_title,
                    title=title,
                    artist=artist,
                    year=year,
                    source="commons",
                    source_url=page_url,
                    image_url=res["thumburl"],
                )
            )

    print(f"commons: {len(works)}/{len(rows)} curated titles resolved", file=sys.stderr)
    return works


if __name__ == "__main__":
    for w in candidates():
        print(w)
