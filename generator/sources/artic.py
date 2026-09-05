"""Art Institute of Chicago source: boosted + public-domain + painting works.

Query verified in PLAN.md section 0: POST /api/v1/artworks/search with
bool.must [is_boosted, is_public_domain, artwork_type_id=1 (Painting)].
Image URL is IIIF: https://www.artic.edu/iiif/2/{image_id}/full/1686,/0/default.jpg
"""
import sys

import requests

import config
from sources import Artwork

SEARCH_URL = "https://api.artic.edu/api/v1/artworks/search"
IIIF_TEMPLATE = "https://www.artic.edu/iiif/2/{image_id}/full/1686,/0/default.jpg"
PAGE_SIZE = 100


def _query_body(offset: int) -> dict:
    return {
        "query": {
            "bool": {
                "must": [
                    {"term": {"is_boosted": True}},
                    {"term": {"is_public_domain": True}},
                    {"term": {"artwork_type_id": 1}},
                ]
            }
        },
        "fields": "id,title,artist_title,date_display,image_id",
        "limit": PAGE_SIZE,
        "from": offset,
    }


def candidates() -> list[Artwork]:
    works = []
    offset = 0
    total = None

    while total is None or offset < total:
        try:
            resp = requests.post(
                SEARCH_URL,
                json=_query_body(offset),
                headers={"User-Agent": config.USER_AGENT},
                timeout=config.DOWNLOAD_TIMEOUT,
            )
            resp.raise_for_status()
        except requests.RequestException as e:
            print(f"artic: request failed at offset {offset} ({e}); stopping", file=sys.stderr)
            break

        data = resp.json()
        total = data.get("pagination", {}).get("total", 0)
        rows = data.get("data", [])
        if not rows:
            break

        for row in rows:
            image_id = row.get("image_id")
            if not image_id:
                continue  # no image available; skip
            aid = row["id"]
            works.append(
                Artwork(
                    id=str(aid),
                    title=row.get("title", "Untitled"),
                    artist=row.get("artist_title") or "Unknown",
                    year=row.get("date_display", ""),
                    source="artic",
                    source_url=f"https://www.artic.edu/artworks/{aid}",
                    image_url=IIIF_TEMPLATE.format(image_id=image_id),
                )
            )
        offset += PAGE_SIZE

    print(f"artic: {len(works)} candidates", file=sys.stderr)
    return works


if __name__ == "__main__":
    for w in candidates():
        print(w)
