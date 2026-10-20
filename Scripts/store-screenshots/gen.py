#!/usr/bin/env python3
"""Generate App Store screenshot slide HTML for Dionysus Player.

Takes raw device screenshots (named by SLIDES below) plus a target device
spec, and produces one self-contained HTML file per slide: brand-gradient
background, a CSS-drawn device frame, and a headline/subcopy pair. Render
each file to a PNG with shot.swift to get the final store-ready image.

See Scripts/render-store-screenshots.sh for the usual entry point — this
script is normally invoked by that wrapper, not run directly.
"""
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
    os.makedirs(outdir, exist_ok=True)
    slides = TV_SLIDES if kind == "appletv" else SLIDES
    idxs = range(len(slides)) if only == "all" else [int(only)]
    for i in idxs:
        if kind == "appletv":
            print(build_tv(i, slides[i], W, H, outdir))
        else:
            print(build(i, slides[i], kind, W, H, outdir))
