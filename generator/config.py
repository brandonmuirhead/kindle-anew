"""Configuration constants for the art-frame generator.

See PLAN.md section 6 ("Generator specification") for the source of truth.
Nothing here should hardcode a GitHub URL or Kindle-side path; the generator
only produces files under OUTPUT_DIR.
"""
from pathlib import Path

# --- Canvas -----------------------------------------------------------
WIDTH = 1072
HEIGHT = 1448
ORIENTATION = "portrait"  # "portrait" or "landscape"
# For ORIENTATION="landscape": compose on a HEIGHTxWIDTH canvas, then rotate
# by ROTATE degrees (90 or 270) so the saved file stays WIDTHxHEIGHT in
# framebuffer coordinates. Verify the actual direction on the device.
ROTATE = 90  # 90 or 270; only used when ORIENTATION == "landscape"

# --- Pool ---------------------------------------------------------------
POOL_SIZE = 160  # ~5 months of daily art: the 98 curated Commons icons, then the best of AIC
SEED = 20260904

# --- Tone -----------------------------------------------------------
GAMMA = 1.0  # 1.0 = no change; try 1.1-1.3 on device if midtones run dark
AUTOCONTRAST_CUTOFF = 1
SHARPNESS = 1.25

# --- 16-level e-ink palette --------------------------------------------
PALETTE = [i * 17 for i in range(16)]

# --- Layout --------------------------------------------------------------
MARGIN = 24
HAIRLINE_GRAY = round(0.40 * 255)  # 1-px 40% gray border around the painting
TITLE_FONT_SIZE = 36
CAPTION_FONT_SIZE = 28
CAPTION_MAX_CHARS = 60

# --- Output ---------------------------------------------------------------
REPO_ROOT = Path(__file__).resolve().parents[1]
OUTPUT_DIR = REPO_ROOT / "docs"
CACHE_DIR = Path(__file__).resolve().parent / "cache"
FONTS_DIR = Path(__file__).resolve().parent / "fonts"

# --- Source toggles -------------------------------------------------------
USE_COMMONS = True
USE_ARTIC = True
USE_MET = True

# --- Networking -------------------------------------------------------
USER_AGENT = "kindle-art-frame/0.1 (+https://github.com/brandonmuirhead/kindle-anew)"
# Fallback UA used only when a download gets HTTP 403 with USER_AGENT.
# Observed live: the Art Institute of Chicago's IIIF image CDN
# (www.artic.edu/iiif/2/...) 403s any User-Agent containing a URL --
# including the exact string PLAN.md specifies and even the plain
# "python-requests/..." default -- while its own JSON search API accepts
# USER_AGENT fine. A bare "product/version" UA is accepted. See
# build_pool.py:download() and the Deviations note in the Phase 1 report.
FALLBACK_USER_AGENT = "kindle-art-frame/0.1"
DOWNLOAD_RETRIES = 3
DOWNLOAD_TIMEOUT = 60  # seconds
MAX_CONTENT_LENGTH = 40 * 1024 * 1024  # 40 MB; skip images larger than this
