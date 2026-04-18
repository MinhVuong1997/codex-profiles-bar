#!/usr/bin/env python3

from __future__ import annotations

import math
import os
import subprocess
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter


ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "Assets"
ICONSET = ASSETS / "AppIcon.iconset"
MASTER = ASSETS / "AppIcon-1024.png"
ICNS = ASSETS / "AppIcon.icns"


def lerp(a: float, b: float, t: float) -> float:
    return a + (b - a) * t


def mix(c1: tuple[int, int, int], c2: tuple[int, int, int], t: float) -> tuple[int, int, int]:
    return tuple(int(lerp(c1[i], c2[i], t)) for i in range(3))


def rounded_box(
    draw: ImageDraw.ImageDraw,
    box: tuple[float, float, float, float],
    radius: float,
    fill: tuple[int, int, int, int],
    outline: tuple[int, int, int, int] | None = None,
    width: int = 1,
) -> None:
    draw.rounded_rectangle(box, radius=radius, fill=fill, outline=outline, width=width)


def draw_gradient_background(image: Image.Image) -> None:
    width, height = image.size
    px = image.load()
    top = (23, 31, 49)
    bottom = (10, 16, 31)
    edge = (44, 56, 86)
    for y in range(height):
        for x in range(width):
            vertical = y / max(height - 1, 1)
            horizontal = abs((x / max(width - 1, 1)) - 0.5) * 2
            base = mix(top, bottom, vertical)
            color = mix(base, edge, horizontal * 0.35)
            px[x, y] = (*color, 255)


def add_glow(base: Image.Image, center: tuple[int, int], radius: int, color: tuple[int, int, int, int]) -> None:
    glow = Image.new("RGBA", base.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(glow)
    cx, cy = center
    draw.ellipse((cx - radius, cy - radius, cx + radius, cy + radius), fill=color)
    glow = glow.filter(ImageFilter.GaussianBlur(radius=radius // 2))
    base.alpha_composite(glow)


def create_master_icon() -> None:
    ASSETS.mkdir(parents=True, exist_ok=True)

    image = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
    mask = Image.new("L", image.size, 0)
    mask_draw = ImageDraw.Draw(mask)
    mask_draw.rounded_rectangle((36, 36, 988, 988), radius=230, fill=255)

    canvas = Image.new("RGBA", image.size, (0, 0, 0, 0))
    draw_gradient_background(canvas)
    add_glow(canvas, (780, 250), 260, (61, 241, 184, 110))
    add_glow(canvas, (340, 820), 250, (48, 121, 255, 80))

    detail = Image.new("RGBA", image.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(detail)

    rounded_box(
        draw,
        (190, 270, 720, 760),
        radius=86,
        fill=(246, 248, 255, 30),
        outline=(255, 255, 255, 52),
        width=5,
    )
    rounded_box(
        draw,
        (300, 170, 834, 660),
        radius=86,
        fill=(246, 248, 255, 42),
        outline=(255, 255, 255, 88),
        width=5,
    )

    for ox, oy in ((330, 255), (220, 355)):
        draw.ellipse((ox, oy, ox + 120, oy + 120), fill=(102, 255, 209, 235))
        draw.rounded_rectangle(
            (ox + 150, oy + 18, ox + 370, oy + 54),
            radius=16,
            fill=(255, 255, 255, 205),
        )
        draw.rounded_rectangle(
            (ox + 150, oy + 74, ox + 315, oy + 104),
            radius=15,
            fill=(172, 186, 225, 180),
        )

    arrow_color = (77, 245, 187, 255)
    arrow_shadow = Image.new("RGBA", image.size, (0, 0, 0, 0))
    shadow_draw = ImageDraw.Draw(arrow_shadow)
    shadow_draw.arc((368, 348, 890, 870), start=212, end=28, fill=(0, 0, 0, 130), width=52)
    shadow_draw.polygon([(790, 360), (902, 350), (828, 436)], fill=(0, 0, 0, 130))
    shadow_draw.arc((138, 138, 660, 660), start=32, end=210, fill=(0, 0, 0, 120), width=52)
    shadow_draw.polygon([(232, 648), (120, 660), (196, 570)], fill=(0, 0, 0, 120))
    shadow_draw = arrow_shadow.filter(ImageFilter.GaussianBlur(radius=12))
    canvas.alpha_composite(shadow_draw)

    draw.arc((368, 348, 890, 870), start=212, end=28, fill=arrow_color, width=44)
    draw.polygon([(790, 360), (902, 350), (828, 436)], fill=arrow_color)
    draw.arc((138, 138, 660, 660), start=32, end=210, fill=(126, 213, 255, 255), width=44)
    draw.polygon([(232, 648), (120, 660), (196, 570)], fill=(126, 213, 255, 255))

    spark = Image.new("RGBA", image.size, (0, 0, 0, 0))
    spark_draw = ImageDraw.Draw(spark)
    for cx, cy, r in ((760, 200, 16), (836, 248, 11), (716, 148, 9), (246, 806, 12)):
        spark_draw.ellipse((cx - r, cy - r, cx + r, cy + r), fill=(255, 255, 255, 210))
    spark = spark.filter(ImageFilter.GaussianBlur(radius=3))
    detail.alpha_composite(spark)

    canvas.alpha_composite(detail)
    image.paste(canvas, mask=mask)

    border = Image.new("RGBA", image.size, (0, 0, 0, 0))
    border_draw = ImageDraw.Draw(border)
    border_draw.rounded_rectangle(
        (36, 36, 988, 988),
        radius=230,
        outline=(255, 255, 255, 48),
        width=6,
    )
    image.alpha_composite(border)
    image.save(MASTER)


def build_iconset() -> None:
    if ICONSET.exists():
        for item in ICONSET.iterdir():
            item.unlink()
    else:
        ICONSET.mkdir(parents=True, exist_ok=True)

    sizes = [
        (16, "icon_16x16.png"),
        (32, "icon_16x16@2x.png"),
        (32, "icon_32x32.png"),
        (64, "icon_32x32@2x.png"),
        (128, "icon_128x128.png"),
        (256, "icon_128x128@2x.png"),
        (256, "icon_256x256.png"),
        (512, "icon_256x256@2x.png"),
        (512, "icon_512x512.png"),
        (1024, "icon_512x512@2x.png"),
    ]

    master = Image.open(MASTER).convert("RGBA")
    for size, filename in sizes:
        resized = master.resize((size, size), Image.Resampling.LANCZOS)
        resized.save(ICONSET / filename)


def build_icns() -> None:
    subprocess.run(["iconutil", "-c", "icns", str(ICONSET), "-o", str(ICNS)], check=True)


if __name__ == "__main__":
    create_master_icon()
    build_iconset()
    build_icns()
    print(f"Generated {MASTER}")
    print(f"Generated {ICNS}")
