#!/usr/bin/env python3
"""Decode release screenshots and recordings and reject blank or obscured evidence."""

from __future__ import annotations

import argparse
import json
import shutil
import statistics
import subprocess
import sys
from pathlib import Path
from typing import Any


MIN_WIDTH = 200
MIN_HEIGHT = 120
MIN_VARIANCE = 24.0
MIN_RANGE = 24
MAX_DARK_FRACTION = 0.97


def run(*args: str) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(args, capture_output=True, check=False, timeout=45)


def require_tools() -> list[str]:
    return [name for name in ("ffmpeg", "ffprobe") if shutil.which(name) is None]


def probe(path: Path) -> tuple[dict[str, Any], list[str]]:
    result = run(
        "ffprobe", "-v", "error", "-show_streams", "-show_format",
        "-of", "json", str(path),
    )
    if result.returncode:
        return {}, [f"media cannot be decoded by ffprobe: {path.name}"]
    try:
        return json.loads(result.stdout), []
    except json.JSONDecodeError:
        return {}, [f"media probe returned invalid JSON: {path.name}"]


def video_stream(payload: dict[str, Any]) -> dict[str, Any] | None:
    return next(
        (stream for stream in payload.get("streams", []) if stream.get("codec_type") == "video"),
        None,
    )


def decode_gray_frame(path: Path, at_seconds: float | None = None) -> bytes:
    args = ["ffmpeg", "-v", "error"]
    if at_seconds is not None:
        args.extend(("-ss", f"{at_seconds:.3f}"))
    args.extend((
        "-i", str(path), "-frames:v", "1",
        "-vf", "scale=160:120:force_original_aspect_ratio=decrease,pad=160:120:(ow-iw)/2:(oh-ih)/2,format=gray",
        "-f", "rawvideo", "-",
    ))
    result = run(*args)
    return result.stdout if result.returncode == 0 else b""


def frame_visibility_errors(frame: bytes, label: str) -> list[str]:
    if len(frame) < 160 * 120:
        return [f"decoded media frame is missing: {label}"]
    values = list(frame[: 160 * 120])
    variance = statistics.pvariance(values)
    dynamic_range = max(values) - min(values)
    dark_fraction = sum(value < 12 for value in values) / len(values)
    errors = []
    if variance < MIN_VARIANCE or dynamic_range < MIN_RANGE:
        errors.append(f"decoded media frame is visually blank: {label}")
    if dark_fraction > MAX_DARK_FRACTION:
        errors.append(f"decoded media frame is permission-obscured or black: {label}")
    return errors


def dimension_errors(stream: dict[str, Any], label: str) -> list[str]:
    width = int(stream.get("width") or 0)
    height = int(stream.get("height") or 0)
    return [] if width >= MIN_WIDTH and height >= MIN_HEIGHT else [
        f"decoded media dimensions are too small for visible proof: {label}"
    ]


def validate_png_file(path: Path) -> list[str]:
    payload, errors = probe(path)
    stream = video_stream(payload)
    if stream is None:
        return errors + [f"PNG has no decodable image stream: {path.name}"]
    errors.extend(dimension_errors(stream, path.name))
    errors.extend(frame_visibility_errors(decode_gray_frame(path), path.name))
    return errors


def validate_video_file(path: Path) -> list[str]:
    payload, errors = probe(path)
    stream = video_stream(payload)
    if stream is None:
        return errors + [f"recording has no decodable video stream: {path.name}"]
    errors.extend(dimension_errors(stream, path.name))
    try:
        duration = float((payload.get("format") or {}).get("duration") or stream.get("duration") or 0)
    except (TypeError, ValueError):
        duration = 0
    if duration < 1.0:
        errors.append("recording duration is too short to span the named UI test")
        return errors
    visible_samples = 0
    sample_errors: list[str] = []
    for fraction in (0.1, 0.5, 0.9):
        label = f"{path.name}@{fraction:.1f}"
        current = frame_visibility_errors(decode_gray_frame(path, duration * fraction), label)
        if current:
            sample_errors.extend(current)
        else:
            visible_samples += 1
    if visible_samples < 2:
        errors.append("recording does not contain enough decoded nonblank visible frames")
        errors.extend(sample_errors)
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--png", action="append", default=[], type=Path)
    parser.add_argument("--video", action="append", default=[], type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    missing = require_tools()
    errors = [f"required media decoder is missing: {name}" for name in missing]
    if not errors:
        for path in args.png:
            errors.extend(validate_png_file(path))
        for path in args.video:
            errors.extend(validate_video_file(path))
    proof = {
        "status": "PASS" if not errors else "FAIL",
        "png": [str(path) for path in args.png],
        "video": [str(path) for path in args.video],
        "errors": errors,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(proof, indent=2) + "\n", encoding="utf-8")
    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
