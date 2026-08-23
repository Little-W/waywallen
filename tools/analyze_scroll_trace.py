#!/usr/bin/env python3
"""Validate waywallen's opt-in mouse-wheel trajectory and presentation log."""

from __future__ import annotations

import argparse
import math
import re
import sys
from pathlib import Path


def field(line: str, name: str) -> float:
    match = re.search(rf"(?:^|\s){re.escape(name)}=(-?\d+(?:\.\d+)?)", line)
    if not match:
        raise ValueError(f"missing {name}")
    return float(match.group(1))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("log", type=Path)
    parser.add_argument("--grid", choices=("wallpaper", "discover"), required=True)
    parser.add_argument("--steps", type=int, default=5)
    parser.add_argument("--target-hz", type=float, default=165.0)
    args = parser.parse_args()

    text = args.log.read_text(encoding="utf-8", errors="replace")
    timing_lines = [
        line for line in text.splitlines()
        if line.startswith(f"waywallen scroll timing: grid={args.grid} ")
        and "duration_ms=" in line
    ]
    native_lines = [
        line for line in text.splitlines()
        if line.startswith(
            f"waywallen visual check: native_wheel page={args.grid} "
        )
    ]
    failures: list[str] = []
    if not timing_lines:
        failures.append("missing completed scroll timing record")
    if not native_lines:
        failures.append("missing native wheel result")
    if failures:
        for failure in failures:
            print(f"FAIL: {failure}")
        return 1

    timing = timing_lines[-1]
    native = native_lines[-1]
    expected_distance = args.steps * 72.0
    frame_period_ms = 1000.0 / args.target_hz

    checks = [
        (field(native, "sent") == args.steps, "all wheel events were delivered"),
        (field(native, "steps") == args.steps, "requested wheel step count matches"),
        (field(native, "count") > 0, "grid model is populated"),
        (field(native, "content_height") > field(native, "viewport_height"),
         "grid is vertically scrollable"),
        (math.isclose(field(native, "delta"), expected_distance, abs_tol=0.5),
         f"travel is {expected_distance:.0f} px"),
        (field(timing, "wheel_events") == args.steps, "telemetry saw every wheel event"),
        (field(timing, "mouse") == args.steps, "events used the mouse path"),
        (field(timing, "touchpad") == 0, "touchpad path stayed untouched"),
        (field(timing, "content_hz") >= args.target_hz * 0.90,
         "content trajectory meets high-refresh cadence"),
        (field(timing, "frame_hz") >= args.target_hz * 0.90,
         "scene presentation meets high-refresh cadence"),
        (field(timing, "input_to_content_p95_ms") <= frame_period_ms * 2.0,
         "input-to-motion latency is at most two target frames"),
        (field(timing, "direction_reversals") == 0, "trajectory never reverses"),
        (field(timing, "reversed_px") <= 0.1, "trajectory has no rebound distance"),
        (math.isclose(field(timing, "net_distance_px"), expected_distance,
                      abs_tol=0.5), "net distance matches wheel input"),
        (abs(field(timing, "total_distance_px")
             - abs(field(timing, "net_distance_px"))) <= 0.5,
         "total distance matches monotonic net distance"),
    ]

    # Bracketed percentile fields need targeted extraction.
    content_dt = re.search(
        r"content_dt_ms\[p50=([\d.]+) p95=([\d.]+) max=([\d.]+)\]", timing
    )
    if not content_dt:
        checks.append((False, "content interval percentiles are present"))
    else:
        checks.append((float(content_dt.group(2)) <= frame_period_ms * 1.6,
                       "content p95 interval stays near one target frame"))
    checks.append((field(timing, "frame_dt_p95_ms") <= frame_period_ms * 1.6,
                   "presentation p95 interval stays near one target frame"))

    bad_runtime_patterns = (
        "Possible anchor loop",
        "QQmlApplicationEngine failed",
        "is not a type",
        "TypeError:",
        "ReferenceError:",
    )
    checks.append((not any(pattern in text for pattern in bad_runtime_patterns),
                   "no QML layout/type runtime errors"))

    for passed, description in checks:
        print(f"{'PASS' if passed else 'FAIL'}: {description}")
        if not passed:
            failures.append(description)

    print(
        "metrics: "
        f"content_hz={field(timing, 'content_hz'):.1f} "
        f"frame_hz={field(timing, 'frame_hz'):.1f} "
        f"latency_p95_ms={field(timing, 'input_to_content_p95_ms'):.3f} "
        f"net_px={field(timing, 'net_distance_px'):.3f}"
    )
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
