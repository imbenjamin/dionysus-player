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
AMBER = "#F08C00"

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
    dict(shot="01-home.png",      head="Your Jellyfin library,<br>made native", sub="Built for iPhone and iPad",                land=False),
    dict(shot="02-grid.png",      head="Find it in seconds",                    sub="Genre, studio, decade — stacked",          land=False),
    dict(shot="03-detail.png",    head="Know before<br>you press play",         sub="Cast, ratings and every detail",           land=False),
    dict(shot="04-player.png",    head="Plays what<br>others can't",            sub="Dolby Vision · HDR10 · Atmos passthrough", land=True),
    dict(shot="05-downloads.png", head="Downloads that<br>just work",           sub="One tap, and it’s ready to watch offline", land=False),
    dict(shot="06-light.png",     head="Light or dark,<br>it just fits",        sub="Follows your system appearance",           land=False),
]


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
    border-radius:99px;background:linear-gradient(90deg,{MAGENTA},{AMBER});
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
        print("usage: gen.py <iphone|ipad> <width> <height> <outdir> <slide-index|all>",
              file=sys.stderr)
        sys.exit(2)
    kind, W, H, outdir, only = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4], sys.argv[5]
    os.makedirs(outdir, exist_ok=True)
    idxs = range(len(SLIDES)) if only == "all" else [int(only)]
    for i in idxs:
        print(build(i, SLIDES[i], kind, W, H, outdir))
