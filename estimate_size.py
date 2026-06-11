#!/usr/bin/env python3
"""Pre-flight mirror-size estimator for Media Mirror.

Walks the source library and estimates how much space the *converted* mirror
will occupy on the destination — before any conversion runs — then compares it
against the destination's free space so you know up front whether it will fit.

Estimation model per file:
  * If the source is already at or below the target height, it is copied
    through unchanged, so the estimate is the real source file size.
  * Otherwise the encoded size is duration × (target video bitrate + audio
    bitrate). Bitrates come from a standard H.264 ladder (see BITRATE_KBPS).

Uses ffprobe (ships with ffmpeg) for duration/height. Files ffprobe can't read
fall back to a size-ratio heuristic so the total is never silently undercounted.
Pure stdlib otherwise.

Usage:
  estimate_size.py [--config PATH] [--json] [--target HEIGHT] [--workers N]
"""

import argparse
import concurrent.futures
import json
import os
import subprocess
import sys

VIDEO_EXTS = {".mp4", ".mkv", ".avi", ".m4v", ".mov", ".wmv", ".ts", ".flv", ".webm"}

# Approximate H.264 total *video* bitrate (kbps) for a given output height.
# Conservative-but-realistic for CRF~23 medium content. Audio added separately.
BITRATE_KBPS = {
    2160: 14000,
    1440: 8000,
    1080: 4500,
    720: 2500,
    480: 1200,
    360: 700,
    240: 400,
}
AUDIO_KBPS = 128
# Heuristic when ffprobe fails: assume re-encode keeps this fraction of source
# size (downscaling to 720p typically lands well under half).
FALLBACK_SIZE_RATIO = 0.45


def video_bitrate_for_height(height: int) -> int:
    """Nearest defined ladder bitrate at or above the requested height."""
    for h in sorted(BITRATE_KBPS):
        if height <= h:
            return BITRATE_KBPS[h]
    return BITRATE_KBPS[max(BITRATE_KBPS)]


def read_config(path: str) -> dict:
    config = {}
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    key, _, val = line.partition("=")
                    config[key.strip()] = val.strip().strip('"').strip("'")
    except FileNotFoundError:
        pass
    return config


def ffprobe_info(path: str) -> tuple[float | None, int | None]:
    """Return (duration_seconds, height) using ffprobe; (None, None) on failure."""
    try:
        out = subprocess.run(
            [
                "ffprobe", "-v", "error",
                "-select_streams", "v:0",
                "-show_entries", "stream=height:format=duration",
                "-of", "json", path,
            ],
            capture_output=True, text=True, timeout=30,
        )
        if out.returncode != 0:
            return None, None
        data = json.loads(out.stdout)
        height = None
        streams = data.get("streams") or []
        if streams:
            height = streams[0].get("height")
        duration = None
        dur_raw = (data.get("format") or {}).get("duration")
        if dur_raw is not None:
            duration = float(dur_raw)
        return duration, (int(height) if height else None)
    except Exception:
        return None, None


def estimate_file(path: str, target_height: int) -> dict:
    """Estimate the converted output size (bytes) for one source file."""
    try:
        src_size = os.path.getsize(path)
    except OSError:
        src_size = 0

    duration, height = ffprobe_info(path)

    if height is not None and height <= target_height:
        # Copied through unchanged — exact size known.
        return {"bytes": src_size, "mode": "copy", "probed": True}

    if duration is not None and duration > 0:
        total_kbps = video_bitrate_for_height(target_height) + AUDIO_KBPS
        est = int(total_kbps * 1000 / 8 * duration)
        # Never estimate a re-encode as larger than the source.
        if src_size and est > src_size:
            est = int(src_size * FALLBACK_SIZE_RATIO)
        return {"bytes": est, "mode": "encode", "probed": True}

    # ffprobe failed — fall back to a fraction of source size.
    return {"bytes": int(src_size * FALLBACK_SIZE_RATIO), "mode": "encode", "probed": False}


def walk_sources(roots: list[str]) -> list[str]:
    files = []
    for root in roots:
        if not root or not os.path.isdir(root):
            continue
        for dirpath, _dirs, names in os.walk(root):
            for n in names:
                if os.path.splitext(n)[1].lower() in VIDEO_EXTS:
                    files.append(os.path.join(dirpath, n))
    return files


def dest_free_bytes(config: dict) -> int | None:
    """Free bytes on the destination movies mount via `df -k` over SSH."""
    dest_host = config.get("DEST_HOST", "")
    dest_key = config.get("DEST_SSH_KEY", "")
    dest_path = config.get("DEST_MOVIES", "")
    if not (dest_host and dest_key and dest_path):
        return None
    try:
        out = subprocess.run(
            ["ssh", "-i", dest_key, "-o", "StrictHostKeyChecking=no",
             "-o", "ConnectTimeout=5", dest_host, f"df -k '{dest_path}'"],
            capture_output=True, text=True, timeout=12,
        )
        if out.returncode != 0:
            return None
        lines = out.stdout.strip().splitlines()
        if len(lines) < 2:
            return None
        # "Avail" is the 4th column in POSIX df -k output (1K blocks).
        avail_kb = int(lines[1].split()[3])
        return avail_kb * 1024
    except Exception:
        return None


def human(n: int | None) -> str:
    if n is None:
        return "unknown"
    units = ["B", "KB", "MB", "GB", "TB", "PB"]
    f = float(n)
    for u in units:
        if f < 1024 or u == units[-1]:
            return f"{f:.1f} {u}"
        f /= 1024
    return f"{f:.1f} PB"


def estimate(config: dict, target_height: int, workers: int = 8,
             progress=None) -> dict:
    roots = [config.get("SOURCE_MOVIES", ""), config.get("SOURCE_TV", "")]
    files = walk_sources(roots)
    total = len(files)

    est_bytes = 0
    src_bytes = 0
    encode_count = copy_count = probe_fail = 0
    done = 0

    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as ex:
        futs = {ex.submit(estimate_file, f, target_height): f for f in files}
        for fut in concurrent.futures.as_completed(futs):
            r = fut.result()
            est_bytes += r["bytes"]
            try:
                src_bytes += os.path.getsize(futs[fut])
            except OSError:
                pass
            if r["mode"] == "copy":
                copy_count += 1
            else:
                encode_count += 1
            if not r["probed"]:
                probe_fail += 1
            done += 1
            if progress and done % 50 == 0:
                progress(done, total)

    free = dest_free_bytes(config)
    result = {
        "target_height": target_height,
        "file_count": total,
        "estimated_bytes": est_bytes,
        "estimated_human": human(est_bytes),
        "source_bytes": src_bytes,
        "source_human": human(src_bytes),
        "encode_count": encode_count,
        "copy_count": copy_count,
        "probe_failures": probe_fail,
        "dest_free_bytes": free,
        "dest_free_human": human(free),
        "fits": (free is not None and est_bytes <= free),
        "headroom_bytes": (free - est_bytes) if free is not None else None,
    }
    return result


def main():
    ap = argparse.ArgumentParser(description="Estimate Media Mirror output size.")
    ap.add_argument("--config", default=os.environ.get("CONFIG_FILE", "/opt/media-mirror/config.env"))
    ap.add_argument("--target", type=int, default=None, help="Override target height")
    ap.add_argument("--workers", type=int, default=8)
    ap.add_argument("--json", action="store_true", help="Emit JSON only")
    args = ap.parse_args()

    config = read_config(args.config)
    target = args.target or int(config.get("TARGET_HEIGHT", "720") or 720)

    def progress(done, total):
        if not args.json:
            print(f"  probed {done}/{total} files…", file=sys.stderr)

    result = estimate(config, target, workers=args.workers, progress=progress)

    if args.json:
        print(json.dumps(result))
        return

    print(f"Target resolution : {result['target_height']}p")
    print(f"Source files      : {result['file_count']}")
    print(f"Source size       : {result['source_human']}")
    print(f"Estimated mirror  : {result['estimated_human']}  "
          f"({result['copy_count']} copied, {result['encode_count']} re-encoded)")
    if result["probe_failures"]:
        print(f"  (note: {result['probe_failures']} files estimated via fallback heuristic)")
    print(f"Destination free  : {result['dest_free_human']}")
    if result["dest_free_bytes"] is not None:
        verdict = "FITS" if result["fits"] else "WILL NOT FIT"
        print(f"Verdict           : {verdict} "
              f"(headroom {human(result['headroom_bytes'])})")
    else:
        print("Verdict           : destination free space unknown (no SSH/df)")


if __name__ == "__main__":
    main()
