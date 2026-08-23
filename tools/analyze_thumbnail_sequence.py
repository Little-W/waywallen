#!/usr/bin/env python3
"""Verify that a targeted cold animated thumbnail never exposes a black lead frame."""

from __future__ import annotations

import argparse
import re
import statistics
from pathlib import Path

import numpy as np
from PIL import Image, ImageSequence


FRAME_RE = re.compile(
    r"waywallen wheel frame: page=wallpaper i=(?P<index>\d+) "
    r"content_y=(?P<content_y>-?[0-9.]+)"
)
TARGET_RE = re.compile(
    r"waywallen visual check: thumbnail_target=.*? found=true "
    r"index=(?P<index>\d+) row=(?P<row>\d+) column=(?P<column>\d+)"
)
GEOMETRY_RE = re.compile(
    r"waywallen visual check: grid count=(?P<count>\d+) visible=\w+ "
    r"columns=(?P<columns>\d+) cell=(?P<cell_width>[0-9.]+)x(?P<cell_height>[0-9.]+) "
    r"display_item=(?P<display_width>[0-9.]+)x(?P<display_height>[0-9.]+) "
    r"window_dpr=(?P<dpr>[0-9.]+)"
)


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("capture_dir", type=Path)
    parser.add_argument("log", type=Path)
    parser.add_argument("source_gif", type=Path)
    parser.add_argument("--grid-origin-x", type=float, default=88.0)
    parser.add_argument("--grid-origin-y", type=float, default=53.0)
    parser.add_argument("--left-margin", type=float, default=8.0)
    parser.add_argument("--card-inset", type=float, default=6.0)
    parser.add_argument("--black-fraction", type=float, default=0.985)
    return parser.parse_args()


def source_metrics(path: Path) -> list[tuple[float, float]]:
    with Image.open(path) as image:
        metrics = []
        for frame in ImageSequence.Iterator(image):
            rgb = np.asarray(frame.convert("RGB"), dtype=np.uint8)
            metrics.append((float(rgb.mean() / 255.0),
                            float(np.mean(np.max(rgb, axis=2) < 12))))
            if len(metrics) >= 12:
                break
        return metrics


def main() -> int:
    args = arguments()
    text = args.log.read_text(errors="replace")
    target_matches = list(TARGET_RE.finditer(text))
    geometry_matches = list(GEOMETRY_RE.finditer(text))
    if not target_matches or not geometry_matches:
        raise SystemExit("missing target or grid geometry in log")
    target = target_matches[-1]
    geometry = geometry_matches[-1]
    row = int(target.group("row"))
    column = int(target.group("column"))
    columns = int(geometry.group("columns"))
    if column >= columns:
        raise SystemExit("target column does not match captured grid geometry")
    cell_width = float(geometry.group("cell_width"))
    cell_height = float(geometry.group("cell_height"))
    display_width = float(geometry.group("display_width"))
    display_height = float(geometry.group("display_height"))
    dpr = float(geometry.group("dpr"))
    positions = {
        int(match.group("index")): float(match.group("content_y"))
        for match in FRAME_RE.finditer(text)
    }

    frames = sorted(args.capture_dir.glob("wheel-*.png"),
                    key=lambda path: int(path.stem.rsplit("-", 1)[1]))
    if not frames:
        raise SystemExit("no wheel captures")
    median_size = statistics.median(path.stat().st_size for path in frames)
    samples: list[tuple[int, float, float, float]] = []
    for path in frames:
        index = int(path.stem.rsplit("-", 1)[1])
        if index not in positions or path.stat().st_size < median_size * 0.5:
            continue
        pixels = np.asarray(Image.open(path).convert("RGB"), dtype=np.uint8)
        height, width, _ = pixels.shape
        content_y = positions[index]
        left = (args.grid_origin_x + args.left_margin + args.card_inset
                + column * cell_width) * dpr
        top = (args.grid_origin_y + args.card_inset + row * cell_height
               - content_y) * dpr
        card_width = (display_width - 2 * args.card_inset) * dpr
        card_height = (display_height - 2 * args.card_inset) * dpr
        crop_left = round(left + 0.08 * card_width)
        crop_right = round(left + 0.92 * card_width)
        crop_top = round(top + 0.08 * card_height)
        crop_bottom = round(top + 0.64 * card_height)
        if (crop_left < 0 or crop_right > width or crop_top < 0 or crop_bottom > height):
            continue
        crop = pixels[crop_top:crop_bottom, crop_left:crop_right]
        if crop.size == 0:
            continue
        samples.append((index, float(crop.mean() / 255.0),
                        float(np.mean(np.max(crop, axis=2) < 12)),
                        float(np.mean(np.min(crop, axis=2) > 245))))

    source = source_metrics(args.source_gif)
    print("source=" + ",".join(
        f"frame{i}:mean={mean:.6f}:black={black:.6f}"
        for i, (mean, black) in enumerate(source)
    ))
    print(f"captured={len(samples)}")
    for index, mean, black, white in samples:
        print(f"frame={index} mean={mean:.6f} black_fraction={black:.6f} "
              f"white_fraction={white:.6f}")

    failures = []
    if len(source) < 2 or source[0][1] < args.black_fraction:
        failures.append("source frame 0 is not the expected black lead frame")
    if not any(mean > 0.03 and black < args.black_fraction and white < 0.985
               for _, mean, black, white in samples):
        failures.append("target never produced visible content")
    leaked = [index for index, _, black, _ in samples if black >= args.black_fraction]
    if leaked:
        failures.append(f"black lead frame leaked in captures {leaked}")
    if failures:
        print("FAIL: " + "; ".join(failures))
        return 1
    print("PASS: black source frame 0 was never visible")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
