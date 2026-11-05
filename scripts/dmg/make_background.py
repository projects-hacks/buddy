"""Draws the disk image window's background: the install steps, as a picture.

People open the disk image; few read the README. So the first-open steps
that macOS needs for an app that is not notarized are drawn where the drag
to Applications happens, and the window holds a shortcut that opens
Privacy & Security directly. Positions match the icon positions that
make-release.sh gives Finder.

usage: python3 -I scripts/dmg/make_background.py   (writes scripts/dmg/background.tiff)
"""

import pathlib
import subprocess
import tempfile

from PIL import Image, ImageDraw, ImageFont

HERE = pathlib.Path(__file__).resolve().parent
WIDTH, HEIGHT = 660, 440
FONT = "/System/Library/Fonts/SFNS.ttf"
INK = (34, 34, 38)
SOFT = (104, 104, 112)
ACCENT = (37, 99, 235)
PAPER = (248, 246, 241)


def font(size, scale, weight=None):
    loaded = ImageFont.truetype(FONT, size * scale)
    if weight:
        try:
            loaded.set_variation_by_name(weight)
        except Exception:
            pass
    return loaded


def draw(scale):
    image = Image.new("RGB", (WIDTH * scale, HEIGHT * scale), PAPER)
    pen = ImageDraw.Draw(image)
    s = lambda value: value * scale

    pen.text((s(WIDTH / 2), s(34)), "Install Buddy", fill=INK, font=font(22, scale, "Bold"), anchor="mm")

    # The arrow between the app (x 165) and Applications (x 495), at icon height.
    y = s(140)
    pen.line([(s(240), y), (s(412), y)], fill=ACCENT, width=s(5))
    pen.polygon([(s(424), y), (s(406), y - s(12)), (s(406), y + s(12))], fill=ACCENT)
    pen.text((s(WIDTH / 2), s(226)), "1   Drag Buddy onto Applications", fill=INK, font=font(15, scale, "Semibold"), anchor="mm")

    pen.line([(s(40), s(254)), (s(WIDTH - 40), s(254))], fill=(222, 218, 208), width=s(1))
    pen.text((s(40), s(272)), "The first time only, macOS asks you to confirm:", fill=SOFT, font=font(12.5, scale))

    steps = [
        ("2", "Open Buddy from Applications. When macOS says", "it can't check Buddy, click Done."),
        ("3", "Open Privacy & Security (the shortcut on the right),", "scroll down and click Open Anyway."),
    ]
    top = 300
    for number, first, second in steps:
        pen.ellipse([(s(40), s(top)), (s(62), s(top + 22))], fill=ACCENT)
        pen.text((s(51), s(top + 11)), number, fill=(255, 255, 255), font=font(13, scale, "Bold"), anchor="mm")
        pen.text((s(74), s(top + 2)), first, fill=INK, font=font(13.5, scale))
        pen.text((s(74), s(top + 21)), second, fill=INK, font=font(13.5, scale))
        top += 56
    pen.text((s(40), s(HEIGHT - 22)), "After that Buddy opens like any app and updates itself.",
             fill=SOFT, font=font(11.5, scale))
    return image


with tempfile.TemporaryDirectory() as folder:
    one, two = pathlib.Path(folder) / "background.png", pathlib.Path(folder) / "background@2x.png"
    draw(1).save(one)
    draw(2).save(two)
    # One file holding both sizes, so the window is sharp on any display.
    subprocess.run(["tiffutil", "-cathidpicheck", str(one), str(two), "-out", str(HERE / "background.tiff")], check=True)
    draw(2).save(pathlib.Path(tempfile.gettempdir()) / "buddy-dmg-preview.png")
print("wrote", HERE / "background.tiff")
