#!/usr/bin/env python3
"""Generate App Store screenshot slide HTML for Dionysus Player.

Takes raw device screenshots (named by SLIDES below) plus a target device
spec, and produces one self-contained HTML file per slide: brand-gradient
background, a CSS-drawn device frame, and a headline/subcopy pair. Render
each file to a PNG with shot.swift to get the final store-ready image.

See Scripts/render-store-screenshots.sh for the usual entry point — this
script is normally invoked by that wrapper, not run directly.
"""
import math
import os, sys

# Brand palette, straight from DionysusPlayer/Shared/BrandColors.swift.
# Update these if that palette changes.
MAGENTA = "#D60D66"
ROSE_GOLD = "#F2A38C"

# Per-slide background: same magenta/burgundy hue family, lightness walks
# down the set so the slides read as one series rather than unrelated
# posters. Add a tuple here if you add a slide.
BACKDROPS = [
    ("#630C33", "#1C010C"),
    ("#590A2D", "#180109"),
    ("#4F0928", "#150008"),
    ("#450722", "#120007"),
    ("#3B061D", "#0F0005"),
    ("#320519", "#0C0004"),
]

# Each slide's source screenshot (relative to the raw screenshots dir passed
# on the command line), headline (HTML allowed, e.g. <br>), subcopy, and
# whether the source was captured with the device rotated to landscape
# (e.g. the player) — landscape slides get a wider frame that isn't pinned
# to the top of the canvas, since the frame itself is much shorter.
SLIDES = [
    dict(shot="01-home.png",      head="A native home<br>for your library",    sub="Built for iPhone and iPad",                land=False),
    dict(shot="02-grid.png",      head="Find it in seconds",                    sub="Genre, studio, decade — stacked",          land=False),
    dict(shot="03-detail.png",    head="Know before<br>you press play",         sub="Cast, ratings and every detail",           land=False),
    dict(shot="04-player.png",    head="Plays what<br>others can't",            sub="Dolby Vision · HDR10 · Atmos passthrough", land=True),
    dict(shot="05-downloads.png", head="Downloads that<br>just work",           sub="One tap, and it’s ready to watch offline", land=False),
    dict(shot="06-light.png",     head="Light or dark,<br>it just fits",        sub="Follows your system appearance",           land=False),
]


# The Apple TV set: the same series look at 1920x1080, with no device frame
# (a TV screenshot is the whole screen). Captures are tvOS Simulator
# screenshots, any 16:9 size.
TV_SLIDES = [
    dict(shot="01-home.png",          head="Your library, on the big screen",              sub="A native Jellyfin app for Apple TV"),
    dict(shot="02-grid.png",          head="Find it in seconds",                          sub="Genre, studio, decade — stacked"),
    dict(shot="03-movie.png",         head="Every detail, at a glance",                   sub="Cast, ratings and where you left off"),
    dict(shot="04-show.png",          head="Episode by episode",                          sub="Pick up the next one in a click"),
    dict(shot="05-player.png",        head="Plays what others can’t",                     sub="Dolby Vision · HDR10+ · Dolby Atmos · DTS:X"),
    dict(shot="06-search.png",        head="Ask for it by name",                          sub="Movies, shows and episodes as you type"),
    dict(shot="07-whos-watching.png", head="A profile for everyone",                      sub="Who’s Watching? for the whole household"),
]


# The iPhone Duo set (one APP_IPHONE_DUO set takes both displays). Each
# slide names the display and how the phone was held when it was captured:
# "wide" is the inner display held wide (open flat or book, 2853x2007),
# "tall" the inner display held tall (tabletop, 2007x2853), "outer" the
# closed phone (1398x2034). The canvas takes the capture's shape, so a slide
# renders at the size of the display it shows.
DUO_SLIDES = [
    dict(shot="01-spread.png",          held="wide",  head="Every title,<br>a two-page spread",  sub="Designed for iPhone Duo"),
    dict(shot="02-tabletop-player.png", held="tall",  pose="tabletop", head="Stand it up<br>and watch",          sub="Picture up top, controls below the fold"),
    dict(shot="03-tabletop-home.png",   held="tall",  pose="tabletop", head="Your library,<br>folded just right", sub="The fold falls in the gap"),
    dict(shot="04-grid.png",            held="wide",  pose="book", head="Find it in seconds",                sub="Genre, studio, decade — stacked"),
    dict(shot="05-settings.png",        held="wide",  head="Settings,<br>side by side",          sub="List and detail on one screen"),
    dict(shot="06-closed-home.png",     held="outer", head="Closed, it’s all<br>still here",     sub="The whole app on the outer display"),
]

DUO_SIZES = {"wide": (2853, 2007), "tall": (2007, 2853), "outer": (1398, 2034)}

# The closed phone's outer display, from the Simulator's device profile
# (/Library/Developer/CoreSimulator/Profiles/DeviceTypes/iPhone Duo.simdevicetype,
# capabilities.plist): 466x678pt, its corners 8pt on the hinge side (left)
# and 59pt on the other. The camera sits at the top of the vertical status
# bar, centred in the gap the system leaves above the clock, as wide as the
# status ring below it; centre and diameter in the capture's pixels
# (1398x2034), measured from the clock, the ring and the pill's top edge.
OUTER_PT_W = 466
OUTER_HINGE_R, OUTER_EDGE_R = 8, 59
OUTER_CAMERA = dict(x=1254, y=160, d=123)


def build_duo(idx, slide, outdir):
    """An iPhone Duo slide: the series backdrop and copy over a CSS-drawn
    Duo. The open phone gets a faint crease down (held wide) or across
    (held tall) its middle, where the fold is, so it reads as a foldable
    without drawing anything the app doesn't show."""
    held = slide["held"]
    W, H = DUO_SIZES[held]
    c1, c2 = BACKDROPS[idx % len(BACKDROPS)]
    sw, sh = DUO_SIZES[held]
    # Sized so the copy and the phone both fit with room to breathe: by
    # width held wide, by height on the portrait canvases, where a
    # width-led phone ran off the bottom.
    if held == "wide":
        dev_w = round(W * 0.66)
        dev_h = round(dev_w * sh / sw)
        head_size, sub_size = round(H * 0.058), round(H * 0.028)
    else:
        dev_h = round(H * 0.655)
        dev_w = round(dev_h * sw / sh)
        head_size, sub_size = round(W * 0.082), round(W * 0.037)
    radius = round(min(dev_w, dev_h) * 0.06)
    bezel = round(min(dev_w, dev_h) * 0.022)
    inner = radius - bezel
    # CSS border-radius order: top-left, top-right, bottom-right, bottom-left.
    dev_r, img_r, camera = f"{radius}px", f"{inner}px", ""
    if held == "outer":
        k = (dev_w - 2 * bezel) / OUTER_PT_W
        hinge, edge = round(OUTER_HINGE_R * k), round(OUTER_EDGE_R * k)
        img_r = f"{hinge}px {edge}px {edge}px {hinge}px"
        dev_r = f"{hinge + bezel}px {edge + bezel}px {edge + bezel}px {hinge + bezel}px"
        # Mapped as the img's object-fit:cover maps the capture, so the
        # camera stays on the status bar whatever the frame's rounding.
        sw_px, sh_px = dev_w - 2 * bezel, dev_h - 2 * bezel
        s = max(sw_px / sw, sh_px / sh)
        ox, oy = (sw_px - sw * s) / 2, (sh_px - sh * s) / 2
        d = OUTER_CAMERA["d"] * s
        camera = (f'<div class="camera" style="width:{d:.1f}px;height:{d:.1f}px;'
                  f'left:{bezel + ox + OUTER_CAMERA["x"] * s - d / 2:.1f}px;'
                  f'top:{bezel + oy + OUTER_CAMERA["y"] * s - d / 2:.1f}px"></div>')
    if held == "wide":
        crease = (f'<div class="crease" style="left:50%;top:{bezel}px;bottom:{bezel}px;width:{max(3, round(dev_w*0.0016))}px;'
                  f'transform:translateX(-50%);background:linear-gradient(90deg,rgba(0,0,0,.30),rgba(255,255,255,.16),rgba(0,0,0,.30))"></div>')
    elif held == "tall":
        crease = (f'<div class="crease" style="top:50%;left:{bezel}px;right:{bezel}px;height:{max(3, round(dev_h*0.0016))}px;'
                  f'transform:translateY(-50%);background:linear-gradient(180deg,rgba(0,0,0,.30),rgba(255,255,255,.16),rgba(0,0,0,.30))"></div>')
    else:
        crease = ""
    if held == "wide":
        copy = f'<div class="copy wide"><div><div class="rule"></div><h1>{slide["head"]}</h1></div><p>{slide["sub"]}</p></div>'
        layout = f"justify-content:center;padding-top:{round(H*0.02)}px"
    else:
        copy = f'<div class="copy"><div class="rule"></div><h1>{slide["head"]}</h1><p>{slide["sub"]}</p></div>'
        layout = f"justify-content:space-between;padding-bottom:{round(H*0.045)}px"

    html = f'''<!doctype html>
<html><head><meta charset="utf-8"><style>
  *{{margin:0;padding:0;box-sizing:border-box}}
  body{{
    width:{W}px;height:{H}px;overflow:hidden;position:relative;
    background:
      radial-gradient(ellipse 80% 60% at 50% 92%, rgba(214,13,102,.42), transparent 70%),
      linear-gradient(163deg, {c1} 0%, {c2} 68%, #0B0004 100%);
    font-family:-apple-system,"SF Pro Display","Helvetica Neue",sans-serif;
    display:flex;flex-direction:column;align-items:center;{layout};
  }}
  body::after{{
    content:"";position:absolute;left:50%;top:{round(H*0.40)}px;transform:translateX(-50%);
    width:{round(max(W, H)*0.9)}px;height:{round(max(W, H)*0.75)}px;border-radius:50%;
    background:radial-gradient(circle, rgba(240,140,0,.14), transparent 65%);
    pointer-events:none;
  }}
  .copy{{text-align:center;padding:{round(H*0.055)}px {round(W*0.075)}px 0;position:relative;z-index:2}}
  .copy.wide{{width:{dev_w}px;padding:0 0 {round(H*0.04)}px;text-align:left;
    display:flex;align-items:flex-end;justify-content:space-between;gap:{round(W*0.03)}px}}
  .rule{{
    width:{round(min(W, H)*0.115)}px;height:{max(8,round(min(W, H)*0.0075))}px;margin:0 auto {round(min(W, H)*0.035)}px;
    border-radius:99px;background:linear-gradient(90deg,{MAGENTA},{ROSE_GOLD});
  }}
  .copy.wide .rule{{margin:0 0 {round(H*0.025)}px}}
  .copy h1{{font-size:{head_size}px;font-weight:800;line-height:1.08;color:#fff;letter-spacing:-{round(head_size*0.022)}px}}
  .copy p{{font-size:{sub_size}px;font-weight:500;line-height:1.3;margin-top:{round(min(W, H)*0.025)}px;color:rgba(255,255,255,.74)}}
  .copy.wide p{{text-align:right;margin:0;padding-bottom:{round(H*0.008)}px}}
  .device{{
    width:{dev_w}px;height:{dev_h}px;border-radius:{dev_r};padding:{bezel}px;
    position:relative;background:#0C0C10;z-index:1;
    box-shadow:0 {round(H*0.03)}px {round(H*0.08)}px rgba(0,0,0,.55),
               inset 0 0 0 {max(3,round(min(W, H)*0.0035))}px #3A3A40;
  }}
  .device img{{width:100%;height:100%;object-fit:cover;display:block;border-radius:{img_r}}}
  .crease{{position:absolute;z-index:2;pointer-events:none}}
  .camera{{position:absolute;z-index:2;border-radius:50%;
    background:radial-gradient(circle at 38% 36%, #2A3140 0, #0A0C12 34%, #000 62%)}}
</style></head>
<body>
  {copy}
  <div class="device"><img src="./{slide["shot"]}">{crease}{camera}</div>
</body></html>'''
    if slide.get("pose") in ("book", "tabletop"):
        html = html.replace(
            f'<div class="device"><img src="./{slide["shot"]}">{crease}</div>',
            folded_device(slide["pose"], slide["shot"], dev_w, dev_h, radius, bezel, W, H, outdir, idx))
    path = os.path.join(outdir, f"slide{idx + 1}.html")
    with open(path, "w") as f:
        f.write(html)
    return path, W, H


# The folded poses. Book: each half turns BOOK_ANGLE toward the viewer about
# the vertical fold. Tabletop: the top half leans back TABLETOP_BACK, the
# bottom half tips TABLETOP_BASE toward the viewer, like a laptop's base, and
# the eye sits a little above. Angles in degrees; the eye's distance is in
# multiples of the phone's longer side.
BOOK_ANGLE = 24
TABLETOP_BACK = 10
TABLETOP_BASE = 50
FOLD_EYE = 2.2


def _solve(m, v):
    """Gaussian elimination for the small linear systems _perspective needs."""
    n = len(v)
    a = [row[:] + [v[i]] for i, row in enumerate(m)]
    for c in range(n):
        p = max(range(c, n), key=lambda r: abs(a[r][c]))
        a[c], a[p] = a[p], a[c]
        for r in range(n):
            if r != c:
                f = a[r][c] / a[c][c]
                a[r] = [x - f * y for x, y in zip(a[r], a[c])]
    return [a[i][n] / a[i][i] for i in range(n)]


def _perspective(dst, src):
    """Pillow's PERSPECTIVE coefficients mapping each dst corner to its src."""
    m, v = [], []
    for (x, y), (u, w) in zip(dst, src):
        m.append([x, y, 1, 0, 0, 0, -u * x, -u * y]); v.append(u)
        m.append([0, 0, 0, x, y, 1, -w * x, -w * y]); v.append(w)
    return _solve(m, v)


def folded_device(pose, shot, dev_w, dev_h, radius, bezel, W, H, outdir, idx):
    """The open phone partly folded, in book pose (held wide, folded about
    the vertical fold) or tabletop (held tall, standing on its bottom half),
    the two halves seen in perspective. WKWebView's snapshot flattens CSS 3D
    transforms to 2D, so the projection is done here with Pillow and the
    slide shows the result as an image. Each half carries its own half of
    the one capture, so the screen is still the app's real pixels; the
    shading only darkens it toward the fold, as a page does in a book."""
    from PIL import Image, ImageDraw
    k = 2  # drawn at twice the size, then downscaled, for smooth edges
    w, h, r, b = dev_w * k, dev_h * k, radius * k, bezel * k
    book = pose == "book"
    flat = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(flat)
    d.rounded_rectangle([0, 0, w - 1, h - 1], r, fill=(12, 12, 16, 255),
                        outline=(58, 58, 64, 255), width=max(3, round(min(w, h) * 0.0035)))
    screen = Image.open(os.path.join(outdir, shot)).convert("RGBA").resize((w - 2 * b, h - 2 * b), Image.LANCZOS)
    mask = Image.new("L", screen.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, screen.width - 1, screen.height - 1], r - b, fill=255)
    flat.paste(screen, (b, b), mask)
    # Shading: each half darkens toward the fold, the first more than the second.
    length = w if book else h
    half = length // 2
    shade = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shade)
    for i in range(length):
        t = abs(i - half) / half  # 0 at the fold, 1 at the outer edge
        a = round(80 * max(0.0, 1 - t / 0.5) ** 2) if i < half else round(50 * max(0.0, 1 - t / 0.4) ** 2)
        sd.line([(i, 0), (i, h)] if book else [(0, i), (w, i)], fill=(0, 0, 0, a))
    flat = Image.alpha_composite(flat, Image.composite(shade, Image.new("RGBA", (w, h)), flat.getchannel("A")))

    # Each half in 3D, the fold through the origin, z toward the eye.
    eye = FOLD_EYE * max(w, h)
    eye_y = 0 if book else -0.35 * h  # tabletop is seen from a little above
    def proj(x, y, z):
        s = eye / (eye - z)
        return x * s, eye_y + (y - eye_y) * s
    pages = []
    if book:
        th = math.radians(BOOK_ANGLE)
        for side in (-1, 1):
            ox, oz = side * half * math.cos(th), half * math.sin(th)
            quad = [proj(0, -h / 2, 0), proj(ox, -h / 2, oz), proj(ox, h / 2, oz), proj(0, h / 2, 0)]
            src = ([(half, 0), (0, 0), (0, h), (half, h)] if side < 0
                   else [(0, 0), (half, 0), (half, h), (0, h)])
            pages.append((quad, src, flat.crop((0, 0, half, h) if side < 0 else (half, 0, w, h))))
    else:
        back, base = math.radians(TABLETOP_BACK), math.radians(TABLETOP_BASE)
        ty, tz = -half * math.cos(back), -half * math.sin(back)
        by, bz = half * math.cos(base), half * math.sin(base)
        top = [proj(-w / 2, ty, tz), proj(w / 2, ty, tz), proj(w / 2, 0, 0), proj(-w / 2, 0, 0)]
        bottom = [proj(-w / 2, 0, 0), proj(w / 2, 0, 0), proj(w / 2, by, bz), proj(-w / 2, by, bz)]
        corners = [(0, 0), (w, 0), (w, half), (0, half)]
        pages.append((top, corners, flat.crop((0, 0, w, half))))
        pages.append((bottom, corners, flat.crop((0, half, w, h))))
    xs = [x for q, _, _ in pages for x, _ in q]
    ys = [y for q, _, _ in pages for _, y in q]
    minx, miny = min(xs), min(ys)
    cw, ch = math.ceil(max(xs) - minx), math.ceil(max(ys) - miny)
    out = Image.new("RGBA", (cw, ch), (0, 0, 0, 0))
    for quad, src, crop in pages:
        dst = [(x - minx, y - miny) for x, y in quad]
        warped = crop.transform((cw, ch), Image.PERSPECTIVE, _perspective(dst, src), Image.BICUBIC)
        out = Image.alpha_composite(out, warped)
    # Held wide, as wide as the flat phone. Held tall, no taller than it,
    # and as wide as the canvas allows: tabletop is shorter than the flat
    # phone, and its widening base is what limits it.
    scale = dev_w / cw if book else min(dev_h / ch, W * 0.86 / cw)
    out = out.resize((round(cw * scale), round(ch * scale)), Image.LANCZOS)
    name = f"slide{idx + 1}-{pose}.png"
    out.save(os.path.join(outdir, name))
    return (f'<div style="position:relative;z-index:1;width:{out.width}px;height:{out.height}px">'
            f'<div style="position:absolute;left:6%;right:6%;bottom:-{round(dev_h*0.05)}px;height:{round(dev_h*0.1)}px;'
            f'border-radius:50%;background:radial-gradient(ellipse at center, rgba(0,0,0,.6), transparent 70%);'
            f'filter:blur({round(dev_h*0.02)}px)"></div>'
            f'<img src="./{name}" style="position:relative;width:100%;height:100%;display:block"></div>')


def build_tv(idx, slide, W, H, outdir):
    """An Apple TV slide: headline top left, the capture large and low."""
    c1, c2 = BACKDROPS[idx % len(BACKDROPS)]
    shot_w = round(W * 0.78)
    shot_h = round(shot_w * 9 / 16)
    shot_top = H - shot_h - round(H * 0.045)
    left = round((W - shot_w) / 2)
    head_size, sub_size = round(H * 0.058), round(H * 0.028)
    radius = round(W * 0.012)

    html = f'''<!doctype html>
<html><head><meta charset="utf-8"><style>
  *{{margin:0;padding:0;box-sizing:border-box}}
  body{{
    width:{W}px;height:{H}px;overflow:hidden;position:relative;
    background:
      radial-gradient(ellipse 70% 60% at 50% 95%, rgba(214,13,102,.42), transparent 70%),
      linear-gradient(163deg, {c1} 0%, {c2} 68%, #0B0004 100%);
    font-family:-apple-system,"SF Pro Display","Helvetica Neue",sans-serif;
  }}
  body::after{{
    content:"";position:absolute;left:50%;top:{round(H*0.35)}px;transform:translateX(-50%);
    width:{round(W*0.95)}px;height:{round(H*0.95)}px;border-radius:50%;
    background:radial-gradient(circle, rgba(240,140,0,.14), transparent 65%);
    pointer-events:none;
  }}
  .copy{{position:absolute;left:{left}px;right:{left}px;top:{round(H*0.045)}px;z-index:2;
    display:flex;align-items:flex-end;justify-content:space-between;gap:{round(W*0.03)}px;
    height:{shot_top - round(H*0.045) - round(H*0.035)}px}}
  .rule{{
    width:{round(W*0.045)}px;height:{max(6,round(H*0.0075))}px;margin-bottom:{round(H*0.018)}px;
    border-radius:99px;background:linear-gradient(90deg,{MAGENTA},{ROSE_GOLD});
  }}
  .copy h1{{
    font-size:{head_size}px;font-weight:800;line-height:1.08;color:#fff;
    letter-spacing:-{round(head_size*0.02)}px;
  }}
  .copy p{{
    font-size:{sub_size}px;font-weight:500;line-height:1.3;text-align:right;
    color:rgba(255,255,255,.74);padding-bottom:{round(H*0.006)}px;
  }}
  .screen{{
    position:absolute;left:{left}px;top:{shot_top}px;width:{shot_w}px;height:{shot_h}px;
    border-radius:{radius}px;overflow:hidden;z-index:1;
    box-shadow:0 {round(H*0.03)}px {round(H*0.08)}px rgba(0,0,0,.55),
               0 0 0 {max(2,round(W*0.001))}px rgba(255,255,255,.10);
  }}
  .screen img{{width:100%;height:100%;object-fit:cover;display:block}}
</style></head>
<body>
  <div class="copy"><div><div class="rule"></div><h1>{slide["head"]}</h1></div><p>{slide["sub"]}</p></div>
  <div class="screen"><img src="./{slide["shot"]}"></div>
</body></html>'''
    path = os.path.join(outdir, f"slide{idx + 1}.html")
    with open(path, "w") as f:
        f.write(html)
    return path


def frame_portrait(w, shot, kind):
    """Portrait device frame drawn in CSS."""
    if kind == "ipad":
        h = round(w * 2752 / 2064)
        radius, bezel = round(w * 0.048), round(w * 0.026)
        island = ""
    else:
        h = round(w * 2868 / 1320)
        radius, bezel = round(w * 0.143), round(w * 0.024)
        iw, ih, itop = round(w * 0.267), round(w * 0.077), round(w * 0.051)
        island = f'<div class="island" style="width:{iw}px;height:{ih}px;top:{itop}px;border-radius:{ih//2}px"></div>'
    inner = radius - bezel
    return f'''<div class="device" style="width:{w}px;height:{h}px;border-radius:{radius}px;padding:{bezel}px">
      <img src="./{shot}" style="border-radius:{inner}px">{island}
    </div>'''


def frame_landscape(w, shot, kind):
    """Landscape device frame — same physical radii, rotated 90 degrees."""
    if kind == "ipad":
        h = round(w * 2064 / 2752)
        radius, bezel = round(h * 0.048), round(h * 0.026)
        island = ""
    else:
        h = round(w * 1320 / 2868)
        radius, bezel = round(h * 0.143), round(h * 0.024)
        iw, ih, ileft = round(h * 0.077), round(h * 0.267), round(h * 0.051)
        island = f'<div class="island-l" style="width:{iw}px;height:{ih}px;left:{ileft}px;border-radius:{iw//2}px"></div>'
    inner = radius - bezel
    return f'''<div class="device" style="width:{w}px;height:{h}px;border-radius:{radius}px;padding:{bezel}px">
      <img src="./{shot}" style="border-radius:{inner}px">{island}
    </div>'''


def build(idx, slide, kind, W, H, outdir):
    c1, c2 = BACKDROPS[idx % len(BACKDROPS)]
    tilt = -1.6 if idx % 2 == 0 else 1.6

    if kind == "ipad":
        head_size, sub_size = round(W * 0.062), round(W * 0.029)
        copy_top = round(H * 0.070)
        dev_w_port, dev_w_land = round(W * 0.760), round(W * 0.940)
        dev_top = round(H * 0.045)
    else:
        head_size, sub_size = round(W * 0.089), round(W * 0.039)
        copy_top = round(H * 0.075)
        dev_w_port, dev_w_land = round(W * 0.780), round(W * 0.960)
        dev_top = round(H * 0.055)

    if slide["land"]:
        # The landscape frame is much shorter than the canvas is tall, so
        # centre it in the remaining space below the copy rather than
        # pinning it to a fixed offset (which leaves a dead gap underneath).
        dev = f'<div class="stage">{frame_landscape(dev_w_land, slide["shot"], kind)}</div>'
        dev_top = 0
    else:
        dev = frame_portrait(dev_w_port, slide["shot"], kind)

    html = f'''<!doctype html>
<html><head><meta charset="utf-8"><style>
  *{{margin:0;padding:0;box-sizing:border-box}}
  body{{
    width:{W}px;height:{H}px;overflow:hidden;position:relative;
    background:
      radial-gradient(ellipse 85% 55% at 50% 88%, rgba(214,13,102,.42), transparent 70%),
      linear-gradient(163deg, {c1} 0%, {c2} 68%, #0B0004 100%);
    font-family:-apple-system,"SF Pro Display","Helvetica Neue",sans-serif;
    display:flex;flex-direction:column;align-items:center;
  }}
  /* soft brand glow behind the device so it lifts off the background */
  body::after{{
    content:"";position:absolute;left:50%;top:{round(H*0.46)}px;transform:translateX(-50%);
    width:{round(W*1.05)}px;height:{round(W*0.85)}px;border-radius:50%;
    background:radial-gradient(circle, rgba(240,140,0,.16), transparent 65%);
    pointer-events:none;
  }}
  .copy{{margin-top:{copy_top}px;text-align:center;padding:0 {round(W*0.075)}px;position:relative;z-index:2}}
  .rule{{
    width:{round(W*0.115)}px;height:{max(8,round(W*0.0075))}px;margin:0 auto {round(W*0.040)}px;
    border-radius:99px;background:linear-gradient(90deg,{MAGENTA},{ROSE_GOLD});
  }}
  .copy h1{{
    font-size:{head_size}px;font-weight:800;line-height:1.10;color:#fff;
    letter-spacing:-{round(head_size*0.022)}px;
  }}
  .copy p{{
    font-size:{sub_size}px;font-weight:500;line-height:1.32;margin-top:{round(W*0.028)}px;
    color:rgba(255,255,255,.74);
  }}
  .device{{
    margin-top:{dev_top}px;position:relative;background:#0C0C10;
    box-shadow:0 {round(W*0.045)}px {round(W*0.105)}px rgba(0,0,0,.55),
               inset 0 0 0 {max(3,round(W*0.0035))}px #3A3A40;
    transform:rotate({tilt}deg);z-index:1;
  }}
  .stage{{flex:1;width:100%;display:flex;align-items:center;justify-content:center}}
  .device img{{width:100%;height:100%;object-fit:cover;object-position:top;display:block}}
  .island{{position:absolute;left:50%;transform:translateX(-50%);background:#000}}
  .island-l{{position:absolute;top:50%;transform:translateY(-50%);background:#000}}
</style></head>
<body>
  <div class="copy"><div class="rule"></div><h1>{slide["head"]}</h1><p>{slide["sub"]}</p></div>
  {dev}
</body></html>'''
    path = os.path.join(outdir, f"slide{idx + 1}.html")
    with open(path, "w") as f:
        f.write(html)
    return path


if __name__ == "__main__":
    if len(sys.argv) != 6:
        print("usage: gen.py <iphone|ipad|appletv> <width> <height> <outdir> <slide-index|all>",
              file=sys.stderr)
        sys.exit(2)
    kind, W, H, outdir, only = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4], sys.argv[5]
    if kind == "duo":
        # Each slide's size follows its capture (DUO_SIZES), so the width and
        # height arguments are ignored; each line prints "path width height".
        os.makedirs(outdir, exist_ok=True)
        idxs = range(len(DUO_SLIDES)) if only == "all" else [int(only)]
        for i in idxs:
            print(*build_duo(i, DUO_SLIDES[i], outdir))
        sys.exit(0)
    os.makedirs(outdir, exist_ok=True)
    slides = TV_SLIDES if kind == "appletv" else SLIDES
    idxs = range(len(slides)) if only == "all" else [int(only)]
    for i in idxs:
        if kind == "appletv":
            print(build_tv(i, slides[i], W, H, outdir))
        else:
            print(build(i, slides[i], kind, W, H, outdir))
