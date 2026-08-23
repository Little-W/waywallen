#!/usr/bin/env python3
"""Detect empty/black wallpaper cards in WAYWALLEN wheel captures.

The visual-check harness records GridView.contentY beside every `wheel-N.png`.
This script projects the QML cell lattice into the captured buffer, samples the
title-free upper area of every fully visible thumbnail, and reports persistent
white holes or black frames.  Defaults match WallpaperPage's desktop geometry;
the logical origins can be overridden for a different shell layout.
"""

from __future__ import annotations

import argparse
import re
import statistics
from pathlib import Path

import numpy as np
from PIL import Image


FRAME_RE = re.compile(
    r"waywallen wheel frame: page=(?P<page>\w+) i=(?P<index>\d+) "
    r"content_y=(?P<content_y>-?[0-9.]+)"
)
GEOMETRY_RE = re.compile(
    r"waywallen visual check: grid count=(?P<count>\d+) visible=\w+ "
    r"columns=(?P<columns>\d+) cell=(?P<cell_width>[0-9.]+)x(?P<cell_height>[0-9.]+) "
    r"display_item=(?P<display_width>[0-9.]+)x(?P<display_height>[0-9.]+) "
    r"window_dpr=(?P<dpr>[0-9.]+)"
)
FINAL_RE = re.compile(
    r"waywallen visual check: native_wheel page=(?P<page>\w+).*?"
    r"after=(?P<after>-?[0-9.]+)"
)


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("capture_dir", type=Path)
    parser.add_argument("log", type=Path)
    parser.add_argument("--page", default="wallpaper")
    parser.add_argument("--grid-origin-x", type=float, default=88.0,
                        help="Grid viewport scene x in logical pixels")
    parser.add_argument("--grid-origin-y", type=float, default=53.0,
                        help="Grid viewport scene y in logical pixels")
    parser.add_argument("--left-margin", type=float, default=8.0)
    parser.add_argument("--card-inset", type=float, default=6.0)
    parser.add_argument("--visible-top", type=float, default=106.0,
                        help="Toolbar lower edge in logical pixels")
    parser.add_argument("--visible-bottom-margin", type=float, default=12.0)
    parser.add_argument("--empty-ratio-limit", type=float, default=0.0)
    parser.add_argument("--black-ratio-limit", type=float, default=0.0)
    parser.add_argument("--bottom-tolerance-rows", type=float, default=1.0,
                        help="Maximum allowed gap from the final wheel position")
    return parser.parse_args()


def main() -> int:
    args = arguments()
    text = args.log.read_text(errors="replace")
    positions = {
        int(match.group("index")): float(match.group("content_y"))
        for match in FRAME_RE.finditer(text)
        if match.group("page") == args.page
    }
    geometry_matches = list(GEOMETRY_RE.finditer(text))
    if not geometry_matches:
        raise SystemExit("missing visual-check grid geometry in log")
    geometry = geometry_matches[-1]
    columns = int(geometry.group("columns"))
    item_count = int(geometry.group("count"))
    cell_width = float(geometry.group("cell_width"))
    cell_height = float(geometry.group("cell_height"))
    display_width = float(geometry.group("display_width"))
    display_height = float(geometry.group("display_height"))
    dpr = float(geometry.group("dpr"))
    final_matches = [match for match in FINAL_RE.finditer(text)
                     if match.group("page") == args.page]
    final_content_y = (float(final_matches[-1].group("after"))
                       if final_matches else None)

    frames = sorted(
        args.capture_dir.glob("wheel-*.png"),
        key=lambda path: int(path.stem.rsplit("-", 1)[1]),
    )
    if not frames:
        raise SystemExit("no wheel-*.png captures found")

    # A process killed while the harness is compressing its buffered frames can
    # leave one syntactically readable but incomplete final PNG. Exclude files
    # whose size is less than half the capture median.
    median_size = statistics.median(path.stat().st_size for path in frames)
    incomplete = [path for path in frames if path.stat().st_size < median_size * 0.5]
    incomplete_names = {path.name for path in incomplete}

    sampled = empty = black = 0
    frame_results: list[tuple[float, int, int, int, int, float]] = []
    card_results: list[tuple[float, int, int, int]] = []
    x0 = (args.grid_origin_x + args.left_margin + args.card_inset) * dpr
    card_width = max(1.0, (display_width - 2 * args.card_inset) * dpr)
    card_height = max(1.0, (display_height - 2 * args.card_inset) * dpr)
    visible_top = args.visible_top * dpr

    for path in frames:
        index = int(path.stem.rsplit("-", 1)[1])
        if path.name in incomplete_names or index not in positions:
            continue
        pixels = np.asarray(Image.open(path).convert("RGB"))
        height, width, _ = pixels.shape
        visible_bottom = height - args.visible_bottom_margin * dpr
        content_y = positions[index]
        first_row = int((content_y - args.grid_origin_y) // cell_height) - 1
        last_row = int((content_y + height / dpr) // cell_height) + 1
        frame_sampled = frame_empty = frame_black = 0

        for row in range(first_row, last_row + 1):
            top = (args.grid_origin_y + args.card_inset
                   + row * cell_height - content_y) * dpr
            if top < visible_top or top + card_height > visible_bottom:
                continue
            # Exclude rounded corners, title text and its lower gradient.
            crop_top = round(top + 0.08 * card_height)
            crop_bottom = round(top + 0.64 * card_height)
            for column in range(columns):
                if row < 0 or row * columns + column >= item_count:
                    continue
                left = x0 + column * cell_width * dpr
                crop_left = round(left + 0.08 * card_width)
                crop_right = round(left + 0.92 * card_width)
                if crop_left < 0 or crop_right > width:
                    continue
                crop = pixels[crop_top:crop_bottom, crop_left:crop_right]
                if crop.size == 0:
                    continue
                frame_sampled += 1
                white_fraction = np.mean(np.min(crop, axis=2) > 245)
                black_fraction = np.mean(np.max(crop, axis=2) < 12)
                if white_fraction > 0.985:
                    frame_empty += 1
                if black_fraction > 0.985:
                    frame_black += 1

        sampled += frame_sampled
        empty += frame_empty
        black += frame_black
        ratio = frame_empty / frame_sampled if frame_sampled else 0.0
        frame_results.append(
            (ratio, frame_empty, frame_black, frame_sampled, index, content_y)
        )
        card_results.append((content_y, frame_empty, frame_black, frame_sampled))

    empty_ratio = empty / sampled if sampled else 1.0
    black_ratio = black / sampled if sampled else 1.0
    worst = sorted(frame_results, reverse=True)[:5]
    print(
        f"frames={len(frame_results)} ignored_incomplete={len(incomplete)} "
        f"cards={sampled} empty={empty} empty_ratio={empty_ratio:.6f} "
        f"black={black} black_ratio={black_ratio:.6f}"
    )
    for ratio, frame_empty, frame_black, frame_sampled, index, content_y in worst:
        print(
            f"worst frame={index} content_y={content_y:.3f} "
            f"empty={frame_empty}/{frame_sampled} black={frame_black} "
            f"empty_ratio={ratio:.6f}"
        )
    if card_results:
        low = min(result[0] for result in card_results)
        high = max(result[0] for result in card_results)
        span = max(1.0, high - low)
        segments = {"top": [0, 0, 0], "middle": [0, 0, 0], "bottom": [0, 0, 0]}
        for content_y, frame_empty, frame_black, frame_sampled in card_results:
            progress = (content_y - low) / span
            name = "top" if progress < 1 / 3 else "middle" if progress < 2 / 3 else "bottom"
            segments[name][0] += frame_empty
            segments[name][1] += frame_black
            segments[name][2] += frame_sampled
        for name, (segment_empty, segment_black, segment_sampled) in segments.items():
            print(
                f"segment={name} cards={segment_sampled} empty={segment_empty} "
                f"empty_ratio={segment_empty / segment_sampled if segment_sampled else 0:.6f} "
                f"black={segment_black} "
                f"black_ratio={segment_black / segment_sampled if segment_sampled else 0:.6f}"
            )

    if sampled == 0:
        print("FAIL: no fully visible cards sampled")
        return 1
    failures = []
    sampled_max_y = max((result[0] for result in card_results), default=None)
    if final_content_y is None:
        failures.append("missing final native-wheel position")
    elif sampled_max_y is None or final_content_y - sampled_max_y > (
            cell_height * args.bottom_tolerance_rows):
        failures.append(
            f"captures stop before bottom (sampled_max={sampled_max_y}, "
            f"wheel_after={final_content_y:.3f})"
        )
    if empty_ratio > args.empty_ratio_limit:
        failures.append("empty-card ratio exceeds limit")
    if black_ratio > args.black_ratio_limit:
        failures.append("black-card ratio exceeds limit")
    if failures:
        print("FAIL: " + "; ".join(failures))
        return 1
    print("PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
