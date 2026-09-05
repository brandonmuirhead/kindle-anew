"""Art sources: each module exposes candidates() -> list[Artwork].

Artwork is a plain dataclass so downstream code (build_pool.py, pipeline.py)
has one shape to deal with regardless of which museum API it came from.
"""
from dataclasses import dataclass


@dataclass
class Artwork:
    id: str  # stable id, unique within its source (e.g. Commons file title, AIC id, Met objectID)
    title: str
    artist: str
    year: str
    source: str  # "commons" | "artic" | "met"
    source_url: str  # human-readable page to credit/link
    image_url: str  # direct URL to fetch the image bytes from
