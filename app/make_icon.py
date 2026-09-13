"""Generate AppIcon.icns: dark rounded square with a cursor arrow and a phone."""
import subprocess, tempfile, pathlib, sys
from PIL import Image, ImageDraw

def draw(size):
    S = 1024
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    m = 90  # macOS icon margin
    d.rounded_rectangle((m, m, S - m, S - m), radius=200, fill=(28, 32, 41, 255))
    # subtle gradient overlay
    ov = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    od = ImageDraw.Draw(ov)
    for i in range(S - 2 * m):
        a = int(70 * (1 - i / (S - 2 * m)))
        od.line((m, m + i, S - m, m + i), fill=(79, 140, 255, a))
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle((m, m, S - m, S - m), radius=200, fill=255)
    img.paste(Image.alpha_composite(img, ov), (0, 0), mask)
    d = ImageDraw.Draw(img)
    # phone outline
    d.rounded_rectangle((300, 250, 560, 780), radius=50, outline=(140, 160, 200, 255), width=22)
    d.rounded_rectangle((330, 300, 530, 700), radius=14, fill=(40, 46, 60, 255))
    # cursor arrow
    ox, oy, k = 500, 430, 3.4
    pts = [(0, 0), (0, 92), (24, 70), (44, 116), (66, 106), (46, 62), (78, 60)]
    pts = [(ox + x * k, oy + y * k) for x, y in pts]
    d.polygon(pts, fill=(255, 255, 255, 255), outline=(30, 34, 44, 255), width=8)
    return img.resize((size, size), Image.LANCZOS)

out = pathlib.Path(sys.argv[1])
with tempfile.TemporaryDirectory() as t:
    iconset = pathlib.Path(t) / "AppIcon.iconset"
    iconset.mkdir()
    for s in (16, 32, 64, 128, 256, 512, 1024):
        draw(s).save(iconset / f"icon_{s}x{s}.png")
        if s <= 512:
            draw(s * 2).save(iconset / f"icon_{s}x{s}@2x.png")
    subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(out)], check=True)
print("icon written", out)
