#!/usr/bin/env python3
"""Generate Codex Mobile launcher assets without third-party packages."""

from __future__ import annotations

import math
import struct
import zlib
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
RES = ROOT / "android/app/src/main/res"

LEGACY_MARK_SCALE = 1.28
ADAPTIVE_MARK_SCALE = 1.28
LAUNCH_MARK_SCALE = 1.55

BG_TOP = (8, 15, 30)
BG_BOTTOM = (14, 42, 54)
ACCENT = (104, 247, 196)
ACCENT_SOFT = (125, 211, 252)


def clamp(value: float, low: float = 0.0, high: float = 1.0) -> float:
    return max(low, min(high, value))


def mix(a: tuple[int, int, int], b: tuple[int, int, int], t: float) -> tuple[int, int, int]:
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


class Canvas:
    def __init__(self, size: int) -> None:
        self.size = size
        self.pixels = bytearray(size * size * 4)

    def blend(self, x: int, y: int, color: tuple[int, int, int], alpha: float) -> None:
        if alpha <= 0 or x < 0 or y < 0 or x >= self.size or y >= self.size:
            return
        alpha = clamp(alpha)
        index = (y * self.size + x) * 4
        dst_a = self.pixels[index + 3] / 255.0
        src_a = alpha
        out_a = src_a + dst_a * (1.0 - src_a)
        if out_a <= 0:
            return
        for channel in range(3):
            dst = self.pixels[index + channel] / 255.0
            src = color[channel] / 255.0
            out = (src * src_a + dst * dst_a * (1.0 - src_a)) / out_a
            self.pixels[index + channel] = round(clamp(out) * 255)
        self.pixels[index + 3] = round(out_a * 255)

    def save_png(self, path: Path) -> None:
        raw = bytearray()
        stride = self.size * 4
        for y in range(self.size):
            raw.append(0)
            raw.extend(self.pixels[y * stride : (y + 1) * stride])

        def chunk(kind: bytes, data: bytes) -> bytes:
            return (
                struct.pack(">I", len(data))
                + kind
                + data
                + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
            )

        png = (
            b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", self.size, self.size, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
            + chunk(b"IEND", b"")
        )
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(png)


def rounded_rect_sdf(px: float, py: float, x: float, y: float, w: float, h: float, r: float) -> float:
    qx = abs(px - (x + w / 2)) - (w / 2 - r)
    qy = abs(py - (y + h / 2)) - (h / 2 - r)
    return min(max(qx, qy), 0.0) + math.hypot(max(qx, 0.0), max(qy, 0.0)) - r


def draw_background(canvas: Canvas) -> None:
    size = canvas.size
    for y in range(size):
        t = y / max(1, size - 1)
        base = mix(BG_TOP, BG_BOTTOM, t)
        for x in range(size):
            glow = clamp(1.0 - math.hypot(x - size * 0.72, y - size * 0.18) / (size * 0.62))
            color = mix(base, ACCENT_SOFT, glow * 0.12)
            canvas.blend(x, y, color, 1.0)


def draw_rounded_background(canvas: Canvas) -> None:
    size = canvas.size
    radius = size * 0.23
    for y in range(size):
        t = y / max(1, size - 1)
        base = mix(BG_TOP, BG_BOTTOM, t)
        for x in range(size):
            glow = clamp(1.0 - math.hypot(x - size * 0.72, y - size * 0.18) / (size * 0.62))
            color = mix(base, ACCENT_SOFT, glow * 0.12)
            coverage = clamp(0.5 - rounded_rect_sdf(x + 0.5, y + 0.5, 0, 0, size, size, radius))
            canvas.blend(x, y, color, coverage)


def draw_segment(
    canvas: Canvas,
    a: tuple[float, float],
    b: tuple[float, float],
    width: float,
    color: tuple[int, int, int],
) -> None:
    half = width / 2
    min_x = max(0, math.floor(min(a[0], b[0]) - half - 2))
    max_x = min(canvas.size - 1, math.ceil(max(a[0], b[0]) + half + 2))
    min_y = max(0, math.floor(min(a[1], b[1]) - half - 2))
    max_y = min(canvas.size - 1, math.ceil(max(a[1], b[1]) + half + 2))
    dx = b[0] - a[0]
    dy = b[1] - a[1]
    length_sq = dx * dx + dy * dy
    for y in range(min_y, max_y + 1):
        for x in range(min_x, max_x + 1):
            px = x + 0.5
            py = y + 0.5
            if length_sq == 0:
                distance = math.hypot(px - a[0], py - a[1])
            else:
                t = clamp(((px - a[0]) * dx + (py - a[1]) * dy) / length_sq)
                distance = math.hypot(px - (a[0] + t * dx), py - (a[1] + t * dy))
            canvas.blend(x, y, color, clamp(half + 0.8 - distance))


def draw_mark(canvas: Canvas, cx: float, cy: float, scale: float) -> None:
    stroke = 82 * scale
    origin_x = cx - 190 * scale
    origin_y = cy
    draw_segment(
        canvas,
        (origin_x, origin_y - 190 * scale),
        (origin_x + 190 * scale, origin_y),
        stroke,
        ACCENT,
    )
    draw_segment(
        canvas,
        (origin_x + 190 * scale, origin_y),
        (origin_x, origin_y + 190 * scale),
        stroke,
        ACCENT,
    )
    draw_segment(
        canvas,
        (cx + 28 * scale, origin_y + 185 * scale),
        (cx + 205 * scale, origin_y + 185 * scale),
        stroke,
        ACCENT_SOFT,
    )


def render_legacy(size: int) -> Canvas:
    canvas = Canvas(size)
    draw_rounded_background(canvas)
    draw_mark(canvas, size * 0.49, size * 0.5, size / 1024 * LEGACY_MARK_SCALE)
    return canvas


def render_background(size: int) -> Canvas:
    canvas = Canvas(size)
    draw_background(canvas)
    return canvas


def render_foreground(size: int) -> Canvas:
    canvas = Canvas(size)
    draw_mark(canvas, size * 0.5, size * 0.5, size / 1024 * ADAPTIVE_MARK_SCALE)
    return canvas


def render_launch_mark(size: int) -> Canvas:
    canvas = Canvas(size)
    draw_mark(canvas, size * 0.5, size * 0.5, size / 1024 * LAUNCH_MARK_SCALE)
    return canvas


def main() -> None:
    densities = {
        "mdpi": 48,
        "hdpi": 72,
        "xhdpi": 96,
        "xxhdpi": 144,
        "xxxhdpi": 192,
    }
    for density, size in densities.items():
        render_legacy(size).save_png(RES / f"mipmap-{density}/ic_launcher.png")

    render_background(1024).save_png(RES / "drawable/ic_launcher_background.png")
    render_foreground(1024).save_png(RES / "drawable/ic_launcher_foreground.png")
    render_foreground(512).save_png(ROOT / "assets/brand_mark.png")
    render_launch_mark(512).save_png(RES / "drawable/launch_icon.png")


if __name__ == "__main__":
    main()
