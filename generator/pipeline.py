"""Image pipeline: raw artwork bytes -> finished 1072x1448 8-bit grayscale PNG.

Implements PLAN.md section 6 ("Generator specification"):
  - never crop (ImageOps.contain), paper-white padding
  - 1-px 40% gray hairline border around the painting
  - bottom caption band: title line + "artist, year" line, centered, ellipsized
  - tone: autocontrast (1% cutoff), optional gamma, sharpness 1.25
  - dither to the panel's 16 gray levels with Floyd-Steinberg, save as mode L

Design choice (not spelled out verbatim by the order of bullets in the plan):
tone adjustments (autocontrast/gamma/sharpen) are applied to the artwork
itself, before it is padded onto the paper-white canvas. Applying them to
the whole canvas instead would let large white margins dominate the
histogram and make autocontrast a no-op for portrait/landscape-mismatched
paintings, defeating its purpose.
"""
from io import BytesIO

from PIL import Image, ImageDraw, ImageEnhance, ImageFont, ImageOps

import config


def _load_font(size: int):
    """Pillow >= 10.1 ImageFont.load_default(size=...) is a scalable default
    font. Prefer a bundled OFL serif under generator/fonts/ if present."""
    for candidate in ("EBGaramond-Regular.ttf", "LibreBaskerville-Regular.ttf"):
        path = config.FONTS_DIR / candidate
        if path.exists():
            return ImageFont.truetype(str(path), size=size)
    return ImageFont.load_default(size=size)


def _ellipsize(text: str, max_chars: int) -> str:
    text = text.strip()
    if len(text) <= max_chars:
        return text
    return text[: max_chars - 1].rstrip() + "…"


def _build_palette_image(palette: list[int]) -> Image.Image:
    pal_img = Image.new("P", (16, 1))
    flat = []
    for v in palette:
        flat += [v, v, v]
    flat += [0, 0, 0] * (256 - len(palette))
    pal_img.putpalette(flat)
    return pal_img


def _rotate_transpose(rotate_degrees: int):
    if rotate_degrees == 90:
        return Image.Transpose.ROTATE_90
    if rotate_degrees == 270:
        return Image.Transpose.ROTATE_270
    raise ValueError(f"ROTATE must be 90 or 270, got {rotate_degrees!r}")


def render(image_bytes: bytes, artwork, cfg=config) -> Image.Image:
    """Render one artwork to a finished, panel-ready grayscale image.

    artwork: an object with .title, .artist, .year attributes (sources.Artwork).
    cfg: the config module (or a compatible namespace) -- passed explicitly
    so pipeline.py stays unit-testable without importing the real config.
    """
    src = Image.open(BytesIO(image_bytes))
    src = ImageOps.exif_transpose(src) or src
    src = src.convert("L")

    # --- Tone adjustments on the artwork itself -------------------------
    # (Sharpening is applied later, after the resize, so it acts at panel
    # resolution instead of being averaged away by the LANCZOS downscale.)
    src = ImageOps.autocontrast(src, cutoff=cfg.AUTOCONTRAST_CUTOFF)
    if cfg.GAMMA != 1.0:
        inv_gamma = 1.0 / cfg.GAMMA
        lut = [min(255, max(0, round(255 * ((i / 255) ** inv_gamma)))) for i in range(256)]
        src = src.point(lut)

    # --- Compose canvas (native orientation before any landscape rotate) -
    if cfg.ORIENTATION == "landscape":
        canvas_w, canvas_h = cfg.HEIGHT, cfg.WIDTH
    else:
        canvas_w, canvas_h = cfg.WIDTH, cfg.HEIGHT

    canvas = Image.new("L", (canvas_w, canvas_h), 255)  # paper white
    draw = ImageDraw.Draw(canvas)

    margin = cfg.MARGIN
    title_font = _load_font(cfg.TITLE_FONT_SIZE)
    caption_font = _load_font(cfg.CAPTION_FONT_SIZE)

    title_text = _ellipsize(artwork.title, cfg.CAPTION_MAX_CHARS)
    byline_bits = [b for b in (artwork.artist, str(artwork.year)) if b]
    byline_text = _ellipsize(", ".join(byline_bits), cfg.CAPTION_MAX_CHARS)

    title_bbox = draw.textbbox((0, 0), title_text, font=title_font)
    byline_bbox = draw.textbbox((0, 0), byline_text, font=caption_font)
    title_h = title_bbox[3] - title_bbox[1]
    byline_h = byline_bbox[3] - byline_bbox[1]
    line_gap = 6
    band_inner_pad = 10
    caption_band_height = band_inner_pad + title_h + line_gap + byline_h + band_inner_pad

    # --- Painting area = canvas minus margins minus caption band --------
    area_w = canvas_w - 2 * margin
    area_h = canvas_h - 2 * margin - caption_band_height
    contained = ImageOps.contain(src, (area_w, area_h), Image.Resampling.LANCZOS)
    contained = ImageEnhance.Sharpness(contained).enhance(cfg.SHARPNESS)

    px = margin + (area_w - contained.width) // 2
    py = margin + (area_h - contained.height) // 2
    canvas.paste(contained, (px, py))

    # 1-px 40% gray hairline border around the painting
    draw.rectangle(
        [px - 1, py - 1, px + contained.width, py + contained.height],
        outline=cfg.HAIRLINE_GRAY,
        width=1,
    )

    # --- Caption band -----------------------------------------------------
    caption_top = canvas_h - margin - caption_band_height
    title_cy = caption_top + band_inner_pad + title_h / 2 - title_bbox[1]
    byline_cy = caption_top + band_inner_pad + title_h + line_gap + byline_h / 2 - byline_bbox[1]
    draw.text((canvas_w / 2, title_cy), title_text, font=title_font, fill=0, anchor="mm")
    draw.text((canvas_w / 2, byline_cy), byline_text, font=caption_font, fill=0, anchor="mm")

    # --- Landscape rotate into framebuffer coordinates ---------------------
    if cfg.ORIENTATION == "landscape":
        canvas = canvas.transpose(_rotate_transpose(cfg.ROTATE))

    # --- Quantize to the panel's 16 gray levels with Floyd-Steinberg ------
    pal_img = _build_palette_image(cfg.PALETTE)
    quantized = canvas.convert("RGB").quantize(palette=pal_img, dither=Image.Dither.FLOYDSTEINBERG)
    result = quantized.convert("L")

    assert result.mode == "L"
    assert result.size == (cfg.WIDTH, cfg.HEIGHT), f"expected {(cfg.WIDTH, cfg.HEIGHT)}, got {result.size}"
    assert set(result.tobytes()) <= set(cfg.PALETTE), "quantized image contains values outside the 16-level palette"

    return result
