"""Metropolitan Museum of Art source: highlight + public-domain paintings.

Query verified in PLAN.md section 0:
  GET /public/collection/v1/search?isHighlight=true&isPublicDomain=true&hasImages=true&medium=Paintings&q=painting
    -> objectIDs
  GET /public/collection/v1/objects/{id} -> primaryImage (full-res original)

The search endpoint's isPublicDomain/hasImages filters are not fully
reliable (some returned objectIDs turn out to have isPublicDomain=False or
an empty primaryImage when fetched individually), so every object is
re-checked before being included.

The per-object endpoint sits behind an Imperva WAF that 403s a burst of
rapid sequential requests from the same client, even inside a single
requests.Session with cookies persisted -- observed live: ~350/420 object
fetches 403'd with no delay between requests, 0/10 403'd with a 0.3s delay.
So requests are paced with REQUEST_DELAY_SECS, and a single 403 is retried
once after a longer pause before giving up on that object.
"""
import sys
import time

import requests

import config
from sources import Artwork

SEARCH_URL = "https://collectionapi.metmuseum.org/public/collection/v1/search"
OBJECT_URL = "https://collectionapi.metmuseum.org/public/collection/v1/objects/{id}"
REQUEST_DELAY_SECS = 0.3
RETRY_DELAY_SECS = 3.0


def _search_object_ids() -> list[int]:
    resp = requests.get(
        SEARCH_URL,
        params={
            "isHighlight": "true",
            "isPublicDomain": "true",
            "hasImages": "true",
            "medium": "Paintings",
            "q": "painting",
        },
        headers={"User-Agent": config.USER_AGENT},
        timeout=config.DOWNLOAD_TIMEOUT,
    )
    resp.raise_for_status()
    data = resp.json()
    return data.get("objectIDs") or []


def candidates() -> list[Artwork]:
    try:
        object_ids = _search_object_ids()
    except requests.RequestException as e:
        print(f"met: search request failed ({e})", file=sys.stderr)
        return []

    works = []
    session = requests.Session()
    session.headers.update({"User-Agent": config.USER_AGENT})

    for oid in object_ids:
        time.sleep(REQUEST_DELAY_SECS)
        try:
            resp = session.get(OBJECT_URL.format(id=oid), timeout=config.DOWNLOAD_TIMEOUT)
            if resp.status_code == 403:
                # Likely the Imperva rate limit; back off once and retry.
                time.sleep(RETRY_DELAY_SECS)
                resp = session.get(OBJECT_URL.format(id=oid), timeout=config.DOWNLOAD_TIMEOUT)
            resp.raise_for_status()
        except requests.RequestException as e:
            print(f"met: object {oid} request failed ({e}); skipping", file=sys.stderr)
            continue

        obj = resp.json()
        if not obj.get("isPublicDomain"):
            continue
        image_url = obj.get("primaryImage")
        if not image_url:
            continue

        works.append(
            Artwork(
                id=str(oid),
                title=obj.get("title") or "Untitled",
                artist=obj.get("artistDisplayName") or "Unknown",
                year=obj.get("objectDate", ""),
                source="met",
                source_url=obj.get("objectURL") or f"https://www.metmuseum.org/art/collection/search/{oid}",
                image_url=image_url,
            )
        )

    print(f"met: {len(works)}/{len(object_ids)} objects usable", file=sys.stderr)
    return works


if __name__ == "__main__":
    for w in candidates():
        print(w)
