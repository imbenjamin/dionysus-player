#!/usr/bin/env python3
"""
Find the bounding box (and center) of a UI element inside a Simulator
screenshot, by scanning a region for pixels that differ from a
background color — a poster, a button fill, an icon glyph, a line of
text, anything with real contrast against what's behind it.

This exists because eyeballing coordinates off the Read tool's
*resized* preview is unreliable — see SKILL.md's Gotchas. Always
measure against the real screenshot file instead.

Usage:
  pixel_bbox.py <screenshot.png> <x0> <y0> <x1> <y1> [--bg r,g,b] [--tol N]

  <x0> <y0> <x1> <y1>  a rough region to search, in the screenshot's
                        native pixel coordinates (not the resized
                        preview you were shown) — eyeball this part
                        loosely, it only needs to bracket the element.
  --bg r,g,b            background color to exclude. Default: samples
                        the region's own top-left corner pixel, which
                        works as long as that corner isn't already on
                        the element.
  --tol N               per-channel tolerance for "counts as
                        background" (default 30 — raise it for noisy/
                        gradient backgrounds, lower it for a busy image
                        where the element's color is close to the bg).

Prints: bbox=(left,top)-(right,bottom) center=(cx,cy) bg=(r,g,b)
`center` is what you feed into the screen-coordinate conversion in
SKILL.md.
"""
import sys
import argparse
from PIL import Image


def main():
    p = argparse.ArgumentParser()
    p.add_argument("image")
    p.add_argument("x0", type=int)
    p.add_argument("y0", type=int)
    p.add_argument("x1", type=int)
    p.add_argument("y1", type=int)
    p.add_argument("--bg", default=None, help="r,g,b background to exclude; default: region's top-left pixel")
    p.add_argument("--tol", type=int, default=30, help="per-channel tolerance for 'matches background'")
    args = p.parse_args()

    img = Image.open(args.image)
    px = img.load()
    x0, y0, x1, y1 = args.x0, args.y0, args.x1, args.y1

    bg = tuple(int(c) for c in args.bg.split(",")) if args.bg else px[x0, y0][:3]

    def is_bg(p):
        return all(abs(p[i] - bg[i]) <= args.tol for i in range(3))

    xs, ys = [], []
    for y in range(y0, y1):
        for x in range(x0, x1):
            p = px[x, y][:3]
            if not is_bg(p):
                xs.append(x)
                ys.append(y)

    if not xs:
        print(f"NO_MATCH — nothing in ({x0},{y0})-({x1},{y1}) differs from background {bg} (tol={args.tol})")
        sys.exit(1)

    left, right = min(xs), max(xs)
    top, bottom = min(ys), max(ys)
    cx, cy = (left + right) // 2, (top + bottom) // 2
    print(f"bbox=({left},{top})-({right},{bottom}) center=({cx},{cy}) bg={bg}")


if __name__ == "__main__":
    main()
