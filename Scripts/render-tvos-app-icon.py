#!/usr/bin/env python3
"""Render the Apple TV app icon and Top Shelf images from dionysus.icon.

tvOS can't use the iOS app's Icon Composer file: actool compiles no tvOS icon
from a `.icon`, and asks for an "App Icon & Top Shelf Image" brand-assets set
instead. This builds that set from the same pieces, so the two platforms stay
in step: the background gradient and the glyph (with its scale) are read from
`dionysus.icon/icon.json`.

The app icon is a two-layer image stack, which tvOS tilts with parallax on
focus: the gradient at the back, the glyph in front. The Top Shelf images are
flat. Every PNG carries the Display P3 profile, since the gradient's colours
are P3 values.

Needs ImageMagick (`brew install imagemagick`). Re-run after changing
dionysus.icon, then commit the regenerated set:

    Scripts/render-tvos-app-icon.py
"""

import json
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ICON = ROOT / "dionysus.icon"
OUT = ROOT / "DionysusTV/Resources/TVAssets.xcassets/App Icon & Top Shelf Image.brandassets"
P3_PROFILE = "/System/Library/ColorSync/Profiles/Display P3.icc"

# The glyph's height as a share of the icon's. The iOS icon draws it at
# `scale` of its natural size on a 1024pt canvas, where it fills about 70% of
# the height; the tvOS icon is wider than tall, so it's matched by height.
ICON_GLYPH_HEIGHT = 0.62
TOP_SHELF_GLYPH_HEIGHT = 0.50

INFO = {"author": "xcode", "version": 1}


def magick(*args):
    subprocess.run(["magick", *map(str, args)], check=True)


def p3_colour(value):
    """'display-p3:r,g,b,a' -> an ImageMagick rgb() of the raw components.
    The PNG is tagged with the P3 profile afterwards, so these are read as P3."""
    components = [float(c) for c in value.split(":", 1)[1].split(",")]
    r, g, b = (round(c * 255) for c in components[:3])
    return f"rgb({r},{g},{b})"


def load_icon():
    spec = json.loads((ICON / "icon.json").read_text())
    fill = spec["fill"]
    top, bottom = (p3_colour(c) for c in fill["linear-gradient"])
    stop = fill["orientation"]["stop"]["y"]
    layer = spec["groups"][0]["layers"][0]
    return {
        "top": top,
        "bottom": bottom,
        "stop": stop,
        "glyph": ICON / "Assets" / layer["image-name"],
    }


def background(icon, width, height, path):
    """The gradient, top to bottom, reaching the bottom colour at `stop` of
    the height and holding it below, as the .icon's orientation says."""
    ramp = max(1, round(height * icon["stop"]))
    magick(
        "-size", f"{width}x{ramp}", f"gradient:{icon['top']}-{icon['bottom']}",
        "-background", icon["bottom"], "-gravity", "north", "-extent", f"{width}x{height}",
        "-profile", P3_PROFILE, path,
    )


def glyph(icon, glyph_height, path):
    """The glyph in white, with a soft shadow like the .icon's, on
    transparency."""
    magick(
        "-background", "none", "-density", 600, icon["glyph"],
        "-fill", "white", "-colorize", "100",
        "-resize", f"x{glyph_height}",
        "(", "+clone", "-background", "black",
        "-shadow", f"50x{max(2, glyph_height // 24)}+0+{max(1, glyph_height // 40)}", ")",
        "+swap", "-background", "none", "-layers", "merge", "+repage", path,
    )


def front_layer(icon, width, height, path):
    with tempfile.TemporaryDirectory() as tmp:
        mark = Path(tmp) / "glyph.png"
        glyph(icon, round(height * ICON_GLYPH_HEIGHT), mark)
        magick(
            "-size", f"{width}x{height}", "xc:none", mark,
            # PNG32: a white-and-black layer is otherwise saved as greyscale,
            # which can't carry the RGB P3 profile.
            "-gravity", "center", "-composite", "-profile", P3_PROFILE, f"PNG32:{path}",
        )


def top_shelf(icon, width, height, path):
    with tempfile.TemporaryDirectory() as tmp:
        back = Path(tmp) / "back.png"
        mark = Path(tmp) / "glyph.png"
        background(icon, width, height, back)
        glyph(icon, round(height * TOP_SHELF_GLYPH_HEIGHT), mark)
        magick(back, mark, "-gravity", "center", "-composite", "-profile", P3_PROFILE, path)


def write_json(path, contents):
    path.mkdir(parents=True, exist_ok=True)
    (path / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")


def image_set(path, idiom, renders):
    """`renders` maps a scale ("1x") to a function writing the PNG."""
    images = []
    for scale, render in renders.items():
        filename = f"{path.stem.lower().replace(' ', '-')}@{scale}.png"
        path.mkdir(parents=True, exist_ok=True)
        render(path / filename)
        images.append({"filename": filename, "idiom": idiom, "scale": scale})
    write_json(path, {"images": images, "info": INFO})


def image_stack(path, idiom, width, height, scales, icon):
    layers = {
        "Front": front_layer,
        "Back": background,
    }
    for name, render in layers.items():
        layer = path / f"{name}.imagestacklayer"
        write_json(layer, {"info": INFO})
        image_set(
            layer / "Content.imageset", idiom,
            {f"{s}x": (lambda p, s=s, r=render: r(icon, width * s, height * s, p)) for s in scales},
        )
    write_json(path, {"info": INFO, "layers": [{"filename": f"{n}.imagestacklayer"} for n in layers]})


def main():
    if not shutil.which("magick"):
        raise SystemExit("ImageMagick not found: brew install imagemagick")
    icon = load_icon()
    if OUT.exists():
        shutil.rmtree(OUT)

    image_stack(OUT / "App Icon.imagestack", "tv", 400, 240, [1, 2], icon)
    image_stack(OUT / "App Icon - App Store.imagestack", "tv-marketing", 1280, 768, [1], icon)
    for name, width in [("Top Shelf Image", 1920), ("Top Shelf Image Wide", 2320)]:
        image_set(
            OUT / f"{name}.imageset", "tv",
            {f"{s}x": (lambda p, s=s, w=width: top_shelf(icon, w * s, 720 * s, p)) for s in (1, 2)},
        )

    write_json(OUT, {
        "assets": [
            {"filename": "App Icon - App Store.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "1280x768"},
            {"filename": "App Icon.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "400x240"},
            {"filename": "Top Shelf Image Wide.imageset", "idiom": "tv", "role": "top-shelf-image-wide", "size": "2320x720"},
            {"filename": "Top Shelf Image.imageset", "idiom": "tv", "role": "top-shelf-image", "size": "1920x720"},
        ],
        "info": INFO,
    })
    write_json(OUT.parent, {"info": INFO})
    print(f"Wrote {OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
