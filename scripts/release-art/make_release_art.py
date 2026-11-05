"""Draws the pictures on a release page: a banner in a light and a dark
version, and the small section icons, so every release looks the same.

GitHub shows release notes on white or near-black depending on the reader's
theme. The banner is drawn twice and the notes pick with <picture>; the icons
are drawn once in a blue that reads on both. PNG rather than SVG because
GitHub does not reliably show SVG files linked from a release page.

The banner's comparison lines are real transcripts from the release's own
tests, set in BANNER below for each release.

usage: python3 -I scripts/release-art/make_release_art.py
       (writes docs/images/whats-new/<version>/banner-light.png, banner-dark.png
        and docs/images/icons/*.png)
"""

import pathlib

from PIL import Image, ImageDraw, ImageFont

ROOT = pathlib.Path(__file__).resolve().parents[2]
ICON = ROOT / "leanring-buddy/Assets.xcassets/AppIcon.appiconset/256-mac.png"
FONT = "/System/Library/Fonts/SFNS.ttf"
MONO = "/System/Library/Fonts/SFNSMono.ttf"

BANNER = {
    "version": "1.5",
    "headline": "Hears you better",
    "subline": "Technical words, long pauses and half-finished questions come through whole.",
    "before_label": "The Mac's recognizer heard",
    "before": [("does ", None), ("posters", "wrong"), (" keep the outbox round until ", None), ("Kath", "wrong"), (" acknowledges it?", None)],
    "after_label": "Buddy 1.5 heard",
    "after": [("does ", None), ("Postgres", "right"), (" keep the outbox round till ", None), ("Kafka", "right"), (" acknowledges it?", None)],
}

THEMES = {
    "light": dict(background=(247, 245, 240), card=(255, 255, 255), line=(222, 218, 208),
                  ink=(30, 30, 34), soft=(98, 98, 106), faint=(150, 150, 158),
                  accent=(37, 99, 235), right=(21, 128, 61), wrong=(185, 28, 28)),
    "dark": dict(background=(13, 17, 23), card=(22, 27, 34), line=(48, 54, 61),
                 ink=(230, 237, 243), soft=(160, 168, 178), faint=(110, 118, 129),
                 accent=(88, 166, 255), right=(63, 185, 80), wrong=(248, 81, 73)),
}

SCALE = 2
WIDTH, HEIGHT = 1280, 400


def font(size, weight=None, mono=False):
    loaded = ImageFont.truetype(MONO if mono else FONT, round(size * SCALE))
    if weight:
        try:
            loaded.set_variation_by_name(weight)
        except Exception:
            pass
    return loaded


def s(value):
    return round(value * SCALE)


def draw_spans(pen, x, y, spans, theme, size):
    """Writes a line of text in pieces, colouring the words that were heard
    wrong or right, with a wavy underline under the wrong ones."""
    for text, kind in spans:
        weight = "Semibold" if kind else None
        typeface = font(size, weight)
        colour = theme[kind] if kind else theme["ink"]
        pen.text((s(x), s(y)), text, fill=colour, font=typeface, anchor="ls")
        width = pen.textlength(text, font=typeface) / SCALE
        if kind == "wrong":
            points = []
            step = 3.0
            position = x
            up = True
            while position <= x + width:
                points.append((s(position), s(y + 5 + (0 if up else 2.4))))
                position += step
                up = not up
            pen.line(points, fill=colour, width=s(1.4))
        x += width
    return x


def banner(theme_name):
    theme = THEMES[theme_name]
    image = Image.new("RGB", (s(WIDTH), s(HEIGHT)), theme["background"])
    pen = ImageDraw.Draw(image)

    icon = Image.open(ICON).convert("RGBA").resize((s(84), s(84)), Image.LANCZOS)
    image.paste(icon, (s(64), s(96)), icon)
    pen.text((s(64), s(232)), f"Buddy {BANNER['version']}", fill=theme["ink"], font=font(46, "Bold"), anchor="ls")
    pen.text((s(64), s(276)), BANNER["headline"], fill=theme["accent"], font=font(30, "Semibold"), anchor="ls")
    words = BANNER["subline"].split()
    lines, current = [], ""
    for word in words:
        candidate = (current + " " + word).strip()
        if pen.textlength(candidate, font=font(16.5)) / SCALE > 400:
            lines.append(current)
            current = word
        else:
            current = candidate
    lines.append(current)
    for index, line in enumerate(lines):
        pen.text((s(64), s(314 + index * 24)), line, fill=theme["soft"], font=font(16.5), anchor="ls")

    # The comparison card: one spoken question, as each recognizer heard it.
    left, top, right, bottom = 540, 70, 1216, 330
    pen.rounded_rectangle([(s(left), s(top)), (s(right), s(bottom))], radius=s(18),
                          fill=theme["card"], outline=theme["line"], width=s(1.5))
    pen.text((s(left + 32), s(top + 44)), "SAME QUESTION, SAME MICROPHONE", fill=theme["faint"],
             font=font(12.5, "Semibold"), anchor="ls")
    pen.text((s(left + 32), s(top + 92)), BANNER["before_label"], fill=theme["soft"], font=font(14), anchor="ls")
    draw_spans(pen, left + 32, top + 124, BANNER["before"], theme, 19)
    pen.line([(s(left + 32), s(top + 152)), (s(right - 32), s(top + 152))], fill=theme["line"], width=s(1))
    pen.text((s(left + 32), s(top + 188)), BANNER["after_label"], fill=theme["soft"], font=font(14), anchor="ls")
    draw_spans(pen, left + 32, top + 220, BANNER["after"], theme, 19)

    return image.resize((s(WIDTH), s(HEIGHT)), Image.LANCZOS)


# Section icons: simple strokes on a 24 unit grid, like the app's own symbols.
ICONS = {
    "hearing": [("round_rect", (9, 3, 15, 14, 3)), ("arc", (5, 4, 19, 18, 0, 180)), ("line", (12, 18, 12, 21)),
                ("line", (8.5, 21, 15.5, 21))],
    "time": [("circle", (12, 12, 9)), ("line", (12, 7, 12, 12)), ("line", (12, 12, 15.5, 14))],
    "history": [("poly", ((12, 3), (21, 8), (12, 13), (3, 8), (12, 3))), ("poly", ((3, 12.5), (12, 17.5), (21, 12.5))),
                ("poly", ((3, 17), (12, 22), (21, 17)))],
    "more": [("circle_fill", (5, 12, 1.6)), ("circle_fill", (12, 12, 1.6)), ("circle_fill", (19, 12, 1.6))],
    "update": [("arc", (3, 3, 21, 21, 40, 330)), ("poly", ((21, 4), (20.2, 9.4), (15, 8.4)))],
    "install": [("line", (12, 3, 12, 15)), ("poly", ((7, 10.5), (12, 15.5), (17, 10.5))), ("line", (4, 20, 20, 20))],
    "check": [("poly", ((4, 12.5), (9.5, 18), (20, 6)))],
}


def icon(name, colour=(59, 130, 246), size=96):
    unit = size / 24
    image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    pen = ImageDraw.Draw(image)
    width = round(2.1 * unit)
    for kind, values in ICONS[name]:
        if kind == "line":
            x0, y0, x1, y1 = values
            pen.line([(x0 * unit, y0 * unit), (x1 * unit, y1 * unit)], fill=colour, width=width)
            for x, y in ((x0, y0), (x1, y1)):
                pen.ellipse([(x * unit - width / 2, y * unit - width / 2), (x * unit + width / 2, y * unit + width / 2)], fill=colour)
        elif kind == "poly":
            points = [(x * unit, y * unit) for x, y in values]
            pen.line(points, fill=colour, width=width, joint="curve")
            for x, y in (points[0], points[-1]):
                pen.ellipse([(x - width / 2, y - width / 2), (x + width / 2, y + width / 2)], fill=colour)
        elif kind == "circle":
            x, y, radius = values
            pen.ellipse([((x - radius) * unit, (y - radius) * unit), ((x + radius) * unit, (y + radius) * unit)], outline=colour, width=width)
        elif kind == "circle_fill":
            x, y, radius = values
            pen.ellipse([((x - radius) * unit, (y - radius) * unit), ((x + radius) * unit, (y + radius) * unit)], fill=colour)
        elif kind == "round_rect":
            x0, y0, x1, y1, radius = values
            pen.rounded_rectangle([(x0 * unit, y0 * unit), (x1 * unit, y1 * unit)], radius=radius * unit, outline=colour, width=width)
        elif kind == "arc":
            x0, y0, x1, y1, start, end = values
            pen.arc([(x0 * unit, y0 * unit), (x1 * unit, y1 * unit)], start=start, end=end, fill=colour, width=width)
    return image


def main():
    releases = ROOT / "docs/images/whats-new" / BANNER["version"]
    releases.mkdir(parents=True, exist_ok=True)
    for theme_name in THEMES:
        banner(theme_name).save(releases / f"banner-{theme_name}.png", optimize=True)
    icons = ROOT / "docs/images/icons"
    icons.mkdir(parents=True, exist_ok=True)
    for name in ICONS:
        icon(name).save(icons / f"{name}.png", optimize=True)
    print("wrote", releases, "and", icons)


if __name__ == "__main__":
    main()
