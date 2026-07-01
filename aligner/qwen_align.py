#!/usr/bin/env python3
"""CaptionLab forced-alignment sidecar (Qwen3-ForcedAligner via mlx-audio, MLX only).

Aligns a KNOWN transcript to audio and prints per-word/char timings as a normalized JSON
array to STDOUT — the stable contract the Swift side depends on:

    [{"text": "<token>", "start": <seconds float>, "end": <seconds float>}, ...]

Usage:
    python qwen_align.py --audio path.wav --text "transcript…" --language Chinese [--model <id>]

Only STDOUT carries the JSON. Progress bars / logs from mlx-audio go to STDERR. On failure this
exits non-zero and writes a one-line JSON error object to STDERR (STDOUT stays empty), so the
caller never has to parse mixed output.
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile

DEFAULT_MODEL = "mlx-community/Qwen3-ForcedAligner-0.6B-8bit"


def fail(msg: str, code: int = 1):
    sys.stderr.write(json.dumps({"error": msg}) + "\n")
    sys.exit(code)


def main() -> int:
    ap = argparse.ArgumentParser(description="Qwen forced-aligner sidecar (mlx-audio).")
    ap.add_argument("--audio", required=True, help="Path to a mono WAV (16 kHz recommended).")
    ap.add_argument("--text", required=True, help="The transcript to align to the audio.")
    ap.add_argument("--language", default="Chinese", help="Aligner language (Chinese, English, …).")
    ap.add_argument("--model", default=os.environ.get("CAPTIONLAB_ALIGNER_MODEL", DEFAULT_MODEL))
    args = ap.parse_args()

    if not os.path.isfile(args.audio):
        fail(f"audio file not found: {args.audio}")
    text = args.text.strip()
    if not text:
        fail("empty transcript text")

    # Invoke the proven mlx_audio forced-aligner CLI, writing to a temp JSON we then normalize.
    # (Calling the module keeps us on the exact code path the human verified, and stays MLX-only.)
    with tempfile.TemporaryDirectory(prefix="captionlab-align-") as tmp:
        out_prefix = os.path.join(tmp, "aligned")
        cmd = [
            sys.executable, "-m", "mlx_audio.stt.generate",
            "--model", args.model,
            "--audio", args.audio,
            "--text", text,
            "--language", args.language,
            "--format", "json",
            "--output-path", out_prefix,
        ]
        try:
            proc = subprocess.run(cmd, stdout=sys.stderr, stderr=sys.stderr)
        except FileNotFoundError:
            fail("could not launch python for mlx_audio — is the venv set up? run ./setup.sh")
        if proc.returncode != 0:
            fail(f"mlx_audio.stt.generate exited {proc.returncode}")

        out_json = out_prefix + ".json"
        if not os.path.isfile(out_json):
            fail("aligner produced no output json")
        try:
            with open(out_json, "r", encoding="utf-8") as f:
                data = json.load(f)
        except Exception as e:  # noqa: BLE001
            fail(f"could not read aligner json: {e}")

    segments = data.get("segments") if isinstance(data, dict) else None
    if not isinstance(segments, list):
        fail("aligner json missing 'segments'")

    words = []
    for seg in segments:
        if not isinstance(seg, dict):
            continue
        t = str(seg.get("text", "")).strip()
        if not t:
            continue
        try:
            start = float(seg.get("start"))
            end = float(seg.get("end"))
        except (TypeError, ValueError):
            continue
        words.append({"text": t, "start": start, "end": end})

    json.dump(words, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
