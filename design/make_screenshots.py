"""Composes App Store screenshots (6.9" iPhone, 1320×2868) from the raw captures in design/raw.
Run: python3 design/make_screenshots.py  →  design/appstore/*.png"""
from PIL import Image, ImageDraw, ImageFont, ImageFilter
import os

W, H = 1320, 2868
RAW, OUT = "design/raw", "design/appstore"
os.makedirs(OUT, exist_ok=True)
FONT = "/System/Library/Fonts/SFNS.ttf"

def font(size, weight=700):
    f = ImageFont.truetype(FONT, size)
    try:
        # Axes: Width, Optical Size, GRAD, Weight.
        f.set_variation_by_axes([100, min(96, size), 400, weight])
    except Exception:
        pass
    return f

def background():
    img = Image.new("RGB", (W, H))
    d = ImageDraw.Draw(img)
    top, bottom = (21, 36, 70), (8, 10, 16)
    for y in range(H):
        t = y / (H - 1)
        d.line([(0, y), (W, y)], fill=tuple(round(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
    return img

def wrap(d, text, f, width):
    lines, line = [], ""
    for word in text.split():
        test = (line + " " + word).strip()
        if d.textlength(test, font=f) <= width:
            line = test
        else:
            lines.append(line); line = word
    return lines + [line]

def headline(img, title, sub, y=190):
    d = ImageDraw.Draw(img)
    f1, f2 = font(104, 800), font(50, 500)
    for line in wrap(d, title, f1, W - 160):
        d.text((W / 2, y), line, font=f1, fill="white", anchor="ma"); y += 124
    y += 26
    for line in wrap(d, sub, f2, W - 200):
        d.text((W / 2, y), line, font=f2, fill=(168, 184, 208), anchor="ma"); y += 66
    return y

def rounded(im, r):
    mask = Image.new("L", im.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, im.width - 1, im.height - 1], r, fill=255)
    out = Image.new("RGBA", im.size); out.paste(im, mask=mask)
    return out

def place(img, shot, box_w, y, radius, bezel=18):
    """Put a screenshot in a dark bezel with a soft shadow, centred horizontally at y."""
    s = shot.resize((box_w, round(shot.height * box_w / shot.width)), Image.LANCZOS)
    fw, fh = s.width + 2 * bezel, s.height + 2 * bezel
    x = (W - fw) // 2
    shadow = Image.new("L", img.size, 0)
    ImageDraw.Draw(shadow).rounded_rectangle([x, y + 30, x + fw, y + fh + 30], radius + bezel, fill=170)
    img.paste((0, 0, 0), mask=shadow.filter(ImageFilter.GaussianBlur(40)))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([x, y, x + fw, y + fh], radius + bezel, fill=(12, 14, 19), outline=(52, 60, 74), width=3)
    img.paste(rounded(s, radius), (x + bezel, y + bezel), rounded(s, radius))
    return y + fh

def chips(img, labels, y):
    d = ImageDraw.Draw(img); f = font(40, 600)
    widths = [d.textlength(l, font=f) + 70 for l in labels]
    x = (W - sum(widths) - 24 * (len(labels) - 1)) / 2
    for l, w in zip(labels, widths):
        d.rounded_rectangle([x, y, x + w, y + 84], 42, fill=(30, 40, 58), outline=(62, 139, 255), width=2)
        d.text((x + w / 2, y + 42), l, font=f, fill="white", anchor="mm")
        x += w + 24

def car_slide(name, raw, title, sub, callouts, labels):
    """Full car screen, then enlarged callouts of the UI that matters, then feature chips."""
    img = background()
    y = headline(img, title, sub) + 70
    shot = Image.open(f"{RAW}/{raw}").convert("RGB")
    y = place(img, shot, 1240, y, 22, bezel=14) + 70
    for box, width in callouts:
        y = place(img, shot.crop(box), width, y, 30, bezel=10) + 44
    chips(img, labels, y + 50)
    img.save(f"{OUT}/{name}.png")

BANNER, TRIP = (16, 16, 496, 222), (16, 1080, 496, 1172)
car_slide("1-navigation", "nav.png", "Turn-by-turn on your car's big screen",
          "A heading-up 3D map with voice prompts, using the car's own GPS.",
          [(BANNER, 1000), (TRIP, 1000)], ["Heading-up", "Voice", "Rerouting", "ETA"])
car_slide("2-search", "search.png", "Finds places the way you type them",
          "Type in English, Russian or Armenian: kaskad, cascade or Каскад all find the Cascade.",
          [((16, 16, 496, 700), 900)], ["Places", "Streets", "Addresses"])
car_slide("3-route", "overview.png", "See the whole route, then just drive",
          "Arrival time, distance and the next turn, always in view.",
          [((16, 16, 496, 138), 1000), (TRIP, 1000)], ["Route overview", "Night map"])

# The iPhone app: mirroring.
img = background()
y = headline(img, "Live traffic? Mirror your iPhone", "Use Yandex, Google Maps or Waze on the car screen. Pair once with a code.")
phone = Image.open(f"{RAW}/phone.png").convert("RGB").crop((0, 0, 1320, 2380))
place(img, phone, 1040, y + 90, 100, bezel=28)
img.save(f"{OUT}/4-mirror.png")

car_slide("5-chargers", "chargers.png", "EV chargers on the map",
          "Tap a charger to see its connectors and drive there.",
          [((380, 150, 1540, 900), 1100)], ["Free", "No account", "No ads"])

# 6.5" copies (1284×2778): App Store Connect asks for this size too.
os.makedirs("design/appstore-6.5", exist_ok=True)
for f in sorted(os.listdir(OUT)):
    Image.open(f"{OUT}/{f}").convert("RGB").resize((1284, 2790), Image.LANCZOS).crop((0, 6, 1284, 2784)).save(f"design/appstore-6.5/{f}")
print(sorted(os.listdir(OUT)))
