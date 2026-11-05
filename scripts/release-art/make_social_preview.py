"""Draws the picture shown when a link to Buddy is shared (the site's
og:image and the repository's social preview), so its words match the site.

The right side is a real answer on screen, kept as social-shot.png beside this
script; only the words on the left are drawn here.

usage: python3 -I scripts/release-art/make_social_preview.py
       (writes docs/images/social-preview.png, 1280 by 640)
"""

import pathlib

from PIL import Image, ImageDraw, ImageFont

ROOT = pathlib.Path(__file__).resolve().parents[2]
ICON = ROOT / "leanring-buddy/Assets.xcassets/AppIcon.appiconset/256-mac.png"
SHOT = pathlib.Path(__file__).resolve().parent / "social-shot.png"
FONT = "/System/Library/Fonts/SFNS.ttf"

BACKGROUND = (17, 18, 22)
INK = (244, 244, 246)
SOFT = (160, 164, 174)
ACCENT = (96, 165, 250)
SCALE = 2


def font(size, weight):
    loaded = ImageFont.truetype(FONT, size * SCALE)
    loaded.set_variation_by_name(weight)
    return loaded


def main():
    width, height = 1280, 640
    image = Image.new("RGB", (width * SCALE, height * SCALE), BACKGROUND)
    pen = ImageDraw.Draw(image)

    shot = Image.open(SHOT).convert("RGB")
    shot = shot.resize((shot.width * SCALE, shot.height * SCALE), Image.LANCZOS)
    image.paste(shot, (470 * SCALE, 104 * SCALE))

    icon = Image.open(ICON).convert("RGBA").resize((88 * SCALE, 88 * SCALE), Image.LANCZOS)
    image.paste(icon, (56 * SCALE, 150 * SCALE), icon)

    left = 56 * SCALE
    pen.text((left, 318 * SCALE), "Buddy", fill=INK, font=font(64, "Bold"), anchor="ls")
    pen.text((left, 368 * SCALE), "Your screen,", fill=INK, font=font(34, "Semibold"), anchor="ls")
    pen.text((left, 410 * SCALE), "explained.", fill=ACCENT, font=font(34, "Semibold"), anchor="ls")
    for index, line in enumerate(["Ask about anything on your screen.", "Buddy explains it out loud and", "draws on it while it talks."]):
        pen.text((left, (456 + index * 26) * SCALE), line, fill=SOFT, font=font(19, "Regular"), anchor="ls")
    pen.text((left, 584 * SCALE), "Free and open source  ·  projects-hacks.github.io/buddy", fill=ACCENT, font=font(16, "Semibold"), anchor="ls")

    image.resize((width, height), Image.LANCZOS).save(ROOT / "docs/images/social-preview.png", optimize=True)
    print("wrote docs/images/social-preview.png")


if __name__ == "__main__":
    main()
