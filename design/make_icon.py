"""Draws the TeslaNav app icon (1024×1024, no alpha). Run: python3 design/make_icon.py"""
from PIL import Image, ImageDraw, ImageFilter
import math

S = 4096                      # draw at 4× and downsample for smooth edges
img = Image.new("RGB", (S, S))
px = img.load()
# Night-sky vertical gradient.
top, bottom = (22, 38, 74), (6, 9, 18)
for y in range(S):
    t = y / (S - 1)
    c = tuple(round(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
    for x in range(S):
        px[x, y] = c

d = ImageDraw.Draw(img)

# A road sweeping up towards the horizon, drawn as a thick curve.
def curve(t):
    # quadratic bezier from bottom-left to upper-right
    p0, p1, p2 = (0.18 * S, 1.05 * S), (0.42 * S, 0.55 * S), (0.92 * S, 0.38 * S)
    x = (1 - t) ** 2 * p0[0] + 2 * (1 - t) * t * p1[0] + t ** 2 * p2[0]
    y = (1 - t) ** 2 * p0[1] + 2 * (1 - t) * t * p1[1] + t ** 2 * p2[1]
    return x, y

road = Image.new("L", (S, S), 0)
rd = ImageDraw.Draw(road)
pts = [curve(i / 200) for i in range(201)]
for i, (x, y) in enumerate(pts):
    w = 0.16 * S * (1 - 0.75 * i / 200)        # narrows with distance
    rd.ellipse([x - w / 2, y - w / 2, x + w / 2, y + w / 2], fill=255)
img.paste((30, 44, 70), mask=road)

# Glowing blue route line along the road centre.
glow = Image.new("L", (S, S), 0)
gd = ImageDraw.Draw(glow)
for i, (x, y) in enumerate(pts):
    w = 0.05 * S * (1 - 0.7 * i / 200)
    gd.ellipse([x - w / 2, y - w / 2, x + w / 2, y + w / 2], fill=255)
halo = glow.filter(ImageFilter.GaussianBlur(S * 0.02))
img.paste((62, 139, 255), mask=halo.point(lambda v: int(v * 0.55)))
img.paste((88, 160, 255), mask=glow)

# The navigation arrow (the car marker from the car page), big and centred.
cx, cy, r = 0.5 * S, 0.5 * S, 0.30 * S
shadow = Image.new("L", (S, S), 0)
ImageDraw.Draw(shadow).ellipse([cx - r, cy - r + 0.02 * S, cx + r, cy + r + 0.02 * S], fill=200)
img.paste((0, 0, 0), mask=shadow.filter(ImageFilter.GaussianBlur(S * 0.03)))
d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(62, 139, 255))
ring = 0.045 * S
d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=(255, 255, 255), width=int(ring))

def rot(x, y, a):
    a = math.radians(a)
    x, y = x - cx, y - cy
    return cx + x * math.cos(a) - y * math.sin(a), cy + x * math.sin(a) + y * math.cos(a)

arrow = [(cx, cy - 0.19 * S), (cx + 0.13 * S, cy + 0.15 * S), (cx, cy + 0.07 * S), (cx - 0.13 * S, cy + 0.15 * S)]
d.polygon([rot(x, y, 35) for x, y in arrow], fill=(255, 255, 255))

img.resize((1024, 1024), Image.LANCZOS).save("Sources/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
print("icon written")
