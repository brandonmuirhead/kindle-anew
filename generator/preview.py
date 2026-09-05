"""Contact sheet of the whole pool, plus a way to eyeball one result at full
size, for Fable/the user to review crop, caption and tonality.

Usage:
    python preview.py                 # write generator/preview.png (contact sheet)
    python preview.py --cols 12       # customize grid width
    python preview.py --open 005      # open docs/art/005.png at full size
    python preview.py --open 5        # same, bare index also accepted
"""
import argparse
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

import config

PREVIEW_PATH = Path(__file__).resolve().parent / "preview.png"


def contact_sheet(cols: int = 10, thumb_w: int = 160) -> Path | None:
    art_dir = config.OUTPUT_DIR / "art"
    files = sorted(art_dir.glob("*.png"))
    if not files:
        print(f"preview: no images found in {art_dir}")
        return None

    thumb_h = round(thumb_w * config.HEIGHT / config.WIDTH)
    label_h = 16
    pad = 6
    cell_w = thumb_w + pad * 2
    cell_h = thumb_h + label_h + pad * 2
    rows = -(-len(files) // cols)  # ceil division

    sheet = Image.new("L", (cell_w * cols, cell_h * rows), 255)
    draw = ImageDraw.Draw(sheet)
    font = ImageFont.load_default(size=11)

    for i, f in enumerate(files):
        im = Image.open(f).convert("L")
        thumb = im.resize((thumb_w, thumb_h), Image.Resampling.LANCZOS)
        col, row = i % cols, i // cols
        x, y = col * cell_w + pad, row * cell_h + pad
        sheet.paste(thumb, (x, y))
        draw.rectangle([x, y, x + thumb_w - 1, y + thumb_h - 1], outline=100, width=1)
        draw.text((x + thumb_w / 2, y + thumb_h + 2), f.name, font=font, fill=0, anchor="ma")

    sheet.save(PREVIEW_PATH)
    print(f"preview: wrote {PREVIEW_PATH} ({len(files)} images, {cols} cols x {rows} rows)")
    return PREVIEW_PATH


def open_one(ref: str) -> None:
    """Open one rendered output at full size in the OS default image viewer.
    `ref` may be a bare index ("5"), a zero-padded name ("005" / "005.png"),
    or a path."""
    art_dir = config.OUTPUT_DIR / "art"
    candidate = Path(ref)
    if candidate.suffix.lower() == ".png" and candidate.exists():
        path = candidate
    else:
        stem = ref.replace(".png", "")
        try:
            n = int(stem)
        except ValueError:
            print(f"preview: can't parse {ref!r} as an index or filename")
            return
        path = art_dir / f"{n:03d}.png"

    if not path.exists():
        print(f"preview: {path} does not exist")
        return

    im = Image.open(path)
    print(f"preview: opening {path} ({im.mode}, {im.size})")
    im.show(title=path.name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cols", type=int, default=10, help="contact sheet grid width")
    parser.add_argument("--thumb-width", type=int, default=160, help="thumbnail width in px")
    parser.add_argument("--open", metavar="REF", help="open one output at full size instead of building the sheet")
    args = parser.parse_args()

    if args.open:
        open_one(args.open)
    else:
        contact_sheet(cols=args.cols, thumb_w=args.thumb_width)


if __name__ == "__main__":
    main()
