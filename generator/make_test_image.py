"""Make a 1072x1448 8-bit grayscale test image for the Kindle panel.

16 horizontal bands with the exact e-ink palette values (0, 17, ..., 255),
a 1-px black border, and a label. Output: kindle/artframe/test.png
"""
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

W, H = 1072, 1448
LEVELS = [i * 17 for i in range(16)]

img = Image.new("L", (W, H), 255)
d = ImageDraw.Draw(img)
band = H // len(LEVELS)
for i, v in enumerate(LEVELS):
    d.rectangle([0, i * band, W, (i + 1) * band - 1], fill=v)
    d.text((24, i * band + 8), f"{i:2d}: {v}", fill=255 if v < 128 else 0, font=ImageFont.load_default(size=28))
d.rectangle([0, 0, W - 1, H - 1], outline=0, width=2)
d.rectangle([W // 4, H // 2 - 60, 3 * W // 4, H // 2 + 60], fill=255, outline=0, width=3)
d.text((W // 2, H // 2), "ART FRAME TEST 1072x1448", fill=0, anchor="mm", font=ImageFont.load_default(size=40))

# Text is anti-aliased; snap every pixel to the nearest of the 16 panel levels.
img = img.point(lambda p: round(p / 17) * 17)

out = Path(__file__).resolve().parents[1] / "kindle" / "artframe" / "test.png"
out.parent.mkdir(parents=True, exist_ok=True)
img.save(out, optimize=True)
chk = Image.open(out)
assert chk.mode == "L" and chk.size == (W, H)
assert set(chk.tobytes()) <= set(LEVELS)
print(f"wrote {out} ({out.stat().st_size} bytes), mode={chk.mode}, size={chk.size}")
