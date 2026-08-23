#!/usr/bin/env python3
"""Analyze a manually-driven Wayland top-level resize trace.

The opt-in ``WAYWALLEN_RESIZE_TIMING`` log contains both QWindow geometry
notifications and the scene-graph frame that first synchronized each geometry.
This analyzer deliberately collapses consecutive duplicate geometries: Qt may
emit widthChanged and heightChanged for the same configure, and counting both
would overstate the compositor's effective resize cadence.
"""

from __future__ import annotations

import argparse
import math
import re
import statistics
from dataclasses import dataclass, field
from pathlib import Path


FIELDS = re.compile(r"([a-z0-9_]+)=([^ ]+)")


def values(line: str) -> dict[str, float | str]:
    parsed: dict[str, float | str] = {}
    for key, raw in FIELDS.findall(line):
        try:
            parsed[key] = float(raw)
        except ValueError:
            parsed[key] = raw
    return parsed


def percentile(samples: list[float], ratio: float) -> float:
    if not samples:
        return 0.0
    ordered = sorted(samples)
    index = max(0, min(len(ordered) - 1, math.ceil(len(ordered) * ratio) - 1))
    return ordered[index]


def rate(timestamps_ms: list[float]) -> float:
    if len(timestamps_ms) < 2:
        return 0.0
    duration = timestamps_ms[-1] - timestamps_ms[0]
    return (len(timestamps_ms) - 1) * 1000.0 / duration if duration > 0 else 0.0


@dataclass
class Configure:
    seq: int
    time_ms: float
    width: int
    height: int


@dataclass
class Session:
    configures: list[Configure] = field(default_factory=list)
    swaps: list[dict[str, float | str]] = field(default_factory=list)
    summary: dict[str, float | str] = field(default_factory=dict)

    def useful(self) -> bool:
        return len(self.configures) >= 2 and bool(self.swaps)


def parse_sessions(path: Path) -> list[Session]:
    sessions: list[Session] = []
    current = Session()
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if line.startswith("waywallen resize configure: "):
            item = values(line)
            current.configures.append(Configure(
                seq=round(float(item["seq"])),
                time_ms=float(item["t_ms"]),
                width=round(float(str(item["window"]).split("x", 1)[0])),
                height=round(float(str(item["window"]).split("x", 1)[1])),
            ))
        elif line.startswith("waywallen resize swap: "):
            current.swaps.append(values(line))
        elif line.startswith("waywallen resize session: "):
            current.summary = values(line)
            if current.useful():
                sessions.append(current)
            current = Session()
    if current.useful():
        sessions.append(current)
    return sessions


def direction_reversals(configures: list[Configure], axis: str) -> int:
    previous_sign = 0
    reversals = 0
    for left, right in zip(configures, configures[1:]):
        delta = getattr(right, axis) - getattr(left, axis)
        sign = (delta > 0) - (delta < 0)
        if sign and previous_sign and sign != previous_sign:
            reversals += 1
        if sign:
            previous_sign = sign
    return reversals


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("trace", type=Path)
    parser.add_argument("--session", type=int,
                        help="analyze only this zero-based session")
    parser.add_argument("--min-swap-hz", type=float)
    args = parser.parse_args()

    sessions = parse_sessions(args.trace)
    if args.session is not None:
        if args.session < 0 or args.session >= len(sessions):
            raise SystemExit(f"session {args.session} does not exist")
        selected = [(args.session, sessions[args.session])]
    else:
        selected = list(enumerate(sessions))
    if not selected:
        raise SystemExit("no completed resize sessions found")

    failed = False
    for index, session in selected:
        unique: list[Configure] = []
        for configure in session.configures:
            if unique and (configure.width, configure.height) == (
                    unique[-1].width, unique[-1].height):
                # The render thread synchronizes the newest sequence number.
                # Retain the last notification for a duplicate geometry so a
                # widthChanged+heightChanged pair maps to its actual buffer.
                unique[-1] = configure
                continue
            unique.append(configure)

        intervals = [right.time_ms - left.time_ms
                     for left, right in zip(unique, unique[1:])]
        by_sequence = {item.seq: item for item in session.configures}
        stale_buffers = 0
        out_of_order = 0
        previous_swap_sequence = -1
        matched_sequences: set[int] = set()
        pending: list[float] = []
        geometry_to_swap: list[float] = []
        sync_to_swap: list[float] = []
        sync: list[float] = []
        render: list[float] = []
        for swap in session.swaps:
            sequence = round(float(swap["seq"]))
            expected = by_sequence.get(sequence)
            if expected:
                buffer_width, buffer_height = (
                    round(float(part)) for part in str(swap["buffer"]).split("x", 1)
                )
                if (buffer_width, buffer_height) != (expected.width, expected.height):
                    stale_buffers += 1
                matched_sequences.add(sequence)
            if sequence < previous_swap_sequence:
                out_of_order += 1
            previous_swap_sequence = sequence
            pending.append(float(swap.get("pending", 0.0)))
            geometry_to_swap.append(float(swap.get("geometry_to_swap_ms", 0.0)))
            sync_to_swap.append(float(swap.get("sync_to_swap_ms", 0.0)))
            sync.append(float(swap.get("sync_ms", 0.0)))
            render.append(float(swap.get("render_ms", 0.0)))

        summary_swaps = round(float(session.summary.get("swaps", len(session.swaps))))
        summary_swap_hz = float(session.summary.get("swap_hz", 0.0))
        unmatched = sum(item.seq not in matched_sequences for item in unique)
        print(
            f"session={index} raw_configures={len(session.configures)} "
            f"unique_configures={len(unique)} duplicate_notifications="
            f"{len(session.configures) - len(unique)} unique_geometry_hz={rate([item.time_ms for item in unique]):.1f}"
        )
        print(
            f"  configure_dt_ms p50={statistics.median(intervals) if intervals else 0.0:.3f} "
            f"p95={percentile(intervals, 0.95):.3f} max={max(intervals, default=0.0):.3f} "
            f"width_reversals={direction_reversals(unique, 'width')} "
            f"height_reversals={direction_reversals(unique, 'height')}"
        )
        print(
            f"  presented_frames={summary_swaps} swap_hz={summary_swap_hz:.1f} "
            f"geometry_matched_swaps={len(session.swaps)} "
            f"pending_p95={percentile(pending, 0.95):.0f} pending_max={max(pending, default=0.0):.0f} "
            f"unmatched_unique_configures={unmatched} stale_buffers={stale_buffers} "
            f"out_of_order_swaps={out_of_order}"
        )
        print(
            f"  latency_p95_ms geometry_to_swap={percentile(geometry_to_swap, 0.95):.3f} "
            f"sync_to_swap={percentile(sync_to_swap, 0.95):.3f} "
            f"sync={percentile(sync, 0.95):.3f} render={percentile(render, 0.95):.3f}"
        )
        if stale_buffers or out_of_order:
            failed = True
        if args.min_swap_hz is not None and summary_swap_hz < args.min_swap_hz:
            failed = True
            print(f"  FAIL: swap_hz is below {args.min_swap_hz:.1f}")

    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
