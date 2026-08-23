#!/usr/bin/env python3
"""Validate monotonic high-refresh wallpaper-grid resize traces.

The UI emits one `waywallen resize frame:` record only after the Wayland
surface has reached the requested logical width.  This script rejects stale
or missing frames and reports any thumbnail/cell size movement opposite to
the simulated window-resize direction (the visible "size rebound").
"""

from __future__ import annotations

import argparse
import math
import re
import statistics
from pathlib import Path


FRAME_PREFIX = "waywallen resize frame: "
TIMING_PREFIX = "waywallen resize timing: "
FIELD = re.compile(r"([a-z0-9_]+)=([^ ]+)")


def percentile(values: list[float], percentage: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    index = math.ceil(len(ordered) * percentage) - 1
    return ordered[max(0, min(index, len(ordered) - 1))]


def parse_frames(path: Path) -> list[dict[str, float]]:
    frames: list[dict[str, float]] = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if not line.startswith(FRAME_PREFIX):
            continue
        values: dict[str, float] = {}
        for key, raw in FIELD.findall(line[len(FRAME_PREFIX) :]):
            try:
                values[key] = float(raw)
            except ValueError:
                continue
        required = {"i", "t_ms", "target_w", "window_w", "cols", "cell_w", "display_w"}
        if required <= values.keys():
            frames.append(values)
    return frames


def parse_timing(path: Path) -> dict[str, float]:
    timing: dict[str, float] = {}
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if not line.startswith(TIMING_PREFIX):
            continue
        for key, raw in FIELD.findall(line[len(TIMING_PREFIX) :]):
            try:
                timing[key] = float(raw)
            except ValueError:
                continue
    return timing


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("trace", type=Path)
    parser.add_argument("--expect-frames", type=int)
    parser.add_argument("--pattern", choices=("monotonic", "bounce"),
                        default="monotonic")
    parser.add_argument("--fail-on-rebound", action="store_true")
    parser.add_argument("--fail-on-settle-motion", action="store_true")
    parser.add_argument("--min-hz", type=float)
    parser.add_argument("--min-swap-hz", type=float)
    args = parser.parse_args()

    frames = parse_frames(args.trace)
    timing = parse_timing(args.trace)
    if not frames:
        raise SystemExit("no synchronized resize frames found")

    failures: list[str] = []
    expected_indexes = list(range(len(frames)))
    indexes = [round(frame["i"]) for frame in frames]
    if indexes != expected_indexes:
        failures.append(f"non-contiguous frame indexes: {indexes}")
    if args.expect_frames is not None and len(frames) != args.expect_frames:
        failures.append(f"expected {args.expect_frames} frames, got {len(frames)}")

    intervals = [right["t_ms"] - left["t_ms"] for left, right in zip(frames, frames[1:])]
    target_deltas = [right["target_w"] - left["target_w"]
                     for left, right in zip(frames, frames[1:])]
    if args.pattern == "monotonic":
        if any(delta > 0 for delta in target_deltas):
            failures.append("target window width increases during shrink trace")
        if target_deltas and not any(delta < 0 for delta in target_deltas):
            failures.append("target window width never decreases")
    else:
        if not any(delta < 0 for delta in target_deltas):
            failures.append("bounce target never shrinks")
        if not any(delta > 0 for delta in target_deltas):
            failures.append("bounce target never expands")
    stale = [frame for frame in frames
             if frame.get("grid_only", 0.0) < 0.5
             and frame["window_w"] != frame["target_w"]]
    if stale:
        failures.append(f"{len(stale)} frames have stale logical window geometry")

    rebounds: list[tuple[int, float, int, int]] = []
    cell_rebounds: list[tuple[int, float, int, int]] = []
    settle_motion: list[tuple[int, float, float, int, int]] = []
    for left, right in zip(frames, frames[1:]):
        target_delta = right["target_w"] - left["target_w"]
        if abs(target_delta) < 0.05:
            display_delta = right["display_w"] - left["display_w"]
            cell_delta = right["cell_w"] - left["cell_w"]
            if abs(display_delta) > 0.05 or abs(cell_delta) > 0.05:
                settle_motion.append((round(right["i"]), display_delta, cell_delta,
                                      round(left["cols"]), round(right["cols"])))
            continue
        display_delta = right["display_w"] - left["display_w"]
        cell_delta = right["cell_w"] - left["cell_w"]
        if display_delta * target_delta < -0.05:
            rebounds.append((round(right["i"]), display_delta,
                             round(left["cols"]), round(right["cols"])))
        if cell_delta * target_delta < -0.05:
            cell_rebounds.append((round(right["i"]), cell_delta,
                                  round(left["cols"]), round(right["cols"])))

    median_ms = statistics.median(intervals) if intervals else 0.0
    p95_ms = percentile(intervals, 0.95)
    achieved_hz = 1000.0 / median_ms if median_ms > 0 else 0.0
    print(f"frames={len(frames)} interval_median_ms={median_ms:.3f} "
          f"interval_p95_ms={p95_ms:.3f} achieved_hz={achieved_hz:.1f}")
    if timing:
        print(f"geometry_hz={timing.get('geometry_hz', 0.0):.1f} "
              f"geometry_p95_ms={timing.get('geometry_p95_ms', 0.0):.3f} "
              f"swap_hz={timing.get('swap_hz', 0.0):.1f} "
              f"swap_p95_ms={timing.get('swap_p95_ms', 0.0):.3f}")
    print(f"window={frames[0]['target_w']:.0f}->{frames[-1]['target_w']:.0f} "
          f"columns={frames[0]['cols']:.0f}->{frames[-1]['cols']:.0f}")
    if rebounds:
        worst = max(rebounds, key=lambda item: item[1])
        print(f"display_rebounds={len(rebounds)} worst_frame={worst[0]} "
              f"worst_delta_px={worst[1]:.3f} columns={worst[2]}->{worst[3]}")
    else:
        print("display_rebounds=0")
    if cell_rebounds:
        worst = max(cell_rebounds, key=lambda item: item[1])
        print(f"cell_rebounds={len(cell_rebounds)} worst_frame={worst[0]} "
              f"worst_delta_px={worst[1]:.3f} columns={worst[2]}->{worst[3]}")
    else:
        print("cell_rebounds=0")
    if settle_motion:
        worst = max(settle_motion,
                    key=lambda item: max(abs(item[1]), abs(item[2])))
        print(f"settle_motion={len(settle_motion)} worst_frame={worst[0]} "
              f"display_delta_px={worst[1]:.3f} cell_delta_px={worst[2]:.3f} "
              f"columns={worst[3]}->{worst[4]}")
    else:
        print("settle_motion=0")

    if args.fail_on_rebound and rebounds:
        failures.append("thumbnail display width rebounds during monotonic shrink")
    if args.fail_on_settle_motion and settle_motion:
        failures.append("thumbnail geometry keeps moving after target width is stable")
    if args.min_hz is not None and achieved_hz < args.min_hz:
        failures.append(f"geometry trajectory {achieved_hz:.1f} Hz is below "
                        f"{args.min_hz:.1f} Hz")
    if args.min_swap_hz is not None:
        swap_hz = timing.get("swap_hz")
        if swap_hz is None:
            failures.append("resize timing summary with swap_hz is missing")
        elif swap_hz < args.min_swap_hz:
            failures.append(f"presentation {swap_hz:.1f} Hz is below "
                            f"{args.min_swap_hz:.1f} Hz")
    if failures:
        for failure in failures:
            print(f"FAIL: {failure}")
        return 1
    print("PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
