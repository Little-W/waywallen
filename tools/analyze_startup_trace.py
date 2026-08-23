#!/usr/bin/env python3
"""Reject startup frames that expose scaled or wrongly sized wallpaper cards."""

from __future__ import annotations

import argparse
import math
import re
import statistics
from pathlib import Path


FRAME_PREFIX = "waywallen startup frame: "
FIELD = re.compile(r"([a-z_]+)=([^ ]+)")
SURFACE = re.compile(r"surface=([-+0-9.eE]+)x([-+0-9.eE]+)")


def parse_frames(path: Path) -> list[dict[str, float]]:
    frames: list[dict[str, float]] = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if not line.startswith(FRAME_PREFIX):
            continue
        values: dict[str, float] = {}
        payload = line[len(FRAME_PREFIX) :]
        for key, raw in FIELD.findall(payload):
            try:
                values[key] = float(raw)
            except ValueError:
                continue
        surface = SURFACE.search(payload)
        if surface:
            values["surface_w"] = float(surface.group(1))
            values["surface_h"] = float(surface.group(2))
        if {"i", "page", "page_opacity", "page_scale", "grid_visible",
            "card", "surface_w", "surface_h"} <= values.keys():
            frames.append(values)
    return frames


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("trace", type=Path)
    parser.add_argument("--expect-frames", type=int)
    parser.add_argument("--size-tolerance", type=float, default=0.75)
    args = parser.parse_args()

    frames = parse_frames(args.trace)
    if not frames:
        raise SystemExit("no startup frames found")

    failures: list[str] = []
    if args.expect_frames is not None and len(frames) != args.expect_frames:
        failures.append(f"expected {args.expect_frames} frames, got {len(frames)}")

    page_frames = [frame for frame in frames if frame["page"] > 0.5]
    transformed = [frame for frame in page_frames
                   if abs(frame["page_scale"] - 1.0) > 0.001
                   or abs(frame["page_opacity"] - 1.0) > 0.001]
    visible_cards = [frame for frame in frames
                     if frame["grid_visible"] > 0.5 and frame["card"] > 0.5]
    if not visible_cards:
        failures.append("no visible wallpaper-card frame found")
        final_width = 0.0
        wrong_sizes: list[dict[str, float]] = []
    else:
        tail = [frame["surface_w"] for frame in visible_cards[-min(8, len(visible_cards)):]
                if math.isfinite(frame["surface_w"]) and frame["surface_w"] > 0.0]
        final_width = statistics.median(tail) if tail else 0.0
        wrong_sizes = [frame for frame in visible_cards
                       if abs(frame["surface_w"] - final_width) > args.size_tolerance
                       or abs(frame["surface_h"] - final_width) > args.size_tolerance]

    print(f"frames={len(frames)} page_transformed={len(transformed)} "
          f"visible_card_frames={len(visible_cards)} final_card_px={final_width:.3f}")
    if wrong_sizes:
        first = wrong_sizes[0]
        print(f"visible_wrong_size={len(wrong_sizes)} first_frame={first['i']:.0f} "
              f"size={first['surface_w']:.3f}x{first['surface_h']:.3f}")
    else:
        print("visible_wrong_size=0")

    if transformed:
        failures.append(f"{len(transformed)} startup frames transform the entire page")
    if wrong_sizes:
        failures.append(f"{len(wrong_sizes)} visible frames expose unstable card geometry")
    if failures:
        for failure in failures:
            print(f"FAIL: {failure}")
        return 1
    print("PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
