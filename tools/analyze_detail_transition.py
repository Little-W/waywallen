#!/usr/bin/env python3
"""Reject two-stage card sizing in the wallpaper detail transition."""

from __future__ import annotations

import argparse
import re
from pathlib import Path


PREFIX = "waywallen detail frame: "
FIELD = re.compile(r"([a-z0-9_]+)=([^ ]+)")


def parse(path: Path) -> list[dict[str, float]]:
    frames: list[dict[str, float]] = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if not line.startswith(PREFIX):
            continue
        frame: dict[str, float] = {}
        for key, raw in FIELD.findall(line[len(PREFIX):]):
            try:
                frame[key] = float(raw)
            except ValueError:
                pass
        required = {"i", "t_ms", "progress", "cols", "cell_w", "display_w",
                    "surface_w", "content_y", "current_scene_center_y",
                    "current_visible"}
        if required <= frame.keys():
            frames.append(frame)
    return frames


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("trace", type=Path)
    parser.add_argument("--tolerance", type=float, default=0.35)
    args = parser.parse_args()

    frames = parse(args.trace)
    failures: list[str] = []
    if len(frames) < 4:
        raise SystemExit(f"not enough detail frames: {len(frames)}")

    progress = [frame["progress"] for frame in frames]
    if any(right + 0.001 < left for left, right in zip(progress, progress[1:])):
        failures.append("panel progress reverses")
    if progress[-1] < 0.995:
        failures.append(f"panel did not settle: progress={progress[-1]:.3f}")

    # A correct master-detail transition chooses its destination topology once
    # at the start. The card may monotonically grow, shrink, or remain fixed,
    # but it must never shrink and then grow as the old code did.
    widths = [frame["surface_w"] for frame in frames]
    deltas = [right - left for left, right in zip(widths, widths[1:])
              if abs(right - left) > args.tolerance]
    signs = {(delta > 0) - (delta < 0) for delta in deltas}
    if len(signs) > 1:
        failures.append("card width changes direction during one transition")

    columns = [round(frame["cols"]) for frame in frames]
    column_changes = sum(left != right for left, right in zip(columns, columns[1:]))
    if column_changes > 1:
        failures.append(f"column topology changed {column_changes} times")
    if any(frame["current_visible"] < 0.5 for frame in frames):
        failures.append("selected card left the visible viewport")

    centers = [frame["current_scene_center_y"] for frame in frames]
    center_steps = [right - left for left, right in zip(centers, centers[1:])]
    # Both layouts position the chosen item on the same visible row. The FLIP
    # may move it by a fraction while sizes interpolate, but a late focus snap
    # must never be the largest movement in the sequence.
    moving_center_steps = [abs(step) for step in center_steps if abs(step) > 0.05]
    tail_center_step = max((abs(step) for step in center_steps[-4:]), default=0.0)
    if moving_center_steps and tail_center_step > max(0.75, max(moving_center_steps) * 0.35):
        failures.append(f"selected card has a late focus jump ({tail_center_step:.3f}px)")

    content_positions = [frame["content_y"] for frame in frames]
    content_steps = [right - left for left, right in zip(content_positions,
                                                          content_positions[1:])]
    moving_content_steps = [abs(step) for step in content_steps if abs(step) > 0.01]
    tail_content_step = max((abs(step) for step in content_steps[-4:]), default=0.0)
    if moving_content_steps and tail_content_step > 0.1:
        failures.append(f"contentY changes after the layout animation ({tail_content_step:.3f}px)")

    intervals = [right["t_ms"] - left["t_ms"]
                 for left, right in zip(frames, frames[1:])]
    duration = frames[-1]["t_ms"] - frames[0]["t_ms"]
    sample_hz = ((len(frames) - 1) * 1000.0 / duration) if duration > 0 else 0.0
    print(
        f"frames={len(frames)} sample_hz={sample_hz:.1f} "
        f"max_interval_ms={max(intervals, default=0.0):.3f} "
        f"progress={progress[0]:.3f}->{progress[-1]:.3f}"
    )
    print(
        f"columns={columns[0]}->{columns[-1]} column_changes={column_changes} "
        f"surface_width={widths[0]:.3f}->{widths[-1]:.3f} "
        f"width_direction_changes={max(0, len(signs) - 1)}"
    )
    print(f"selected_visible_frames={sum(frame['current_visible'] >= 0.5 for frame in frames)}/{len(frames)}")
    print(f"selected_center={centers[0]:.3f}->{centers[-1]:.3f} "
          f"tail_center_step={tail_center_step:.3f} "
          f"content_y={content_positions[0]:.3f}->{content_positions[-1]:.3f} "
          f"tail_content_step={tail_content_step:.3f}")
    for failure in failures:
        print(f"FAIL: {failure}")
    if not failures:
        print("PASS")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
