"""Make the "please charge" screen shown by loop.sh when the battery is
below LOW_BATTERY_PCT.

Same technique as make_test_image.py: render at 1072x1448 in mode "L", then
snap every pixel to the panel's 16 real gray levels (0, 17, ..., 255) so
eips's 8-to-4-bit truncation never introduces a value outside the palette.
Output: kindle/artframe/charge.png (loop.sh paints this directly with
`eips -f -g`, no caption band, no dithering needed for flat text/shapes).
"""
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

W, H = 1072, 1448
LEVELS = [i * 17 for i in range(16)]
WHITE = 255
BLACK = 0
MID_GRAY = LEVELS[4]  # a soft gray for the battery-outline icon

TITLE = "Battery low"
SUBTITLE = "please charge"

img = Image.new("L", (W, H), WHITE)
d = ImageDraw.Draw(img)

# A simple battery glyph above the text: rounded body + a small nub, drawn
# with plain rectangles (no external font/icon assets needed).
body_w, body_h = 220, 110
nub_w, nub_h = 18, 40
cx = W // 2
body_top = H // 2 - 260
body_left = cx - body_w // 2
body_right = body_left + body_w
body_bottom = body_top + body_h
d.rectangle([body_left, body_top, body_right, body_bottom], outline=BLACK, width=6)
nub_left = body_right
nub_top = body_top + (body_h - nub_h) // 2
d.rectangle([nub_left, nub_top, nub_left + nub_w, nub_top + nub_h], fill=BLACK)
# Low charge: a single narrow red-ish (dark gray, this is grayscale) bar at
# the left of the body, rest left empty/white to read as "low".
pad = 12
low_w = int((body_w - 2 * pad) * 0.18)
d.rectangle(
    [body_left + pad, body_top + pad, body_left + pad + low_w, body_bottom - pad],
    fill=BLACK,
)

title_font = ImageFont.load_default(size=64)
subtitle_font = ImageFont.load_default(size=44)

d.text((cx, body_bottom + 90), TITLE, fill=BLACK, anchor="mm", font=title_font)
d.text((cx, body_bottom + 170), SUBTITLE, fill=BLACK, anchor="mm", font=subtitle_font)
d.text(
    (cx, H - 80),
    "Art Frame will resume once charged",
    fill=MID_GRAY,
    anchor="mm",
    font=ImageFont.load_default(size=28),
)

# Text/shapes above are already flat colors, but anti-aliased glyph edges can
# introduce off-palette gray values; snap everything to the nearest of the
# 16 panel levels, exactly like make_test_image.py.
img = img.point(lambda p: round(p / 17) * 17)

out = Path(__file__).resolve().parents[1] / "kindle" / "artframe" / "charge.png"
out.parent.mkdir(parents=True, exist_ok=True)
img.save(out, optimize=True)

chk = Image.open(out)
assert chk.mode == "L" and chk.size == (W, H)
assert set(chk.tobytes()) <= set(LEVELS)
print(f"wrote {out} ({out.stat().st_size} bytes), mode={chk.mode}, size={chk.size}")
