"""Draws the disk image window's background: the install steps, as pictures.

People open the disk image; few read the README. So the window shows the
drag to Applications, then the two things macOS shows the first time an app
that is not notarized is opened, each drawn with the button to press ringed
and a pointer on it. A shortcut in the window opens Privacy & Security.
Positions match the icon positions make-release.sh gives Finder (WINDOW and
the *_AT values below).

usage: python3 -I scripts/dmg/make_background.py   (writes scripts/dmg/background.tiff)
"""

import pathlib
import subprocess
import tempfile

from PIL import Image, ImageDraw, ImageFont

HERE = pathlib.Path(__file__).resolve().parent
ICON = HERE.parents[1] / "leanring-buddy/Assets.xcassets/AppIcon.appiconset/256-mac.png"
WIDTH, HEIGHT = 760, 640
FONT = "/System/Library/Fonts/SFNS.ttf"
INK, SOFT, FAINT = (30, 30, 34), (98, 98, 106), (150, 150, 158)
ACCENT, PAPER, CARD, LINE = (37, 99, 235), (247, 245, 240), (255, 255, 255), (222, 218, 208)
# Where make-release.sh puts the icons, in window points (icon centres).
BUDDY_AT, APPLICATIONS_AT, SHORTCUT_AT = (210, 130), (550, 130), (555, 556)


def font(size, scale, weight=None):
    loaded = ImageFont.truetype(FONT, round(size * scale))
    if weight:
        try:
            loaded.set_variation_by_name(weight)
        except Exception:
            pass
    return loaded


def draw(scale):
    image = Image.new("RGB", (WIDTH * scale, HEIGHT * scale), PAPER)
    pen = ImageDraw.Draw(image)
    s = lambda value: round(value * scale)
    box = lambda x0, y0, x1, y1: [(s(x0), s(y0)), (s(x1), s(y1))]

    def badge(x, y, number):
        pen.ellipse(box(x, y, x + 26, y + 26), fill=ACCENT)
        pen.text((s(x + 13), s(y + 13)), number, fill=(255, 255, 255), font=font(14, scale, "Bold"), anchor="mm")

    def ring(x0, y0, x1, y1):
        pen.rounded_rectangle(box(x0 - 5, y0 - 5, x1 + 5, y1 + 5), radius=s(12), outline=(234, 88, 12), width=s(3))

    def pointer(x, y):
        points = [(0, 0), (0, 22), (6, 17), (10, 26), (14, 24), (10, 15), (17, 15)]
        pen.polygon([(s(x + px), s(y + py)) for px, py in points], fill=INK, outline=(255, 255, 255))

    def button(x0, y0, x1, y1, words, primary):
        pen.rounded_rectangle(box(x0, y0, x1, y1), radius=s(7), fill=ACCENT if primary else (232, 232, 236))
        pen.text((s((x0 + x1) / 2), s((y0 + y1) / 2)), words, fill=(255, 255, 255) if primary else INK,
                 font=font(11.5, scale, "Semibold" if primary else None), anchor="mm")

    pen.text((s(WIDTH / 2), s(36)), "Install Buddy", fill=INK, font=font(24, scale, "Bold"), anchor="mm")

    # Step 1: the drag, an arrow between the two icons Finder draws.
    badge(WIDTH / 2 - 13, 70, "1")
    y = BUDDY_AT[1]
    pen.line([(s(290), s(y)), (s(458), s(y))], fill=ACCENT, width=s(5))
    pen.polygon([(s(472), s(y)), (s(454), s(y - 12)), (s(454), s(y + 12))], fill=ACCENT)
    pen.text((s(WIDTH / 2), s(232)), "Drag Buddy onto Applications", fill=INK, font=font(16, scale, "Semibold"), anchor="mm")

    pen.line([(s(40), s(262)), (s(WIDTH - 40), s(262))], fill=LINE, width=s(1))
    pen.text((s(WIDTH / 2), s(284)), "The first time only, macOS asks twice. This is what to click:",
             fill=SOFT, font=font(13, scale), anchor="mm")

    # Step 2: the "Not Opened" message, Done ringed.
    pen.rounded_rectangle(box(40, 304, 370, 520), radius=s(16), fill=CARD, outline=LINE, width=s(1))
    badge(56, 318, "2")
    pen.text((s(92), s(331)), "Open Buddy, then click Done", fill=INK, font=font(13.5, scale, "Semibold"), anchor="lm")
    dialog = box(95, 352, 315, 508)
    pen.rounded_rectangle(dialog, radius=s(14), fill=(242, 242, 245), outline=(214, 214, 220), width=s(1))
    icon = Image.open(ICON).convert("RGBA").resize((s(38), s(38)), Image.LANCZOS)
    image.paste(icon, (s(186), s(362)), icon)
    pen.text((s(205), s(414)), "“Buddy” Not Opened", fill=INK, font=font(12, scale, "Bold"), anchor="mm")
    pen.text((s(205), s(431)), "Apple could not verify “Buddy”", fill=SOFT, font=font(9.5, scale), anchor="mm")
    button(110, 446, 300, 470, "Done", True)
    button(110, 476, 300, 498, "Move to Trash", False)
    ring(110, 446, 300, 470)
    pointer(262, 458)

    # Step 3: Privacy & Security, Open Anyway ringed.
    pen.rounded_rectangle(box(390, 304, 720, 520), radius=s(16), fill=CARD, outline=LINE, width=s(1))
    badge(406, 318, "3")
    pen.text((s(442), s(331)), "In Settings, click Open Anyway", fill=INK, font=font(13.5, scale, "Semibold"), anchor="lm")
    pane = box(410, 352, 700, 508)
    pen.rounded_rectangle(pane, radius=s(12), fill=(242, 242, 245), outline=(214, 214, 220), width=s(1))
    pen.text((s(424), s(372)), "Privacy & Security", fill=INK, font=font(12.5, scale, "Bold"), anchor="lm")
    pen.text((s(424), s(394)), "scroll down to Security", fill=FAINT, font=font(10, scale), anchor="lm")
    pen.rounded_rectangle(box(420, 410, 690, 496), radius=s(9), fill=CARD)
    pen.text((s(432), s(430)), "“Buddy” was blocked to", fill=INK, font=font(10.5, scale), anchor="lm")
    pen.text((s(432), s(446)), "protect your Mac.", fill=INK, font=font(10.5, scale), anchor="lm")
    button(586, 426, 680, 450, "Open Anyway", False)
    ring(586, 426, 680, 450)
    pointer(650, 440)
    pen.text((s(432), s(476)), "then your Mac password, and Open", fill=FAINT, font=font(9.5, scale), anchor="lm")

    # The shortcut's label is drawn by Finder under its icon; this says why it is there.
    pen.text((s(474), s(SHORTCUT_AT[1] - 6)), "Shortcut to that page:", fill=SOFT, font=font(12, scale), anchor="rm")
    pen.text((s(40), s(HEIGHT - 26)), "After that Buddy opens like any app, and updates itself.",
             fill=SOFT, font=font(12, scale), anchor="lm")
    return image


with tempfile.TemporaryDirectory() as folder:
    one, two = pathlib.Path(folder) / "background.png", pathlib.Path(folder) / "background@2x.png"
    draw(1).save(one)
    draw(2).save(two)
    # One file holding both sizes, so the window is sharp on any display.
    subprocess.run(["tiffutil", "-cathidpicheck", str(one), str(two), "-out", str(HERE / "background.tiff")],
                   check=True, capture_output=True)
    draw(2).save(pathlib.Path(tempfile.gettempdir()) / "buddy-dmg-preview.png")
print("wrote", HERE / "background.tiff")
